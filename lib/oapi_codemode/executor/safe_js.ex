defmodule OapiCodemode.Executor.SafeJS do
  @moduledoc """
  In-process executor on [ex_safejs](https://github.com/jtippett/ex_safejs),
  the QuickJS-NG engine embedded as a Rustler NIF (our hard fork of
  lpgauth/quicksand). Like `Executor.ZapCode` it's a pure dependency with
  precompiled binaries — no runtime binary in the image, no subprocess — but
  unlike zapcode it enforces a genuine hard memory cap (QuickJS's own
  allocator is the sole memory authority, so even typed-array/`ArrayBuffer`
  allocations are bounded, the vector that escapes V8's heap limit) and runs
  a mature, correct engine with O(1) container access (no O(n²) spec scans).

  ## Dialect: same async arrow as `Executor.Deno`

  Since ex_safejs 0.3.0 eval is async-aware, so guest code may be a sync or
  an `async` arrow — `await`, `.then` chains, and `Promise.all` all work.
  `apis.<name>.request(...)` blocks the JS thread while the Elixir callback
  runs and returns the response as a plain value, which `await` passes
  through unchanged; `Promise.all` over several requests therefore executes
  them serially, not concurrently. A promise that nothing can ever settle
  is reported as a deadlock error immediately instead of burning the
  timeout.

  ## Timeout is compute-only — wall clock is a separate opt

  `:timeout` is a JS *compute* budget: host-callback time does not count
  against it. For a single slow call that's a feature (a slow host call
  never reads as guest misbehavior), but it means a guest looping over
  cheap `request()` calls has **unbounded wall-clock time** — the engine
  can never end it (ele P1). Hosts that meter runs (semaphores, billing,
  request deadlines) must pass `:wall_clock_ms`: the eval then runs in a
  throwaway worker killed at that deadline, returning
  `{:error, {:wall_clock, ms}}` (logs captured before the kill are lost).
  `OapiCodemode.Tools`' `:max_calls` bounds the same class at the tool
  layer for every executor. `Executor.Deno`'s timeout, by contrast, is a
  wall-clock deadline that includes callback time.

  Injection differs from Deno: ex_safejs has no globals API, so
  `env.globals` is handed in through a host callback that returns the map
  (direct term→JS conversion — faster than embedding JSON) and
  `Object.assign`ed onto `globalThis` in a preamble. The `apis` object and a
  `console.log` capture shim are built in the same preamble.

  ## Isolation

  ex_safejs guarantees a straggler-free mailbox: eval messages are tagged
  per-eval and a timed-out eval's late result is absorbed inside `eval/3`,
  so `run/3` executes directly in the calling process — safe for a
  trap_exit GenServer caller (gentility's LoopServer). The quicksand-era
  throwaway worker per eval is gone.

  ## Divergences from `Executor.Deno`, inherent to the engine

    * **Serial `Promise.all`** (above): requests resolve one at a time.
    * **Raising callbacks are opaque to the guest.** A callback that raises
      surfaces to JS as a generic `"host function failed"` exception; if
      uncaught, this run's `{:error, %{message: ..., logs: ...}}` carries
      the real exception message (host-side only).
    * **No regex.** (Shared with zapcode; steer codegen to string methods.)
  """

  @behaviour OapiCodemode.Executor

  @load_fn "__oapi_load_globals"
  @request_fn "__oapi_request"
  @log_fn "__oapi_log"
  @logs_key {__MODULE__, :logs}

  @impl true
  def run(code, env, opts) do
    case Keyword.get(opts, :wall_clock_ms) do
      nil -> safe_run(code, env, opts)
      wall when is_integer(wall) and wall > 0 -> walled_run(code, env, opts, wall)
    end
  end

  defp safe_run(code, env, opts) do
    do_run(code, env, opts)
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  # ele P1: `:timeout` is a JS compute budget that excludes host-callback
  # time, so a guest looping over cheap `request()` calls is otherwise
  # unbounded in wall time. `:wall_clock_ms` runs the eval (and therefore
  # its callbacks) in an unlinked, monitored worker and kills it at the
  # deadline. The kill takes any in-flight callback with the worker;
  # ex_safejs 0.3.1's dead-caller detection unblocks the runtime thread and
  # the runtime resource is reclaimed on GC. Logs captured before the kill
  # die with the worker's pdict — only the error shape survives.
  defp walled_run(code, env, opts, wall) do
    owner = self()
    ref = make_ref()

    # Unlinked: a linked worker would hand a trap_exit caller an {:EXIT, _}
    # message — the straggler class run/3 must never produce. safe_run/3 is
    # total, so the worker's normal return carries the result.
    {worker, mon} = spawn_monitor(fn -> send(owner, {ref, safe_run(code, env, opts)}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^worker, reason} ->
        {:error, {:raised, "sandbox worker exited: #{inspect(reason)}"}}
    after
      wall ->
        Process.exit(worker, :kill)
        Process.demonitor(mon, [:flush])
        {:error, {:wall_clock, wall}}
    end
  end

  defp do_run(code, env, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    start_opts =
      [timeout: timeout]
      |> maybe_put(:memory_limit, Keyword.get(opts, :memory_limit))
      |> maybe_put(:max_stack_size, Keyword.get(opts, :max_stack_size))

    Process.put(@logs_key, [])

    case ExSafejs.start(start_opts) do
      {:ok, rt} ->
        try do
          full = preamble(env.globals) <> "\nconst __oapi_main = " <> code <> ";\n__oapi_main();"
          rt |> ExSafejs.eval(full, callbacks(env)) |> to_result(timeout)
        after
          ExSafejs.stop(rt)
        end

      {:error, reason} ->
        {:error, %{message: "sandbox start failed: #{inspect(reason)}", logs: []}}
    end
  end

  defp callbacks(env) do
    base = %{
      @load_fn => fn [] -> {:ok, encodable_globals(env.globals)} end,
      @log_fn => fn [msg] ->
        Process.put(@logs_key, [to_string(msg) | Process.get(@logs_key, [])])
        {:ok, nil}
      end
    }

    case env.callbacks do
      %{request: request} when is_function(request) ->
        Map.put(base, @request_fn, fn [name, req_opts] -> {:ok, request.(name, req_opts)} end)

      _ ->
        base
    end
  end

  # apiNames is the one build-instruction global (see OapiCodemode.Executor);
  # it drives the apis shim and is not injected as inert data.
  defp encodable_globals(globals), do: Map.delete(globals, "apiNames")

  defp preamble(globals) do
    api_names = globals |> Map.get("apiNames", []) |> Enum.map(&to_string/1)

    """
    globalThis.console = {
      log: (...a) => #{@log_fn}(a.map(v => typeof v === "string" ? v : JSON.stringify(v)).join(" ")),
    };
    globalThis.console.error = globalThis.console.log;
    globalThis.console.warn = globalThis.console.log;
    Object.assign(globalThis, #{@load_fn}());
    const apis = #{apis_literal(api_names)};
    """
  end

  # Each entry closes over its own name via a JSON-encoded key, so a request
  # always tells the host which API it addressed and an exotic name can't
  # break out of the object literal.
  defp apis_literal([]), do: "{}"

  defp apis_literal(api_names) do
    entries =
      Enum.map_join(api_names, ", ", fn name ->
        key = Jason.encode!(name)
        "#{key}: { request: (o) => #{@request_fn}(#{key}, o) }"
      end)

    "{ " <> entries <> " }"
  end

  defp to_result({:ok, value}, _timeout), do: {:ok, %{value: value, logs: logs()}}

  # Plain-map __struct__ matches, not %ExSafejs.Error{} — struct expansion
  # would break compilation for consumers without the optional dep.
  defp to_result({:error, %{__struct__: ExSafejs.Error, kind: :timeout}}, timeout),
    do: {:error, {:timeout, timeout}}

  defp to_result({:error, %{__struct__: ExSafejs.Error, message: message}}, _timeout) do
    {:error, %{message: first_line(message), logs: logs()}}
  end

  # ex_safejs returns just the value; console output was captured host-side as
  # we went, oldest first once reversed.
  defp logs, do: @logs_key |> Process.get([]) |> Enum.reverse()

  defp first_line(message), do: message |> String.split("\n") |> hd() |> String.slice(0, 500)

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)
end
