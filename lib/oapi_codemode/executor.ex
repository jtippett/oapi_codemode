defmodule OapiCodemode.Executor do
  @moduledoc """
  The sandbox contract — the entire interface a TS execution environment
  must satisfy. Deliberately minimal: run code with globals and callbacks,
  return the value and console output.

  Requirements for real implementations:
    * No network access inside the sandbox.
    * `globals` are injected as JSON data before the code runs.
    * `callbacks.request` may be invoked CONCURRENTLY (a guest's
      `Promise.all` under an engine that dispatches in parallel, as
      `Executor.Deno` does) — the callback the tool layer supplies is
      safe for that. Dispatching serially instead is allowed and is what
      the in-process engines do.
    * The boundary is JSON-native: values crossing it survive
      JSON encode/decode unchanged.
    * On timeout, return `{:error, {:timeout, ms}}`, and cancel any
      outstanding callback work first — killing the sandbox process is not
      enough on its own, since callbacks dispatched into Elixir Tasks can
      still be in flight and will try to write to a call log the tool layer
      has already torn down.
    * On a run-time error inside the sandbox, prefer
      `{:error, %{message: String.t(), logs: [String.t()]}}` when any
      console output was captured before the crash — the tool layer surfaces
      those logs to the caller even though the run failed. A bare
      `{:error, term()}` (no logs) is also accepted for errors that
      necessarily precede any code running (e.g. a raise in the executor
      itself).

  ## The `apiNames` global (magic key)

  `env.globals` always carries an `"apiNames"` entry — the list of
  registered API names for this run (set by `OapiCodemode.Tools` in
  `do_execute/6`). This is not an ordinary data global: a real executor
  MUST read `globals["apiNames"]` and, before running the sandboxed code,
  build one `apis.<name>.request(opts)` binding per name, each forwarding
  to the `:request` callback with that name as its first argument. How the
  bindings are built is the engine's business: `OapiCodemode.Executor.SafeJS`
  emits an `apis` object literal in a JS preamble evaluated ahead of the
  guest code, and `priv/deno/bootstrap.ts`'s `installGlobals/2` builds the
  same object over the port protocol's `rpc("request", [name, opts])`.
  Either way the guest sees one shape. Everything else in `globals` is
  injected as inert data;
  `apiNames` alone is a *build instruction* for the sandbox's `apis` object.
  A third-party executor that treats it as just another data global will
  silently omit `apis` entirely and every `execute_api_code` call will fail
  with "apis is not defined" — there is no other signal pointing at this
  requirement, so implementers must know to look for it here.
  """

  @type env :: %{globals: map(), callbacks: %{optional(:request) => fun()}}
  @type result :: %{value: term(), logs: [String.t()]}
  @type run_error ::
          {:timeout, pos_integer()} | %{message: String.t(), logs: [String.t()]} | term()

  @callback run(code :: String.t(), env(), opts :: keyword()) ::
              {:ok, result()} | {:error, run_error()}
end
