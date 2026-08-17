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
             Deno.run(
               "async () => Object.keys(specs.a.paths)",
               %{globals: globals, callbacks: %{}},
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

  test "runtime errors return {:error, %{message: first_line, logs: [...]}}" do
    assert {:error, %{message: msg, logs: logs}} =
             Deno.run("async () => nope.nope", %{globals: %{}, callbacks: %{}}, timeout: 10_000)

    assert msg =~ "nope"
    refute msg =~ "data:application"
    assert logs == []
  end

  test "runtime error logs are captured even though the run failed" do
    code =
      ~s|async () => { console.log("before the crash"); return nope.nope; }|

    assert {:error, %{message: msg, logs: logs}} =
             Deno.run(code, %{globals: %{}, callbacks: %{}}, timeout: 10_000)

    assert msg =~ "nope"
    assert logs == ["before the crash"]
  end

  test "syntax errors are errors, not hangs" do
    assert {:error, _} =
             Deno.run("async () => {{{", %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end

  test "round-trips a ~1MB globals payload intact" do
    # Real specs' globals payload can be multi-MB (a real spec's globals
    # measure ~4MB) — nothing in the protocol may assume short lines.
    item = "item-" <> String.duplicate("x", 40)
    big_list = for i <- 1..20_000, do: item <> "-#{i}"
    globals = %{"bigList" => big_list}

    approx_bytes = big_list |> Enum.map(&byte_size/1) |> Enum.sum()
    assert approx_bytes > 1_000_000

    {elapsed_us, result} =
      :timer.tc(fn ->
        Deno.run(
          "async () => ({ length: bigList.length, last: bigList[bigList.length - 1] })",
          %{globals: globals, callbacks: %{}},
          timeout: 10_000
        )
      end)

    assert {:ok, %{value: %{"length" => 20_000, "last" => last}}} = result
    assert last == List.last(big_list)

    IO.puts("1MB globals round-trip: #{Float.round(elapsed_us / 1000, 1)} ms")
  end

  test "request callback round-trips" do
    callback = fn "petstore", %{"path" => "/pets"} ->
      %{"status" => 200, "body" => %{"n" => 1}}
    end

    code =
      ~s|async () => { const r = await apis.petstore.request({ path: "/pets" }); return r.body.n; }|

    assert {:ok, %{value: 1}} =
             Deno.run(
               code,
               %{globals: %{"apiNames" => ["petstore"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )
  end

  test "concurrent callbacks via Promise.all" do
    test_pid = self()

    callback = fn "a", %{"path" => path} ->
      send(test_pid, {:called, path})
      Process.sleep(300)
      %{"path" => path}
    end

    code = ~s|async () => {
      const [x, y] = await Promise.all([
        apis.a.request({ path: "/one" }),
        apis.a.request({ path: "/two" })
      ]);
      return [x.path, y.path];
    }|

    started = System.monotonic_time(:millisecond)

    assert {:ok, %{value: ["/one", "/two"]}} =
             Deno.run(code, %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )

    elapsed = System.monotonic_time(:millisecond) - started
    # Concurrent, not serial: two 300ms callbacks well under 600ms total.
    assert elapsed < 550
    assert_received {:called, "/one"}
    assert_received {:called, "/two"}
  end

  test "callback errors become JS exceptions the code can catch" do
    callback = fn _, _ -> raise "credential resolution failed" end

    code =
      ~s|async () => { try { await apis.a.request({ path: "/x" }); return "no"; } catch (e) { return e.message; } }|

    assert {:ok, %{value: msg}} =
             Deno.run(code, %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )

    assert msg =~ "credential resolution failed"
  end

  test "timeout kills the subprocess and returns a named limit" do
    assert {:error, {:timeout, 500}} =
             Deno.run("async () => { while (true) {} }", %{globals: %{}, callbacks: %{}},
               timeout: 500
             )
  end

  test "timeout kill actually terminates the OS process (not a pattern match)" do
    test_pid = self()

    task =
      Task.async(fn ->
        Deno.run(
          "async () => { while (true) {} }",
          %{globals: %{}, callbacks: %{}},
          timeout: 500,
          report_pid: test_pid
        )
      end)

    assert_receive {:deno_pid, os_pid}, 2_000
    assert {:error, {:timeout, 500}} = Task.await(task, 5_000)

    assert wait_until_dead(os_pid), "process #{os_pid} still alive after timeout kill"
  end

  # Regression: `run/3` used to open the port on (and receive its
  # messages on) the CALLING process. The `{:exit_status, _}` message the
  # OS sends when the child dies can arrive after "done" is already
  # processed and `run/3` has returned — undrained, it would sit in the
  # caller's mailbox and land on whatever that caller's next unrelated
  # `receive`/`handle_info` was (fatal for a GenServer calling this
  # synchronously from a message handler, which is exactly how gentility's
  # LoopServer calls it). `run/3` now owns the port from inside a
  # throwaway Task, so nothing should ever reach this test process's own
  # mailbox.
  test "no stray port messages leak into the calling process after run/3 returns" do
    assert {:ok, %{value: 1}} =
             Deno.run("async () => 1", %{globals: %{}, callbacks: %{}}, timeout: 10_000)

    refute_receive {_port, {:exit_status, _}}, 200
    refute_receive {_port, {:data, _}}, 0
  end

  # Regression: the first fix ran the port lifecycle inside `Task.async/1`,
  # which LINKS the task to the caller. A caller that traps exits — the
  # normal setup for a host GenServer — therefore got `{:EXIT, pid, :normal}`
  # when the task finished: the very class of unmatched straggler message
  # the fix was meant to remove, just wearing a different tag. `run/3` must
  # send the caller nothing that outlives the call, trap_exit or not.
  test "no stray messages leak into a trap_exit caller after run/3 returns" do
    Process.flag(:trap_exit, true)

    assert {:ok, %{value: 1}} =
             Deno.run("async () => 1", %{globals: %{}, callbacks: %{}}, timeout: 10_000)

    refute_receive {:EXIT, _, _}, 200
    refute_receive {:DOWN, _, _, _, _}, 0
    refute_receive {_port, {:exit_status, _}}, 0
    refute_receive {_port, {:data, _}}, 0
  end

  # Regression: the sandbox timeout used to be a per-receive IDLE timer —
  # every callback message reset it — so sandbox code that calls a callback
  # in an infinite loop never tripped it. The outer `Task.await(timeout +
  # 5_000)` backstop then fired and EXITed the caller (an exit is not
  # `rescue`-able, so it tore through `Tools.run_sandbox/3` into the host's
  # tool loop), and since the worker died from an exit signal its `after`
  # clause never ran — the `deno` child was orphaned and kept spinning.
  # The timeout is now a real wall-clock deadline.
  test "callback traffic cannot outlive the timeout (deadline, not idle timer)" do
    test_pid = self()
    callback = fn "a", _req -> %{"status" => 200} end

    code = ~s|async () => {
      for (;;) {
        try { await apis.a.request({ path: "/x" }); } catch (e) {}
      }
    }|

    started = System.monotonic_time(:millisecond)

    result =
      Deno.run(
        code,
        %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
        timeout: 500,
        report_pid: test_pid
      )

    elapsed = System.monotonic_time(:millisecond) - started

    assert {:error, {:timeout, 500}} = result
    assert elapsed < 3_000, "run/3 took #{elapsed}ms — timeout is not a real deadline"
    assert Process.alive?(test_pid)

    assert_received {:deno_pid, os_pid}
    assert wait_until_dead(os_pid), "process #{os_pid} still alive after deadline kill"
  end

  test "no network access inside the sandbox" do
    code =
      ~s|async () => { try { await fetch("https://example.com"); return "fetched"; } catch (e) { return "blocked"; } }|

    assert {:ok, %{value: "blocked"}} =
             Deno.run(code, %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end

  # Deno 2's default import allowlist permits dynamic https:/npm:/jsr:
  # imports WITHOUT --allow-net (network permission only gates `fetch`/TCP,
  # not the module loader). --no-remote/--no-npm close that door; these
  # cases prove all three remote import schemes are blocked from inside the
  # sandbox, not just plain fetch.
  test "dynamic import of a remote https module is blocked" do
    code =
      ~s|async () => { try { await import("https://esm.sh/left-pad@1.3.0"); return "imported"; } catch (e) { return "blocked"; } }|

    assert {:ok, %{value: "blocked"}} =
             Deno.run(code, %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end

  test "dynamic import of an npm module is blocked" do
    code =
      ~s|async () => { try { await import("npm:left-pad"); return "imported"; } catch (e) { return "blocked"; } }|

    assert {:ok, %{value: "blocked"}} =
             Deno.run(code, %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end

  test "dynamic import of a jsr module is blocked" do
    code =
      ~s|async () => { try { await import("jsr:@std/streams"); return "imported"; } catch (e) { return "blocked"; } }|

    assert {:ok, %{value: "blocked"}} =
             Deno.run(code, %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end

  # Polls `ps -p <pid>` for up to ~1s (SIGKILL delivery is not instantaneous)
  # instead of sleeping a fixed amount. The pid targeted is the exact one
  # recorded at spawn time via `report_pid` — never a name-based match.
  defp wait_until_dead(os_pid, attempts \\ 20) do
    {out, _} = System.cmd("ps", ["-p", Integer.to_string(os_pid)], stderr_to_stdout: true)

    cond do
      not (out =~ "deno") ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(50)
        wait_until_dead(os_pid, attempts - 1)
    end
  end
end
