defmodule OapiCodemode.Executor.QuicksandTest do
  use ExUnit.Case, async: true
  @moduletag :quicksand
  alias OapiCodemode.Executor.Quicksand

  # NOTE the SYNCHRONOUS contract: quicksand (QuickJS-NG) does not pump the
  # microtask queue, so promises never resolve. Guest code is a synchronous
  # arrow — `apis.x.request(...)` blocks and returns directly, no `await`.

  test "evaluates code and returns the value" do
    assert {:ok, %{value: 3, logs: []}} =
             Quicksand.run("() => 1 + 2", %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end

  test "globals are injected as data" do
    globals = %{"specs" => %{"a" => %{"paths" => %{"/x" => %{}}}}}

    assert {:ok, %{value: ["/x"]}} =
             Quicksand.run(
               "() => Object.keys(specs.a.paths)",
               %{globals: globals, callbacks: %{}},
               timeout: 10_000
             )
  end

  test "console output is captured as logs" do
    assert {:ok, %{value: nil, logs: ["hello", "world"]}} =
             Quicksand.run(
               "() => { console.log('hello'); console.log('world'); return null; }",
               %{globals: %{}, callbacks: %{}},
               timeout: 10_000
             )
  end

  test "runtime errors return {:error, %{message: message, logs: [...]}}" do
    assert {:error, %{message: msg, logs: []}} =
             Quicksand.run("() => nope.nope", %{globals: %{}, callbacks: %{}}, timeout: 10_000)

    assert msg =~ "nope"
    refute msg =~ "eval_script"
  end

  test "console output before a runtime error is still captured" do
    code = "() => { console.log('before crash'); return nope.nope; }"

    assert {:error, %{message: msg, logs: ["before crash"]}} =
             Quicksand.run(code, %{globals: %{}, callbacks: %{}}, timeout: 10_000)

    assert msg =~ "nope"
  end

  test "syntax errors are errors, not hangs" do
    assert {:error, _} =
             Quicksand.run("() => {{{", %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end

  test "round-trips a ~1MB globals payload intact" do
    item = "item-" <> String.duplicate("x", 40)
    big_list = for i <- 1..20_000, do: item <> "-#{i}"
    globals = %{"bigList" => big_list}

    approx_bytes = big_list |> Enum.map(&byte_size/1) |> Enum.sum()
    assert approx_bytes > 1_000_000

    {elapsed_us, result} =
      :timer.tc(fn ->
        Quicksand.run(
          "() => ({ length: bigList.length, last: bigList[bigList.length - 1] })",
          %{globals: globals, callbacks: %{}},
          timeout: 10_000
        )
      end)

    assert {:ok, %{value: %{"length" => 20_000, "last" => last}}} = result
    assert last == List.last(big_list)

    IO.puts("1MB globals round-trip (quicksand): #{Float.round(elapsed_us / 1000, 1)} ms")
  end

  test "request callback round-trips through the apis shim (synchronous)" do
    callback = fn "petstore", %{"path" => "/pets"} ->
      %{"status" => 200, "body" => %{"n" => 1}}
    end

    code = "() => { const r = apis.petstore.request({ path: '/pets' }); return r.body.n; }"

    assert {:ok, %{value: 1}} =
             Quicksand.run(
               code,
               %{globals: %{"apiNames" => ["petstore"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )
  end

  test "makes several api calls in one run" do
    callback = fn "a", %{"path" => path} -> %{"path" => path} end

    code = """
    () => {
      const x = apis.a.request({ path: '/one' });
      const y = apis.a.request({ path: '/two' });
      return [x.path, y.path];
    }
    """

    assert {:ok, %{value: ["/one", "/two"]}} =
             Quicksand.run(
               code,
               %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )
  end

  test "a raising callback aborts the run as a structured error" do
    callback = fn _, _ -> raise "credential resolution failed" end

    code = "() => apis.a.request({ path: '/x' })"

    assert {:error, %{message: msg}} =
             Quicksand.run(
               code,
               %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )

    assert msg =~ "credential resolution failed"
  end

  test "calling apis with no :request callback is an error, not a crash" do
    code = "() => apis.a.request({ path: '/x' })"

    assert {:error, %{message: msg}} =
             Quicksand.run(code, %{globals: %{"apiNames" => ["a"]}, callbacks: %{}},
               timeout: 10_000
             )

    assert msg =~ "request"
  end

  test "timeout returns {:error, {:timeout, ms}}" do
    assert {:error, {:timeout, 500}} =
             Quicksand.run("() => { while (true) {} }", %{globals: %{}, callbacks: %{}},
               timeout: 500
             )
  end

  test "memory abuse returns a structured limit error, node survives" do
    code = "() => { const c = []; while (true) { c.push(new Uint8Array(1048576).fill(7)); } }"

    assert {:error, %{message: msg}} =
             Quicksand.run(code, %{globals: %{}, callbacks: %{}},
               timeout: 10_000,
               memory_limit: 50_000_000
             )

    assert msg =~ ~r/memory/i
  end

  # A timed-out eval leaves a straggler {:quicksand_result, ...} in the
  # servicing process's mailbox; run/3 must isolate each eval so nothing
  # leaks into a trap_exit caller (gentility's LoopServer) or corrupts the
  # next call. This is the whole reason run/3 uses a throwaway worker.
  test "no stray messages leak into a trap_exit caller after a timeout" do
    Process.flag(:trap_exit, true)

    assert {:error, {:timeout, 300}} =
             Quicksand.run("() => { while (true) {} }", %{globals: %{}, callbacks: %{}},
               timeout: 300
             )

    # A subsequent normal run must be clean, not poisoned by a straggler.
    assert {:ok, %{value: 42}} =
             Quicksand.run("() => 42", %{globals: %{}, callbacks: %{}}, timeout: 10_000)

    refute_receive {:EXIT, _, _}, 200
    refute_receive {:DOWN, _, _, _, _}, 0
    refute_receive {:quicksand_result, _}, 0
    refute_receive {:quicksand_callback, _, _, _}, 0
  end
end
