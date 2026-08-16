defmodule OapiCodemode.Executor do
  @moduledoc """
  The sandbox contract — the entire interface a TS execution environment
  must satisfy. Deliberately minimal: run code with globals and callbacks,
  return the value and console output.

  Requirements for real implementations:
    * No network access inside the sandbox.
    * `globals` are injected as JSON data before the code runs.
    * `callbacks.request` may be invoked CONCURRENTLY (Promise.all).
    * The boundary is JSON-native: values crossing it survive
      JSON encode/decode unchanged.
    * On timeout, return `{:error, {:timeout, ms}}`.
  """

  @type env :: %{globals: map(), callbacks: %{optional(:request) => fun()}}
  @type result :: %{value: term(), logs: [String.t()]}

  @callback run(code :: String.t(), env(), opts :: keyword()) ::
              {:ok, result()} | {:error, term()}
end
