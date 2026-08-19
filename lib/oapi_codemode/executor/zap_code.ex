defmodule OapiCodemode.Executor.ZapCode do
  @moduledoc """
  In-process executor on [ex_zapcode](https://github.com/jtippett/ex_zapcode),
  a pure-Rust TypeScript-subset interpreter shipped as a NIF. No subprocess,
  no runtime binary in the image, no container config — a hex dependency is
  the whole deployment story, and the engine enforces a hard cap on live
  guest memory (the blocker that ruled Deno out for some hosts).

  The engine has no host bindings at all (no filesystem/network/env), so
  the `:request` callback is the sandbox's only door out, same as Deno.
  Guest code suspends at each `apis.<name>.request(...)` call
  (zapcode's start/resume model), the callback runs in Elixir, and the run
  resumes with its return value. The `apis` object itself is built by a JS
  preamble prepended to the code — one entry per `globals["apiNames"]` name,
  each forwarding to the single registered external function.

  Requires zapcode >= engine commit eaa546a: earlier revisions clobber the
  `apis` base variable on the second namespaced call and cannot snapshot
  with a pending builtin call (Promise.all) on the operand stack — both
  found integrating this module, both covered by regression tests here.

  Known divergences from `OapiCodemode.Executor.Deno`, all inherent to the
  engine rather than this module:

    * **Callbacks are serial.** `Promise.all` over api calls works but
      resolves one call at a time (accepted zapcode constraint):
      wall-clock for N calls is the sum, not the max.
    * **Callback errors abort the run.** `resume` can only inject a return
      value, not a throwable, so a raising callback comes back to the model
      as this run's `{:error, %{message: ..., logs: ...}}` instead of a JS
      exception the guest could catch.
    * **Logs are partial.** zapcode-core does not capture stdout produced
      after a resume, and its error tuple carries no stdout — so
      `console.log` output after the first API call, or in a failing
      segment, is dropped. Output before the first suspension is captured.
    * **No regex.** Regex literals are rejected at parse time; guest code
      must filter with `.includes()`/`.startsWith()`/`.endsWith()`.

  Timeout is a wall-clock deadline enforced at every suspension point, and
  the engine's own `max_duration_secs` (set to the same `:timeout`) bounds
  guest execution inside a segment — so a run that never suspends is cut by
  the engine at `timeout`, and one that suspends is cut at the first
  suspension past the deadline. Worst case is just under 2× `timeout` (a
  segment entered right before the deadline gets a fresh engine allowance).
  A callback still in flight at the deadline is killed before returning —
  it runs in an unlinked, monitored worker precisely so it can be cancelled
  and so nothing (EXITs, DOWNs, straggler replies) leaks into a trap_exit
  caller's mailbox after `run/3` returns.

  Callback results are round-tripped through JSON before entering the
  sandbox, keeping the behaviour's JSON-native boundary guarantee exact.
  """

  @behaviour OapiCodemode.Executor

  # ex_zapcode is an optional dep: consumers who never select this executor
  # compile without it, and these remote calls must not warn there.
  @compile {:no_warn_undefined, ExZapcode}

  @impl true
  def run(code, env, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    limits =
      opts
      |> Keyword.get(:limits, %{})
      |> Map.put_new(:max_duration_secs, timeout / 1000)

    api_names = env.globals |> Map.get("apiNames", []) |> Enum.map(&to_string/1)

    full_code =
      preamble(api_names) <> "\nconst __oapi_main = " <> code <> "\n;await __oapi_main();"

    full_code
    |> ExZapcode.start(inputs: env.globals, functions: ["__oapi_request"], limits: limits)
    |> loop(env.callbacks, "", deadline, timeout)
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  # Every entry closes over its own name, so the callback always learns
  # which API the guest addressed. Names are embedded via JSON encoding —
  # they come from host registration, but a quoted key means an exotic
  # name can't break out of the preamble.
  defp preamble([]), do: "const apis = {};"

  defp preamble(api_names) do
    entries =
      Enum.map_join(api_names, ",\n", fn name ->
        key = Jason.encode!(name)
        "  #{key}: { request: async (o) => await __oapi_request(#{key}, o) }"
      end)

    "const apis = {\n" <> entries <> "\n};"
  end

  defp loop(progress, callbacks, acc, deadline, timeout) do
    case progress do
      {:complete, value, out} ->
        {:ok, %{value: value, logs: to_logs(acc <> out)}}

      {:function_call, "__oapi_request", args, snapshot, out} ->
        acc = acc <> out
        remaining = deadline - System.monotonic_time(:millisecond)

        with true <- remaining > 0 || :deadline,
             {:ok, value} <- dispatch(args, callbacks, remaining) do
          snapshot |> ExZapcode.resume(value) |> loop(callbacks, acc, deadline, timeout)
        else
          :deadline -> {:error, {:timeout, timeout}}
          :callback_timeout -> {:error, {:timeout, timeout}}
          {:error, message} -> {:error, %{message: message, logs: to_logs(acc)}}
        end

      # Plain-map __struct__ matches, not %ExZapcode.Exception{} — struct
      # expansion needs the module at compile time, and ex_zapcode is an
      # optional dep no consumer has, so the struct form makes this library
      # uncompilable as a dependency (Elixir 1.20 type checking hard-errors
      # on an undefined struct; plain remote calls only warn).
      {:error, %{__struct__: ExZapcode.Exception, type: :timeout}} ->
        {:error, {:timeout, timeout}}

      {:error, %{__struct__: ExZapcode.Exception, type: type, message: message}} ->
        {:error, %{message: "#{type}: #{message}", logs: to_logs(acc)}}
    end
  end

  # The callback runs in an unlinked, monitored worker so a wedged one can
  # be killed at the deadline (contract: cancel outstanding callback work
  # before returning a timeout) and so no exit signal reaches a trap_exit
  # caller. Selective receives + demonitor flush + a final drain mean
  # nothing the worker ever sends outlives this call.
  defp dispatch(args, callbacks, remaining) do
    parent = self()
    ref = make_ref()

    {worker, mon} = spawn_monitor(fn -> send(parent, {ref, safe_call(args, callbacks)}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^worker, reason} ->
        {:error, "request callback exited: #{inspect(reason)}"}
    after
      remaining ->
        Process.exit(worker, :kill)
        Process.demonitor(mon, [:flush])
        drain(ref)
        :callback_timeout
    end
  end

  defp safe_call([api_name, req_opts], %{request: request}) do
    # The round-trip pins the behaviour's JSON-native boundary: whatever the
    # callback returns enters the sandbox exactly as JSON data would (atom
    # keys become strings, non-JSON terms fail here as a structured error
    # instead of surprising the guest).
    {:ok, request.(api_name, req_opts) |> Jason.encode!() |> Jason.decode!()}
  rescue
    e -> {:error, Exception.message(e) |> String.split("\n") |> hd()}
  end

  defp safe_call(_args, _callbacks),
    do: {:error, "request callback is not available for this run"}

  defp drain(ref) do
    receive do
      {^ref, _} -> drain(ref)
    after
      0 -> :ok
    end
  end

  defp to_logs(""), do: []
  defp to_logs(out), do: out |> String.split("\n") |> Enum.reject(&(&1 == ""))
end
