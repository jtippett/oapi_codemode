defmodule OapiCodemode.Executor.DenoTest do
  use ExUnit.Case
  @moduletag :deno
  alias OapiCodemode.Executor.Deno

  test "evaluates code and returns the value" do
    assert {:ok, %{value: 3, logs: []}} =
             Deno.run("async () => 1 + 2", %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end

  test "globals are injected as data" do
    globals = %{"specs" => %{"a" => %{"paths" => %{"/x" => %{}}}}}

    assert {:ok, %{value: ["/x"]}} =
             Deno.run("async () => Object.keys(specs.a.paths)", %{globals: globals, callbacks: %{}},
               timeout: 10_000
             )
  end

  test "console output is captured as logs" do
    assert {:ok, %{value: nil, logs: ["hello", "world"]}} =
             Deno.run(
               "async () => { console.log('hello'); console.log('world'); return null; }",
               %{globals: %{}, callbacks: %{}},
               timeout: 10_000
             )
  end

  test "runtime errors return {:error, first_line}" do
    assert {:error, msg} =
             Deno.run("async () => nope.nope", %{globals: %{}, callbacks: %{}}, timeout: 10_000)

    assert msg =~ "nope"
    refute msg =~ "data:application"
  end

  test "syntax errors are errors, not hangs" do
    assert {:error, _} =
             Deno.run("async () => {{{", %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end
end
