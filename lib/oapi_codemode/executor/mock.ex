defmodule OapiCodemode.Executor.Mock do
  @moduledoc """
  Test executor: the "sandbox" is an Elixir function you set per test.
  Exercises the plumbing (globals in, callbacks out, results back) without
  a JS runtime.
  """

  @behaviour OapiCodemode.Executor

  @key {__MODULE__, :response}

  def set_response(fun) when is_function(fun, 2), do: Process.put(@key, fun)

  @impl true
  def run(code, env, _opts) do
    case Process.get(@key) do
      nil -> {:error, :no_mock_response_set}
      fun -> fun.(code, env)
    end
  end
end
