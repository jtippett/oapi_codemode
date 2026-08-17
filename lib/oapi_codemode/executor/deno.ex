defmodule OapiCodemode.Executor.Deno do
  @moduledoc """
  Subprocess Deno executor. Resurrects ele's Exile-bridge design
  (ele-core a2a52478f) over a raw Port with three properties the original
  lacked: no temp files (data-URL import), concurrent callback dispatch,
  and child reaping on every path this module can reach — we record the
  OS pid at spawn and kill exactly that pid (never a pattern) both from
  the worker's own `after` clause and, if the worker itself dies or
  overruns, from `run/3`'s backstop, which is why the worker reports the
  pid to `run/3` the moment the port is open.

  Sandboxing: deno runs with --no-prompt and NO permission flags, so the
  child has no `fetch`/TCP network access, no filesystem access, no env
  access, and cannot spawn subprocesses. On its own that is not
  "no network": Deno 2's default *import* allowlist lets `import()` of
  `https:`/`npm:`/`jsr:` specifiers reach the network to fetch the module
  even without `--allow-net` (the module loader is a separate permission
  domain from `fetch`). We additionally pass `--no-remote` and `--no-npm`
  to close that door — they disable remote (http/https/jsr) and npm module
  resolution outright, so no permission grant could re-open it later
  either. The `data:text/typescript` bootstrap import that loads the
  sandboxed code itself is unaffected (`data:` is a local scheme, not
  remote/npm). Callbacks are the sandbox's only door out.

  Residual risk (protocol injection): `bootstrap.ts` patches `console.log`
  and, once the sandboxed code starts running, attempts to lock down
  `Deno.stdout.write`/`writeSync` so sandboxed code cannot forge protocol
  lines on stdout. If a future Deno version makes those properties
  non-configurable, that lockdown silently no-ops (bootstrap.ts documents
  this at the call site) and a malicious script could in principle inject a
  fake `done` line. Severity is low: the sandbox already runs with zero
  permissions (no network/filesystem/env), so the worst case is a confused
  result for that one run, not an escape from the sandbox.

  Port ownership: `Port.open/2` ties the port's messages — including the
  `{:exit_status, _}` message the OS delivers when the child dies — to
  whichever process calls it. `run/3` may already have returned via the
  "done" callback protocol before that trailing exit-status message
  reaches the mailbox (the child writes "done" to stdout and calls
  `Deno.exit(0)` back-to-back; the pipe-data and process-exit
  notifications race independently). A caller that invokes `run/3`
  synchronously from inside a long-lived process (a GenServer handling a
  tool call, say) would otherwise see that straggler delivered to its next
  unrelated `receive`/`handle_info` and crash on a message it has no
  clause for — this happened for real integrating with a host's loop
  server. So the whole port lifecycle runs inside a throwaway worker
  process instead: any message that outlives the run dies with that
  worker's mailbox rather than leaking into the caller.

  The worker is *unlinked* (`spawn_monitor`, not `Task.async`). A linked
  task sends a trap_exit caller — the normal setup for a host GenServer —
  an `{:EXIT, pid, :normal}` when it finishes, which is the same
  unmatched-straggler crash in different clothing. `run/3` consumes the
  `:DOWN` before returning and flushes the monitor on every path, so it
  hands the caller nothing that outlives the call and, because the worker
  is unlinked and `do_run/3` is total, never exits or raises into it
  either: the return is always `{:ok, _} | {:error, _}`.

  Timeout is a wall-clock deadline, not an idle timer. It is computed
  once at spawn and each `receive` in `loop/5` waits only the remaining
  time, so total sandbox wall time is bounded by `:timeout` no matter how
  much callback traffic the sandbox generates (an infinite loop calling a
  callback used to reset a per-receive timer forever and run unbounded).
  """

  @behaviour OapiCodemode.Executor

  @bootstrap Path.join(:code.priv_dir(:oapi_codemode), "deno/bootstrap.ts")

  @impl true
  def run(code, env, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    owner = self()
    ref = make_ref()

    # Unlinked on purpose: a linked task delivers `{:EXIT, _, :normal}` to
    # a trap_exit caller. `do_run/4` is also made total (never raises — see
    # `safe_run/4`) so the worker's normal return, not an exit signal,
    # carries failures back. An EXIT is NOT a `rescue`-able exception, and
    # callers of this behaviour (e.g. `OapiCodemode.Tools.run_sandbox/3`)
    # rely on being able to `rescue` a misbehaving executor.
    {worker, mon} =
      spawn_monitor(fn -> send(owner, {ref, safe_run(code, env, opts, owner, ref)}) end)

    # The backstop is a deadline too, so the worker's os_pid report can't
    # push it out. It only ever fires if the worker itself wedges past its
    # own deadline; the grace is for the SIGKILL round trip.
    await(ref, mon, worker, timeout, System.monotonic_time(:millisecond) + timeout + 5_000, nil)
  end

  defp await(ref, mon, worker, timeout, backstop, os_pid) do
    receive do
      {^ref, :os_pid, pid} ->
        await(ref, mon, worker, timeout, backstop, pid)

      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^worker, reason} ->
        # The worker died without reporting. Its `after` clause never ran,
        # so nothing reaped the child — do it here, from the pid it told
        # us about at spawn.
        reap_child(os_pid)
        flush_result(ref)
        {:error, {:worker_down, reason}}
    after
      max(backstop - System.monotonic_time(:millisecond), 0) ->
        # Reap the child BEFORE killing the worker: while the worker lives
        # the port holds the OS child, so the pid can't be recycled out
        # from under our kill (see `close_port/2`).
        reap_child(os_pid)
        Process.exit(worker, :kill)
        Process.demonitor(mon, [:flush])
        flush_result(ref)
        {:error, {:timeout, timeout}}
    end
  end

  # Nothing may outlive the call: drain any result/report the worker got
  # out before we stopped listening.
  defp flush_result(ref) do
    receive do
      {^ref, _} -> flush_result(ref)
      {^ref, :os_pid, _} -> flush_result(ref)
    after
      0 -> :ok
    end
  end

  defp safe_run(code, env, opts, owner, ref) do
    do_run(code, env, opts, owner, ref)
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  defp do_run(code, env, opts, owner, ref) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    report_pid = Keyword.get(opts, :report_pid)
    deno = System.find_executable("deno") || raise "deno not found on PATH"

    port =
      Port.open({:spawn_executable, deno}, [
        :binary,
        :exit_status,
        :hide,
        args: ["run", "--no-prompt", "--quiet", "--no-remote", "--no-npm", @bootstrap]
      ])

    os_pid = port |> Port.info(:os_pid) |> elem(1)

    # `run/3` needs the pid immediately: if this process dies abnormally
    # the `after` clause below never runs and the backstop is the only
    # thing left that can reap the child.
    send(owner, {ref, :os_pid, os_pid})
    if report_pid, do: send(report_pid, {:deno_pid, os_pid})

    start_msg =
      Jason.encode!(%{
        type: "start",
        code: code,
        globals: env.globals,
        apiNames: Map.get(env.globals, "apiNames", [])
      })

    Port.command(port, start_msg <> "\n")

    try do
      loop(port, env.callbacks, "", deadline, timeout)
    after
      close_port(port, os_pid)
    end
  end

  # `deadline` is absolute monotonic ms; each receive waits only what is
  # left of it. A per-receive `after timeout` would be an idle timer that
  # chatty sandbox code (a callback called in an infinite loop) resets
  # forever, so the run would never be bounded by `:timeout` at all.
  defp loop(port, callbacks, buffer, deadline, timeout) do
    receive do
      {^port, {:data, data}} ->
        {lines, rest} = split_lines(buffer <> data)

        case handle_lines(lines, port, callbacks) do
          {:done, result} -> result
          :continue -> loop(port, callbacks, rest, deadline, timeout)
        end

      {^port, {:exit_status, status}} ->
        {:error, "sandbox process exited with status #{status} before returning"}

      {:callback_reply, id, reply} ->
        Port.command(port, Jason.encode!(reply_msg(id, reply)) <> "\n")
        loop(port, callbacks, buffer, deadline, timeout)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, {:timeout, timeout}}
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {lines, [rest]} = Enum.split(parts, -1)
    {Enum.reject(lines, &(&1 == "")), rest}
  end

  defp handle_lines([], _port, _callbacks), do: :continue

  defp handle_lines([line | rest], port, callbacks) do
    case Jason.decode(line) do
      {:ok, %{"type" => "done", "ok" => %{"value" => value, "logs" => logs}}} ->
        {:done, {:ok, %{value: value, logs: logs}}}

      {:ok, %{"type" => "done", "error" => error, "logs" => logs}} ->
        {:done, {:error, %{message: error, logs: logs}}}

      {:ok, %{"type" => "done", "error" => error}} ->
        {:done, {:error, %{message: error, logs: []}}}

      {:ok, %{"type" => "callback", "id" => id, "name" => name, "args" => args}} ->
        dispatch_callback(id, name, args, callbacks)
        handle_lines(rest, port, callbacks)

      _other ->
        handle_lines(rest, port, callbacks)
    end
  end

  # Callbacks run in their own tasks so the sandbox can have several in
  # flight (Promise.all). Replies are funneled back through the port loop's
  # mailbox to keep Port.command on the owning process.
  defp dispatch_callback(id, name, args, callbacks) do
    parent = self()

    Task.start(fn ->
      reply =
        try do
          case {name, args} do
            {"request", [api_name, req_opts]} when is_map_key(callbacks, :request) ->
              {:ok, callbacks.request.(api_name, req_opts)}

            _ ->
              {:error, "unknown callback #{name}"}
          end
        rescue
          e -> {:error, Exception.message(e) |> String.split("\n") |> hd()}
        end

      send(parent, {:callback_reply, id, reply})
    end)
  end

  defp reply_msg(id, {:ok, value}), do: %{type: "callback_result", id: id, ok: value}
  defp reply_msg(id, {:error, message}), do: %{type: "callback_result", id: id, error: message}

  defp close_port(port, os_pid) do
    # Kill exactly the pid we spawned (recorded above) — never a pattern —
    # BEFORE closing the port. Port.close reaps the OS child asynchronously;
    # closing first would free up that pid for the OS to reuse while our
    # kill -9 is still in flight, risking a signal landing on an unrelated
    # process that raced into the freed pid.
    System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    if Port.info(port), do: Port.close(port)
  catch
    _, _ -> :ok
  end

  # Backstop reaping from `run/3`, which does not own the port. If the
  # worker already died the VM has closed the port for us, so the pid may
  # in principle have been recycled — check the process still looks like
  # our deno child before signalling it. Still an exact recorded pid,
  # never a name-based match.
  defp reap_child(nil), do: :ok

  defp reap_child(os_pid) do
    pid = Integer.to_string(os_pid)
    {out, status} = System.cmd("ps", ["-p", pid, "-o", "comm="], stderr_to_stdout: true)

    if status == 0 and String.contains?(out, "deno") do
      System.cmd("kill", ["-9", pid], stderr_to_stdout: true)
    end

    :ok
  catch
    _, _ -> :ok
  end
end
