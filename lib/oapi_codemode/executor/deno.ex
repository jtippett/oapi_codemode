defmodule OapiCodemode.Executor.Deno do
  @moduledoc """
  Subprocess Deno executor. Resurrects ele's Exile-bridge design
  (ele-core a2a52478f) over a raw Port with three properties the original
  lacked: no temp files (data-URL import), concurrent callback dispatch,
  and guaranteed child reaping (we record the OS pid at spawn and kill
  exactly that pid on timeout — never a pattern).

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
  """

  @behaviour OapiCodemode.Executor

  @bootstrap Path.join(:code.priv_dir(:oapi_codemode), "deno/bootstrap.ts")

  @impl true
  def run(code, env, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
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
      loop(port, env.callbacks, "", timeout)
    after
      close_port(port, os_pid)
    end
  end

  defp loop(port, callbacks, buffer, timeout) do
    receive do
      {^port, {:data, data}} ->
        {lines, rest} = split_lines(buffer <> data)

        case handle_lines(lines, port, callbacks) do
          {:done, result} -> result
          :continue -> loop(port, callbacks, rest, timeout)
        end

      {^port, {:exit_status, status}} ->
        {:error, "sandbox process exited with status #{status} before returning"}

      {:callback_reply, id, reply} ->
        Port.command(port, Jason.encode!(reply_msg(id, reply)) <> "\n")
        loop(port, callbacks, buffer, timeout)
    after
      timeout -> {:error, {:timeout, timeout}}
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

      {:ok, %{"type" => "done", "error" => error}} ->
        {:done, {:error, error}}

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
    if Port.info(port), do: Port.close(port)
    # Kill exactly the pid we spawned (recorded above) — never a pattern.
    System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
  catch
    _, _ -> :ok
  end
end
