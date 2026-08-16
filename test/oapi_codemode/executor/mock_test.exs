defmodule OapiCodemode.Executor.MockTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Executor.Mock

  test "returns the canned value and records the run" do
    Mock.set_response(fn code, env ->
      send(self(), {:ran, code, env})
      {:ok, %{value: %{"found" => 2}, logs: ["hi"]}}
    end)

    assert {:ok, %{value: %{"found" => 2}, logs: ["hi"]}} =
             Mock.run("async () => 1", %{globals: %{"specs" => %{}}, callbacks: %{}}, [])

    assert_received {:ran, "async () => 1", %{globals: %{"specs" => %{}}}}
  end

  test "can drive the request callback to simulate execute-tool code" do
    Mock.set_response(fn _code, env ->
      result = env.callbacks.request.("petstore", %{"method" => "GET", "path" => "/pets"})
      {:ok, %{value: result, logs: []}}
    end)

    callback = fn "petstore", %{"path" => "/pets"} -> %{"status" => 200} end

    assert {:ok, %{value: %{"status" => 200}}} =
             Mock.run("code", %{globals: %{}, callbacks: %{request: callback}}, [])
  end
end
