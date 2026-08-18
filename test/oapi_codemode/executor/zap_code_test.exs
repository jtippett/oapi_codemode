defmodule OapiCodemode.Executor.ZapCodeTest do
  use ExUnit.Case, async: true
  @moduletag :zapcode
  alias OapiCodemode.Executor.ZapCode

  test "evaluates code and returns the value" do
    assert {:ok, %{value: 3, logs: []}} =
             ZapCode.run("async () => 1 + 2", %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end

  test "globals are injected as data" do
    globals = %{"specs" => %{"a" => %{"paths" => %{"/x" => %{}}}}}

    assert {:ok, %{value: ["/x"]}} =
             ZapCode.run(
               "async () => Object.keys(specs.a.paths)",
               %{globals: globals, callbacks: %{}},
               timeout: 10_000
             )
  end

  test "console output is captured as logs" do
    assert {:ok, %{value: nil, logs: ["hello", "world"]}} =
             ZapCode.run(
               "async () => { console.log('hello'); console.log('world'); return null; }",
               %{globals: %{}, callbacks: %{}},
               timeout: 10_000
             )
  end

  test "runtime errors return {:error, %{message: message, logs: [...]}}" do
    assert {:error, %{message: msg, logs: []}} =
             ZapCode.run("async () => nope.nope", %{globals: %{}, callbacks: %{}},
               timeout: 10_000
             )

    assert msg =~ "nope"
  end

  test "syntax errors are errors, not hangs" do
    assert {:error, _} =
             ZapCode.run("async () => {{{", %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end

  test "round-trips a ~1MB globals payload intact" do
    item = "item-" <> String.duplicate("x", 40)
    big_list = for i <- 1..20_000, do: item <> "-#{i}"
    globals = %{"bigList" => big_list}

    approx_bytes = big_list |> Enum.map(&byte_size/1) |> Enum.sum()
    assert approx_bytes > 1_000_000

    {elapsed_us, result} =
      :timer.tc(fn ->
        ZapCode.run(
          "async () => ({ length: bigList.length, last: bigList[bigList.length - 1] })",
          %{globals: globals, callbacks: %{}},
          timeout: 10_000
        )
      end)

    assert {:ok, %{value: %{"length" => 20_000, "last" => last}}} = result
    assert last == List.last(big_list)

    IO.puts("1MB globals round-trip (zapcode): #{Float.round(elapsed_us / 1000, 1)} ms")
  end

  test "request callback round-trips through the apis shim" do
    callback = fn "petstore", %{"path" => "/pets"} ->
      %{"status" => 200, "body" => %{"n" => 1}}
    end

    code =
      ~s|async () => { const r = await apis.petstore.request({ path: "/pets" }); return r.body.n; }|

    assert {:ok, %{value: 1}} =
             ZapCode.run(
               code,
               %{globals: %{"apiNames" => ["petstore"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )
  end

  # ENGINE GAP (zapcode): calling a user-defined function through a depth-2
  # property chain (`apis.a.request(...)`) overwrites the base variable with
  # the intermediate receiver — `apis` becomes `apis.a` — so the SECOND api
  # call of a run finds `apis.a` undefined. Reproduced engine-only:
  #   const o = {"a": {"r": (n) => n + 1}}; o.a.r(1); Object.keys(o) //=> ["r"]
  # Builtin methods (`.filter`, `.toLowerCase`) do not clobber, so search
  # workloads are unaffected. See ex_zapcode/SANDBOX_HARDENING_PLAN.md
  # (consumer findings). Unskip when the engine fix lands.
  @tag skip: "zapcode engine: depth-2 user-fn call clobbers base variable"
  test "two sequential api calls in one run" do
    callback = fn "a", %{"path" => path} -> %{"path" => path} end

    code = ~s|async () => {
      const x = await apis.a.request({ path: "/one" });
      const y = await apis.a.request({ path: "/two" });
      return [x.path, y.path];
    }|

    assert {:ok, %{value: ["/one", "/two"]}} =
             ZapCode.run(
               code,
               %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )
  end

  # ENGINE GAP (zapcode): snapshot capture fails ("Serde Serialization Error")
  # when a suspension happens with pending promises in scope — Promise.all
  # over external calls cannot suspend at all, even flat ones. Unskip when
  # the engine can snapshot pending promises.
  @tag skip: "zapcode engine: cannot snapshot with pending promises in scope"
  test "Promise.all over api calls works (serially — accepted P2.2 constraint)" do
    test_pid = self()

    callback = fn "a", %{"path" => path} ->
      send(test_pid, {:called, path})
      %{"path" => path}
    end

    code = ~s|async () => {
      const [x, y] = await Promise.all([
        apis.a.request({ path: "/one" }),
        apis.a.request({ path: "/two" })
      ]);
      return [x.path, y.path];
    }|

    assert {:ok, %{value: ["/one", "/two"]}} =
             ZapCode.run(
               code,
               %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )

    assert_received {:called, "/one"}
    assert_received {:called, "/two"}
  end

  # Divergence from the Deno executor: zapcode's resume can only inject a
  # return VALUE, not a throwable — so a raising callback aborts the run as a
  # structured error instead of becoming a catchable JS exception.
  test "callback errors abort the run as a structured error" do
    callback = fn _, _ -> raise "credential resolution failed" end

    code = ~s|async () => { await apis.a.request({ path: "/x" }); return "no"; }|

    assert {:error, %{message: msg, logs: _}} =
             ZapCode.run(
               code,
               %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )

    assert msg =~ "credential resolution failed"
  end

  test "calling apis with no :request callback is an error, not a crash" do
    code = ~s|async () => await apis.a.request({ path: "/x" })|

    assert {:error, %{message: msg}} =
             ZapCode.run(code, %{globals: %{"apiNames" => ["a"]}, callbacks: %{}},
               timeout: 10_000
             )

    assert msg =~ "request"
  end

  test "timeout returns {:error, {:timeout, ms}}" do
    # With default limits an infinite loop trips :max_allocations long before
    # the clock (covered below); raise it so wall-clock actually governs.
    assert {:error, {:timeout, 500}} =
             ZapCode.run("async () => { while (true) {} }", %{globals: %{}, callbacks: %{}},
               timeout: 500,
               limits: %{max_allocations: 999_999_999_999}
             )
  end

  test "under default limits an infinite loop is a structured limit error (errors are data)" do
    assert {:error, %{message: msg}} =
             ZapCode.run("async () => { while (true) {} }", %{globals: %{}, callbacks: %{}},
               timeout: 10_000
             )

    assert msg =~ ~r/allocation/i
  end

  test "callback traffic cannot outlive the timeout (deadline, not idle timer)" do
    callback = fn "a", _req ->
      Process.sleep(50)
      %{"status" => 200}
    end

    # Flat __oapi_request calls, not the apis shim: repeated shim calls are
    # blocked by the depth-2 clobber engine gap (see the skipped test above),
    # and this test is about the executor's own deadline enforcement.
    code = ~s|async () => {
      for (;;) {
        await __oapi_request("a", { path: "/x" });
      }
    }|

    started = System.monotonic_time(:millisecond)

    assert {:error, {:timeout, 300}} =
             ZapCode.run(
               code,
               %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 300
             )

    assert System.monotonic_time(:millisecond) - started < 2_000
  end

  test "a wedged callback is cancelled at the deadline" do
    callback = fn "a", _req ->
      Process.sleep(30_000)
      %{"status" => 200}
    end

    code = ~s|async () => await apis.a.request({ path: "/x" })|

    started = System.monotonic_time(:millisecond)

    assert {:error, {:timeout, 300}} =
             ZapCode.run(
               code,
               %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 300
             )

    assert System.monotonic_time(:millisecond) - started < 2_000
  end

  # The whole reason zapcode is here (ele's blocker): resource abuse comes
  # back as a structured error the model can read — the node stays alive.
  test "memory abuse returns a structured limit error, node survives" do
    code = ~s|async () => { let s = "x"; while (true) { s = s + s; } }|

    assert {:error, %{message: msg}} =
             ZapCode.run(code, %{globals: %{}, callbacks: %{}}, timeout: 10_000)

    assert msg =~ ~r/memory|allocation/i
  end

  test "custom :limits are passed through to the engine" do
    code = ~s|async () => { let t = 0; for (let i = 0; i < 1000; i++) { t = t + i; } return t; }|

    assert {:ok, %{value: _}} =
             ZapCode.run(code, %{globals: %{}, callbacks: %{}}, timeout: 10_000)

    assert {:error, %{message: msg}} =
             ZapCode.run(code, %{globals: %{}, callbacks: %{}},
               timeout: 10_000,
               limits: %{max_allocations: 10}
             )

    assert msg =~ ~r/allocation/i
  end

  test "deep data nesting returns a structured limit error, node survives" do
    code = ~s|async () => { let a = []; for (let i = 0; i < 1000; i++) { a = [a]; } return 1; }|

    assert {:error, %{message: msg}} =
             ZapCode.run(code, %{globals: %{}, callbacks: %{}}, timeout: 10_000)

    assert msg =~ ~r/nest/i
  end

  # `run/3` may be called synchronously from a host GenServer that traps
  # exits (gentility's LoopServer). Nothing — task EXITs, DOWNs, straggler
  # replies — may outlive the call into the caller's mailbox.
  test "no stray messages leak into a trap_exit caller after run/3 returns" do
    Process.flag(:trap_exit, true)

    callback = fn "a", _req -> %{"status" => 200} end
    code = ~s|async () => await apis.a.request({ path: "/x" })|

    assert {:ok, %{value: %{"status" => 200}}} =
             ZapCode.run(
               code,
               %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )

    refute_receive {:EXIT, _, _}, 200
    refute_receive {:DOWN, _, _, _, _}, 0
  end

  test "no stray messages leak after a timeout cancels a wedged callback" do
    Process.flag(:trap_exit, true)

    callback = fn "a", _req ->
      Process.sleep(30_000)
      %{"status" => 200}
    end

    code = ~s|async () => await apis.a.request({ path: "/x" })|

    assert {:error, {:timeout, 300}} =
             ZapCode.run(
               code,
               %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 300
             )

    refute_receive {:EXIT, _, _}, 200
    refute_receive {:DOWN, _, _, _, _}, 0
  end
end
