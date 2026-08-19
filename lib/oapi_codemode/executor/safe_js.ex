defmodule OapiCodemode.Executor.SafeJS do
  @moduledoc """
  In-process executor on [ex_safejs](https://github.com/jtippett/ex_safejs),
  the QuickJS-NG engine embedded as a Rustler NIF (our hard fork of
  lpgauth/quicksand, carrying the rquickjs 0.12 fix for the BEAM-killing
  SIGABRT on timeout-during-a-pending-promise-job — lpgauth/quicksand#2).
  Like `Executor.ZapCode` it's a pure dependency with precompiled binaries —
  no runtime binary in the image, no subprocess — but unlike zapcode it
  enforces a genuine hard memory cap (QuickJS's own allocator is the sole
  memory authority, so even typed-array/`ArrayBuffer` allocations are
  bounded, the vector that escapes V8's heap limit) and runs a mature,
  correct engine with O(1) container access (no O(n²) spec scans).

  ## Synchronous contract — this executor is different

  QuickJS-NG here does **not** pump the microtask queue before snapshotting
  the eval result, so a Promise never resolves: an `async` arrow comes back
  as an unresolved `{}`. Guest code must therefore be a **synchronous**
  arrow, and `apis.<name>.request(...)` is a **blocking** call that returns
  the response directly — no `await`, no `Promise.all`. The callback runs in
  Elixir while the JS thread blocks, then the run resumes with its return
  value. Callers that generate code for this executor must describe the
  synchronous surface (this is why `run/3` is not a drop-in swap for
  `Executor.Deno`, whose contract is an async arrow). An async-aware eval is
  planned in ex_safejs (`eval_promise` + drain-check-settle); this contract
  note is the thing to revisit when it ships.

  Injection differs too: ex_safejs has no globals API, so `env.globals` is
  handed in through a host callback that returns the map (direct term→JS
  conversion — faster than embedding JSON) and `Object.assign`ed onto
  `globalThis` in a preamble. The `apis` object and a `console.log` capture
  shim are built in the same preamble.

  ## Isolation

  `run/3` runs each eval in an unlinked, monitored throwaway process. This is
  load-bearing, not hygiene: ex_safejs delivers `{:ex_safejs_callback, ...}`
  and `{:ex_safejs_result, ...}` to the process servicing the eval, and a
  *timed-out* eval can leave a straggler `{:ex_safejs_result, ...}` in that
  mailbox after `eval/3` has already returned `{:error, "timeout"}`. Left in
  the caller, that straggler would poison the next unrelated `receive` — fatal
  for a host GenServer calling this synchronously (gentility's LoopServer). The
  worker absorbs any straggler and dies with it; being unlinked and total, it
  hands a trap_exit caller no `{:EXIT, _}`/`:DOWN`/stray message either.

  ## Divergences from `Executor.Deno`, inherent to the engine

    * **Synchronous** (above): no `await`, no `Promise.all`.
    * **Callback errors abort the run.** A raising or `{:error, _}` callback
      comes back as this run's `{:error, %{message: ..., logs: ...}}`, not a
      catchable JS exception.
    * **No regex.** (Shared with zapcode; steer codegen to string methods.)
  """

  @behaviour OapiCodemode.Executor

  @load_fn "__oapi_load_globals"
  @request_fn "__oapi_request"
  @log_fn "__oapi_log"
  @logs_key {__MODULE__, :logs}

  @impl true
  def run(code, env, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    owner = self()
    ref = make_ref()

    # Unlinked worker: a linked task would send a trap_exit caller
    # {:EXIT, _, :normal}, the same unmatched-straggler hazard the isolation
    # is meant to remove. do_run/4 is total, so the worker's normal return —
    # never an exit signal — carries the result back.
    {worker, mon} =
      spawn_monitor(fn -> send(owner, {ref, safe_run(code, env, opts)}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^worker, reason} ->
        {:error, {:worker_down, reason}}
    after
      # A little past the engine's own deadline; the worker should return its
      # own {:timeout, _} first. This only fires if the worker itself wedges.
      timeout + 5_000 ->
        Process.exit(worker, :kill)
        Process.demonitor(mon, [:flush])
        {:error, {:timeout, timeout}}
    end
  end

  defp safe_run(code, env, opts) do
    do_run(code, env, opts)
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  defp do_run(code, env, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    start_opts =
      [timeout: timeout]
      |> maybe_put(:memory_limit, Keyword.get(opts, :memory_limit))
      |> maybe_put(:max_stack_size, Keyword.get(opts, :max_stack_size))

    Process.put(@logs_key, [])
    Process.put({__MODULE__, :timeout}, timeout)

    case ExSafejs.start(start_opts) do
      {:ok, rt} ->
        try do
          full = preamble(env.globals) <> "\nconst __oapi_main = " <> code <> ";\n__oapi_main();"
          rt |> ExSafejs.eval(full, callbacks(env)) |> to_result()
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

  defp to_result({:ok, value}), do: {:ok, %{value: value, logs: logs()}}

  defp to_result({:error, message}) when is_binary(message) do
    cond do
      timeout?(message) -> {:error, {:timeout, timeout_ms(message)}}
      true -> {:error, %{message: first_line(message), logs: logs()}}
    end
  end

  # ex_safejs returns just the value; console output was captured host-side as
  # we went, oldest first once reversed.
  defp logs, do: @logs_key |> Process.get([]) |> Enum.reverse()

  defp timeout?("timeout" <> _), do: true
  defp timeout?(_), do: false

  # The engine reports "timeout" without the configured ms; carry back what we
  # asked for so the tool layer can render {:timeout, ms} uniformly. The value
  # is stashed by do_run via the process dictionary of this worker.
  defp timeout_ms(_message), do: Process.get({__MODULE__, :timeout}, 0)

  defp first_line(message), do: message |> String.split("\n") |> hd() |> String.slice(0, 500)

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)
end
