defmodule OapiCodemode.ToolsTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.{Tools, Registry, Ingest, ApiConfig, Fixtures}
  alias OapiCodemode.Executor.Mock

  defmodule NoneResolver do
    @behaviour OapiCodemode.Credentials
    @impl true
    def resolve(_, _, _, _), do: {:ok, :none}
  end

  setup do
    reg = start_supervised!({Registry, name: nil})
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())
    :ok = Registry.register(reg, "petstore", art, %ApiConfig{})

    opts = [
      registry: reg,
      executor: Mock,
      resolver: NoneResolver,
      policy: :read_only,
      max_result_tokens: 6000
    ]

    %{reg: reg, opts: opts}
  end

  test "definitions expose two tools with schemas", %{opts: opts} do
    defs = Tools.definitions(opts)
    assert ["execute_api_code", "search_apis"] = defs |> Enum.map(& &1.name) |> Enum.sort()
    search = Enum.find(defs, &(&1.name == "search_apis"))
    assert search.input_schema["required"] == ["code"]
    assert is_function(search.handler, 2)
  end

  test "search runs code against specs global and JSON-encodes the result", %{opts: opts} do
    Mock.set_response(fn code, env ->
      assert code =~ "spec"
      assert %{"petstore" => %{"paths" => _}} = Jason.decode!(env.globals["__oapi_specs_json"])
      {:ok, %{value: [%{"path" => "/pets"}], logs: []}}
    end)

    search = Tools.definitions(opts) |> Enum.find(&(&1.name == "search_apis"))
    assert {:ok, result} = search.handler.(%{"code" => "async () => spec"}, %{})
    assert result =~ ~s([{"path":"/pets"}])
  end

  test ":executor_opts are forwarded to the executor for both tools", %{opts: opts} do
    # Mock.run/3 ignores opts, so capture them via a spy executor. The
    # handler invokes the executor in the calling process, so self() here
    # is the test process.
    defmodule OptsSpy do
      @behaviour OapiCodemode.Executor
      @impl true
      def run(_code, _env, opts) do
        send(self(), {:executor_opts, opts})
        {:ok, %{value: nil, logs: []}}
      end
    end

    opts =
      opts
      |> Keyword.put(:executor, OptsSpy)
      |> Keyword.put(:executor_opts, limits: %{max_memory: 256_000_000})

    [search, execute] = Tools.definitions(opts) |> Enum.sort_by(& &1.name, :desc)

    assert {:ok, _} = search.handler.(%{"code" => "async () => null"}, %{})
    assert_received {:executor_opts, received}
    assert received[:limits] == %{max_memory: 256_000_000}
    assert received[:timeout] == 30_000

    assert {:ok, _} = execute.handler.(%{"code" => "async () => null"}, %{})
    assert_received {:executor_opts, received}
    assert received[:limits] == %{max_memory: 256_000_000}
  end

  test "search sandbox gets no callbacks", %{opts: opts} do
    Mock.set_response(fn _code, env ->
      assert env.callbacks == %{}
      {:ok, %{value: nil, logs: []}}
    end)

    search = Tools.definitions(opts) |> Enum.find(&(&1.name == "search_apis"))
    assert {:ok, _} = search.handler.(%{"code" => "async () => null"}, %{})
  end

  test "oversized results are truncated with an instructive trailer", %{opts: opts} do
    big = List.duplicate(%{"x" => String.duplicate("a", 100)}, 2000)
    Mock.set_response(fn _c, _e -> {:ok, %{value: big, logs: []}} end)

    search = Tools.definitions(opts) |> Enum.find(&(&1.name == "search_apis"))
    {:ok, result} = search.handler.(%{"code" => "async () => big"}, %{})
    assert String.length(result) < 30_000
    assert result =~ "Use more specific queries"
  end

  test "execute wires request callback through the proxy", %{opts: opts} do
    Req.Test.stub(ToolStub, fn conn -> Req.Test.json(conn, %{"pets" => []}) end)

    Mock.set_response(fn _code, env ->
      # simulate sandbox code calling apis.petstore.request(...)
      result =
        env.callbacks.request.("petstore", %{
          "method" => "GET",
          "path" => "/pets",
          "query" => %{"limit" => 1}
        })

      {:ok, %{value: result, logs: []}}
    end)

    execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

    {:ok, result} =
      execute.handler.(%{"code" => "async () => ..."}, %{
        req_options: [plug: {Req.Test, ToolStub}]
      })

    # I6: the callback's return value is the real proxy response, handed
    # back into the sandbox as data.
    decoded = Jason.decode!(result)
    assert decoded["result"]["status"] == 200
    assert decoded["result"]["body"] == %{"pets" => []}
    assert decoded["result"]["headers"]["content-type"] =~ "application/json"
    assert [%{"api" => "petstore", "status" => 200}] = decoded["calls"]
  end

  test "execute records call metadata even when code returns a summary", %{opts: opts} do
    Req.Test.stub(ToolStub2, fn conn -> Req.Test.json(conn, %{"pets" => []}) end)

    Mock.set_response(fn _code, env ->
      env.callbacks.request.("petstore", %{
        "method" => "GET",
        "path" => "/pets",
        "query" => %{"limit" => 1}
      })

      {:ok, %{value: "done", logs: ["log line"]}}
    end)

    execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

    {:ok, result} =
      execute.handler.(%{"code" => "..."}, %{req_options: [plug: {Req.Test, ToolStub2}]})

    decoded = Jason.decode!(result)
    assert decoded["result"] == "done"
    assert decoded["logs"] == ["log line"]
    assert [%{"operation" => "GET /pets", "status" => 200}] = decoded["calls"]
  end

  test "annotate_call classifies a call's log entry from the host-observed payload; base keys win",
       %{opts: opts} do
    Req.Test.stub(ToolStub2, fn conn ->
      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{"error" => %{"type" => "step_up_required"}})
    end)

    Mock.set_response(fn _code, env ->
      env.callbacks.request.("petstore", %{
        "method" => "GET",
        "path" => "/pets",
        "query" => %{"limit" => 1}
      })

      # The model's code returns a cheerful summary; the annotation must be
      # in the host-written call log regardless.
      {:ok, %{value: "done", logs: []}}
    end)

    annotate = fn
      %{"status" => 403, "body" => %{"error" => %{"type" => type}}} ->
        %{"refusal" => type, "status" => "forged"}

      _payload ->
        %{}
    end

    execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

    {:ok, result} =
      execute.handler.(
        %{"code" => "..."},
        %{req_options: [plug: {Req.Test, ToolStub2}], annotate_call: annotate}
      )

    assert [entry] = Jason.decode!(result)["calls"]
    assert entry["refusal"] == "step_up_required"
    # The annotator tried to clobber "status"; the library's own key wins.
    assert entry["status"] == 403
  end

  test "sandbox errors come back as phase-tagged tool errors", %{opts: opts} do
    Mock.set_response(fn _c, _e -> {:error, "ReferenceError: nope is not defined"} end)
    search = Tools.definitions(opts) |> Enum.find(&(&1.name == "search_apis"))
    assert {:error, msg} = search.handler.(%{"code" => "async () => nope"}, %{})
    assert msg =~ "sandbox"
    assert msg =~ "ReferenceError"
  end

  describe "handler robustness (I1, M4, M5, M9)" do
    # I1: the call-log Agent was started linked and only stopped on the happy
    # path — every failing execute leaked a process into the host's caller
    # (20 leaked over the suite), and a late Agent crash would have taken the
    # host process with it.
    test "an executor that raises leaks no processes and surfaces the error as data", %{
      opts: opts
    } do
      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      {:links, before} = Process.info(self(), :links)

      Mock.set_response(fn _c, _e -> raise "boom inside the sandbox" end)

      assert {:ok, result} = execute.handler.(%{"code" => "async () => 1"}, %{})
      decoded = Jason.decode!(result)
      assert decoded["calls"] == []
      assert decoded["logs"] == []
      assert decoded["error"] =~ "sandbox error"
      assert decoded["error"] =~ "boom inside the sandbox"
      refute Map.has_key?(decoded, "result")

      {:links, later} = Process.info(self(), :links)
      assert later == before
    end

    # I1: on sandbox error/timeout the call metadata (and any calls already
    # made before the crash) must still reach the caller — mutations may
    # have landed even though the run ultimately failed.
    test "an executor error still leaves no linked processes behind and reports calls made before the crash",
         %{opts: opts} do
      Req.Test.stub(ErrorPathStub, fn conn -> Req.Test.json(conn, %{"pets" => []}) end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      {:links, before} = Process.info(self(), :links)

      Mock.set_response(fn _code, env ->
        env.callbacks.request.("petstore", %{
          "method" => "GET",
          "path" => "/pets",
          "query" => %{"limit" => 1}
        })

        {:error, "ReferenceError"}
      end)

      assert {:ok, result} =
               execute.handler.(%{"code" => "async () => 1"}, %{
                 req_options: [plug: {Req.Test, ErrorPathStub}]
               })

      decoded = Jason.decode!(result)
      assert [%{"api" => "petstore", "status" => 200}] = decoded["calls"]
      assert decoded["error"] =~ "sandbox error"
      assert decoded["error"] =~ "ReferenceError"

      {:links, later} = Process.info(self(), :links)
      assert later == before
    end

    # ele P1 (round 5): a run that dies while a call is mid-dispatch — a
    # wall-clock kill after the upstream accepted a mutation but before the
    # response came back — must leave that call visible in the envelope as
    # "in_flight", not silently omit it. An omitted landed mutation invites
    # the model to replay it.
    test "a run killed mid-dispatch leaves the in-flight call in the envelope", %{opts: opts} do
      handler_pid = self()

      Mock.set_response(fn _code, env ->
        # The "sandbox" starts a request that blocks inside dispatch (the
        # plug below signals us once it is executing), then the run dies
        # with the callback still in flight — the SafeJS wall-clock kill
        # shape.
        caller = self()

        {pid, mref} =
          spawn_monitor(fn ->
            payload =
              env.callbacks.request.("petstore", %{
                "method" => "GET",
                "path" => "/pets",
                "query" => %{"limit" => 1}
              })

            send(caller, {:payload, payload})
          end)

        assert caller == handler_pid

        receive do
          :in_dispatch -> :ok
          {:payload, payload} -> raise "dispatch returned early: #{inspect(payload)}"
          {:DOWN, ^mref, :process, ^pid, reason} -> raise "callback crashed: #{inspect(reason)}"
        after
          2_000 -> raise "the request callback never reached dispatch"
        end

        {:error, {:wall_clock, 123}}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

      blocked_plug = fn conn ->
        send(handler_pid, :in_dispatch)
        Process.sleep(5_000)
        Req.Test.json(conn, %{})
      end

      assert {:ok, result} =
               execute.handler.(%{"code" => "async () => ..."}, %{
                 req_options: [plug: blocked_plug]
               })

      decoded = Jason.decode!(result)
      assert decoded["error"] =~ "wall-clock"

      assert [entry] = decoded["calls"]
      assert entry["status"] == "in_flight"
      assert entry["operation"] == "GET /pets"
      assert entry["note"] =~ "outcome is unknown"
    end

    # M9: the timeout branch has its own message shape, and (I1) still
    # surfaces the calls made before the timeout hit rather than discarding
    # them.
    test "an executor timeout surfaces the elapsed budget and the calls already made", %{
      opts: opts
    } do
      Mock.set_response(fn _c, _e -> {:error, {:timeout, 30_000}} end)
      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

      assert {:ok, result} =
               execute.handler.(%{"code" => "async () => while(true){}"}, %{})

      assert result == ~s({"calls":[],"logs":[],"error":"sandbox timed out after 30000 ms"})
    end

    # I1: a Deno bootstrap crash mid-run still carries whatever console.log
    # output happened before the crash; the tool layer must not discard it.
    test "executor errors that carry logs surface them in the envelope", %{opts: opts} do
      Mock.set_response(fn _c, _e ->
        {:error, %{message: "nope is not defined", logs: ["before the crash"]}}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      assert {:ok, result} = execute.handler.(%{"code" => "async () => 1"}, %{})

      decoded = Jason.decode!(result)
      assert decoded["logs"] == ["before the crash"]
      assert decoded["error"] =~ "nope is not defined"
    end

    # M5: a model that emits the tool call without arguments must get a
    # usable message, not a FunctionClauseError.
    test "a call with no code argument names the missing argument", %{opts: opts} do
      defs = Tools.definitions(opts)

      for tool <- defs do
        assert {:error, "missing required argument: code"} = tool.handler.(%{}, %{})
        assert {:error, "missing required argument: code"} = tool.handler.(%{"cod" => "x"}, %{})
      end
    end

    # M4: `request()` called with a string/array/nothing must not crash the
    # callback (and therefore the whole run).
    test "request() with a non-object argument returns a usable error", %{opts: opts} do
      Mock.set_response(fn _code, env ->
        {:ok, %{value: env.callbacks.request.("petstore", "GET /pets"), logs: []}}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      {:ok, result} = execute.handler.(%{"code" => "..."}, %{})

      assert Jason.decode!(result)["result"] == %{
               "error" => "request() expects an options object"
             }
    end

    # M9: an unknown API name must name the ones that exist.
    test "request() against an unregistered API names the registered ones", %{opts: opts} do
      Mock.set_response(fn _code, env ->
        {:ok,
         %{
           value: env.callbacks.request.("petsore", %{"method" => "GET", "path" => "/pets"}),
           logs: []
         }}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      {:ok, result} = execute.handler.(%{"code" => "..."}, %{})

      error = Jason.decode!(result)["result"]["error"]
      assert error =~ "unknown API"
      assert error =~ "petsore"
      assert error =~ "Registered: petstore"
    end

    # M9: the globals the execute description declares must really arrive.
    test "sandbox_globals and apiNames reach the sandbox", %{reg: reg, opts: opts} do
      {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())

      :ok =
        Registry.register(reg, "petstore", art, %ApiConfig{
          sandbox_globals: %{"storeId" => "s1"}
        })

      Mock.set_response(fn _code, env ->
        assert env.globals["apiNames"] == ["petstore"]
        assert env.globals["context"] == %{"petstore" => %{"storeId" => "s1"}}
        {:ok, %{value: nil, logs: []}}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      assert {:ok, _} = execute.handler.(%{"code" => "..."}, %{})
    end

    # M9: a denied request is still a call the operator should see.
    test "a policy denial is recorded in the calls metadata as an error", %{opts: opts} do
      Mock.set_response(fn _code, env ->
        result =
          env.callbacks.request.("petstore", %{
            "method" => "POST",
            "path" => "/pets",
            "body" => %{"name" => "R", "species" => "dog"}
          })

        {:ok, %{value: result, logs: []}}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      {:ok, result} = execute.handler.(%{"code" => "..."}, %{})
      decoded = Jason.decode!(result)

      assert [%{"operation" => "POST /pets", "status" => "error", "api" => "petstore"}] =
               decoded["calls"]

      assert decoded["result"]["error"] =~ "[policy]"
    end

    # M9: two registered APIs are both addressable in the same run.
    test "both registered APIs are reachable from one run", %{reg: reg, opts: opts} do
      {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())
      :ok = Registry.register(reg, "other", art, %ApiConfig{})

      Req.Test.stub(TwoApiStub, fn conn -> Req.Test.json(conn, %{"host" => conn.host}) end)

      Mock.set_response(fn _code, env ->
        req = %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 1}}

        {:ok,
         %{
           value: [
             env.callbacks.request.("petstore", req),
             env.callbacks.request.("other", req)
           ],
           logs: []
         }}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

      {:ok, result} =
        execute.handler.(%{"code" => "..."}, %{req_options: [plug: {Req.Test, TwoApiStub}]})

      decoded = Jason.decode!(result)
      assert [%{"status" => 200}, %{"status" => 200}] = decoded["result"]
      assert [%{"api" => "petstore"}, %{"api" => "other"}] = decoded["calls"]
    end

    # M1: truncation chops the tail, so the envelope puts call metadata and
    # logs first and the (unbounded) result last.
    test "the execute envelope orders calls and logs before result", %{opts: opts} do
      Mock.set_response(fn _c, _e -> {:ok, %{value: "v", logs: ["l"]}} end)
      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      {:ok, result} = execute.handler.(%{"code" => "..."}, %{})

      assert result == ~s({"calls":[],"logs":["l"],"result":"v"})
    end
  end

  # I2: tool names were hardcoded, blocking a host from registering both a
  # read-only `execute_api_code` and a mutating `execute_api_mutations`
  # variant (two `definitions/1` calls, each with its own policy and name).
  describe "configurable execute tool name and search inclusion (I2)" do
    test "default behavior is unchanged: search_apis + execute_api_code", %{opts: opts} do
      defs = Tools.definitions(opts)
      assert ["execute_api_code", "search_apis"] = defs |> Enum.map(& &1.name) |> Enum.sort()
    end

    test "search tool name is configurable and defaults to search_apis", %{opts: opts} do
      custom_names =
        opts
        |> Keyword.put(:search_tool_name, "x_api_search")
        |> Tools.definitions()
        |> Enum.map(& &1.name)

      assert "x_api_search" in custom_names
      # M2: the custom name replaces the default outright — it must not be
      # emitted alongside it as a second, stray tool.
      refute "search_apis" in custom_names
      assert "search_apis" in Enum.map(Tools.definitions(opts), & &1.name)
    end

    # I2: the execute tool's description must name its own paired search
    # tool, not the other trio's — otherwise a host running several
    # search/execute instances can't tell the model which pair goes
    # together.
    test "execute description names the paired search tool by its configured name", %{
      opts: opts
    } do
      custom_opts = Keyword.put(opts, :search_tool_name, "x_api_search")
      defs = Tools.definitions(custom_opts)
      execute = Enum.find(defs, &(&1.name == "execute_api_code"))

      assert execute.description =~ "`x_api_search` tool"
    end

    # I2: the second call in the two-tool-variant pattern sets
    # include_search: false — no search tool is emitted from THIS call, and
    # none was named, so the description must not claim one exists.
    test "execute description names no search tool when include_search is false and none was given",
         %{opts: opts} do
      mutating_opts =
        opts
        |> Keyword.put(:policy, :all)
        |> Keyword.put(:execute_tool_name, "execute_api_mutations")
        |> Keyword.put(:include_search, false)

      defs = Tools.definitions(mutating_opts)
      execute = Enum.find(defs, &(&1.name == "execute_api_mutations"))

      refute execute.description =~ "search"
    end

    # I2: a host can still advertise a search tool it emits from a
    # DIFFERENT definitions/1 call by naming it explicitly, even when this
    # call's include_search is false.
    test "execute description names an explicitly given search tool even when include_search is false",
         %{opts: opts} do
      mutating_opts =
        opts
        |> Keyword.put(:policy, :all)
        |> Keyword.put(:execute_tool_name, "execute_api_mutations")
        |> Keyword.put(:include_search, false)
        |> Keyword.put(:search_tool_name, "x_api_search")

      defs = Tools.definitions(mutating_opts)
      execute = Enum.find(defs, &(&1.name == "execute_api_mutations"))

      assert execute.description =~ "`x_api_search` tool"
    end

    test "a second definitions call with a custom execute_tool_name and no search yields exactly one tool",
         %{opts: opts} do
      mutating_opts =
        opts
        |> Keyword.put(:policy, :all)
        |> Keyword.put(:execute_tool_name, "execute_api_mutations")
        |> Keyword.put(:include_search, false)

      defs = Tools.definitions(mutating_opts)
      assert [%{name: "execute_api_mutations"}] = defs
    end

    test "policy :all description mentions mutations are allowed", %{opts: opts} do
      mutating_opts =
        opts
        |> Keyword.put(:policy, :all)
        |> Keyword.put(:execute_tool_name, "execute_api_mutations")

      defs = Tools.definitions(mutating_opts)
      execute = Enum.find(defs, &(&1.name == "execute_api_mutations"))
      assert execute.description =~ ~r/mutat/i

      # read-only (default) description must NOT claim mutations are allowed.
      default_execute =
        Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

      refute default_execute.description =~ ~r/mutating requests are allowed/i
    end

    test "a custom-named execute tool still handles calls correctly", %{opts: opts} do
      Mock.set_response(fn _c, _e -> {:ok, %{value: "v", logs: []}} end)

      mutating_opts = Keyword.put(opts, :execute_tool_name, "execute_api_mutations")

      execute =
        Tools.definitions(mutating_opts) |> Enum.find(&(&1.name == "execute_api_mutations"))

      assert {:ok, result} = execute.handler.(%{"code" => "..."}, %{})
      assert Jason.decode!(result)["result"] == "v"
    end
  end

  # M1: a host that accidentally reuses the same name for both tools would
  # otherwise get two tools sharing one name (the caller's tool-approval
  # layer, keyed by name, can only see one of them) or, worse, an execute
  # description pointing the model at itself as "the search tool". This is
  # a config mistake, so it must fail loudly at definitions/1 time.
  # I3: search hands the specs to the sandbox as one pre-encoded JSON string
  # (cached per registration in the Registry) parsed guest-side — measured 3x
  # cheaper than term conversion for a multi-MB spec — and wraps the model's
  # arrow so `specs` is in place before it runs. The model-visible contract
  # (`specs.<name>`) is unchanged.
  describe "search specs JSON handoff (I3)" do
    test "globals carry the encoded specs; the wrapper defines `specs` around the model's code",
         %{opts: opts} do
      Mock.set_response(fn code, env ->
        refute Map.has_key?(env.globals, "specs")
        assert %{"petstore" => %{"paths" => _}} = Jason.decode!(env.globals["__oapi_specs_json"])
        assert code =~ "JSON.parse"
        assert code =~ "Object.keys(specs)"
        {:ok, %{value: nil, logs: []}}
      end)

      search = Tools.definitions(opts) |> Enum.find(&(&1.name == "search_apis"))
      assert {:ok, _} = search.handler.(%{"code" => "async () => Object.keys(specs)"}, %{})
    end
  end

  # Design §5.3: optional per-call API allowlist from host context. The
  # guarantee is enforced at the request-dispatch boundary; filtering the
  # globals on top just keeps the model from being shown APIs it cannot call.
  describe "per-call API allowlist" do
    setup %{reg: reg} do
      {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())
      :ok = Registry.register(reg, "other", art, %ApiConfig{sandbox_globals: %{"id" => "o1"}})
      :ok
    end

    test "execute filters apiNames and context to the allowlist", %{opts: opts} do
      Mock.set_response(fn _code, env ->
        assert env.globals["apiNames"] == ["other"]
        assert env.globals["context"] == %{"other" => %{"id" => "o1"}}
        {:ok, %{value: nil, logs: []}}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      assert {:ok, _} = execute.handler.(%{"code" => "..."}, %{api_allowlist: ["other"]})
    end

    test "a request to a disallowed API is blocked at dispatch, naming the permitted set",
         %{opts: opts} do
      Mock.set_response(fn _code, env ->
        result = env.callbacks.request.("other", %{"method" => "GET", "path" => "/pets"})
        {:ok, %{value: result, logs: []}}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

      {:ok, result} = execute.handler.(%{"code" => "..."}, %{api_allowlist: ["petstore"]})
      decoded = Jason.decode!(result)

      assert decoded["result"]["error"] =~ "not permitted"
      assert decoded["result"]["error"] =~ "petstore"
      # The blocked attempt is still a call the operator should see (M9).
      assert [%{"api" => "other", "status" => "error"}] = decoded["calls"]
    end

    test "search shows only the allowed specs", %{opts: opts} do
      Mock.set_response(fn _code, env ->
        assert env.globals["__oapi_specs_json"] |> Jason.decode!() |> Map.keys() == ["petstore"]
        {:ok, %{value: nil, logs: []}}
      end)

      search = Tools.definitions(opts) |> Enum.find(&(&1.name == "search_apis"))
      assert {:ok, _} = search.handler.(%{"code" => "..."}, %{api_allowlist: ["petstore"]})
    end

    test "an absent allowlist means every registered API", %{opts: opts} do
      Mock.set_response(fn _code, env ->
        assert env.globals["apiNames"] == ["other", "petstore"]
        {:ok, %{value: nil, logs: []}}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      assert {:ok, _} = execute.handler.(%{"code" => "..."}, %{})
    end

    test "an empty allowlist means no APIs at all", %{opts: opts} do
      Mock.set_response(fn _code, env ->
        assert env.globals["apiNames"] == []
        refute Map.has_key?(env.globals, "context")
        {:ok, %{value: nil, logs: []}}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      assert {:ok, _} = execute.handler.(%{"code" => "..."}, %{api_allowlist: []})
    end

    test "allowlist entries for unregistered APIs are inert", %{opts: opts} do
      Mock.set_response(fn _code, env ->
        assert env.globals["apiNames"] == ["petstore"]
        {:ok, %{value: nil, logs: []}}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

      assert {:ok, _} =
               execute.handler.(%{"code" => "..."}, %{api_allowlist: ["petstore", "ghost"]})
    end

    # A malformed allowlist is a host bug, not a model mistake — raise like
    # the M1 collision guard rather than feeding the model an error it
    # cannot act on.
    test "a non-list or non-binary allowlist raises", %{opts: opts} do
      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

      assert_raise ArgumentError, fn ->
        execute.handler.(%{"code" => "..."}, %{api_allowlist: "petstore"})
      end

      assert_raise ArgumentError, fn ->
        execute.handler.(%{"code" => "..."}, %{api_allowlist: [:petstore]})
      end
    end
  end

  # ele P1: an executor whose timeout is a compute-only budget (SafeJS)
  # cannot bound a run that loops over cheap request() calls, and the
  # call-log Agent is plain BEAM memory outside any engine cap. :max_calls
  # bounds both at the layer that owns the loop, for every executor.
  describe "per-run call limit (:max_calls)" do
    test "calls beyond the limit are refused and only the first refusal is logged",
         %{opts: opts} do
      Req.Test.stub(LimitStub, fn conn -> Req.Test.json(conn, %{}) end)

      Mock.set_response(fn _code, env ->
        results =
          for _ <- 1..5 do
            env.callbacks.request.("petstore", %{
              "method" => "GET",
              "path" => "/pets",
              "query" => %{"limit" => 1}
            })
          end

        {:ok, %{value: results, logs: []}}
      end)

      opts = Keyword.put(opts, :max_calls, 2)
      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

      {:ok, result} =
        execute.handler.(%{"code" => "..."}, %{req_options: [plug: {Req.Test, LimitStub}]})

      decoded = Jason.decode!(result)
      [r1, r2, r3, _r4, r5] = decoded["result"]
      assert r1["status"] == 200
      assert r2["status"] == 200
      assert r3["error"] =~ "call limit"
      assert r5["error"] =~ "call limit"

      # Two dispatched calls plus ONE logged refusal — the log must not grow
      # with further refused attempts, or the limit re-opens the unbounded
      # memory it exists to close.
      assert [%{"status" => 200}, %{"status" => 200}, %{"status" => "error"}] = decoded["calls"]
    end

    test ":infinity disables the limit", %{opts: opts} do
      Req.Test.stub(LimitStub2, fn conn -> Req.Test.json(conn, %{}) end)

      Mock.set_response(fn _code, env ->
        results =
          for _ <- 1..3 do
            env.callbacks.request.("petstore", %{
              "method" => "GET",
              "path" => "/pets",
              "query" => %{"limit" => 1}
            })
          end

        {:ok, %{value: results, logs: []}}
      end)

      opts = Keyword.put(opts, :max_calls, :infinity)
      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

      {:ok, result} =
        execute.handler.(%{"code" => "..."}, %{req_options: [plug: {Req.Test, LimitStub2}]})

      assert [%{"status" => 200}, %{"status" => 200}, %{"status" => 200}] =
               Jason.decode!(result)["result"]
    end

    test "a junk :max_calls raises at definitions time", %{opts: opts} do
      assert_raise ArgumentError, fn ->
        Tools.definitions(Keyword.put(opts, :max_calls, 0))
      end

      assert_raise ArgumentError, fn ->
        Tools.definitions(Keyword.put(opts, :max_calls, "10"))
      end
    end

    test "a wall-clock executor error surfaces as data in the envelope", %{opts: opts} do
      Mock.set_response(fn _c, _e -> {:error, {:wall_clock, 250}} end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      {:ok, result} = execute.handler.(%{"code" => "..."}, %{})

      assert Jason.decode!(result)["error"] =~ "wall-clock"
    end
  end

  # James (via ele): making the model write idempotency headers is a bit
  # much. With ApiConfig.auto_idempotency_header set, mutating calls are
  # keyed automatically; the key (auto or explicit) is recorded in the
  # host-written call log so a retry-after-ambiguity can reuse it — the
  # in_flight pairing below is the load-bearing part.
  describe "auto idempotency keys" do
    @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    setup %{reg: reg, opts: opts} do
      {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())

      :ok =
        Registry.register(reg, "idem", art, %ApiConfig{
          auto_idempotency_header: "idempotency-key"
        })

      %{opts: Keyword.put(opts, :policy, :all)}
    end

    defp run_execute(opts, code_opts, host_ctx) do
      Mock.set_response(fn _code, env ->
        {:ok, %{value: env.callbacks.request.(code_opts.api, code_opts.req), logs: []}}
      end)

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
      {:ok, result} = execute.handler.(%{"code" => "..."}, host_ctx)
      Jason.decode!(result)
    end

    test "a mutating call without a key gets a generated one, sent and logged", %{opts: opts} do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:key_header, Plug.Conn.get_req_header(conn, "idempotency-key")})
        Req.Test.json(conn, %{})
      end

      decoded =
        run_execute(
          opts,
          %{
            api: "idem",
            req: %{
              "method" => "POST",
              "path" => "/pets",
              "body" => %{"name" => "R", "species" => "dog"}
            }
          },
          %{req_options: [plug: plug]}
        )

      assert_received {:key_header, [sent_key]}
      assert sent_key =~ @uuid_re
      assert [%{"idempotency_key" => ^sent_key, "status" => 200}] = decoded["calls"]
    end

    test "a GET is not keyed", %{opts: opts} do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:key_header, Plug.Conn.get_req_header(conn, "idempotency-key")})
        Req.Test.json(conn, %{})
      end

      decoded =
        run_execute(
          opts,
          %{
            api: "idem",
            req: %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 1}}
          },
          %{req_options: [plug: plug]}
        )

      assert_received {:key_header, []}
      assert [entry] = decoded["calls"]
      refute Map.has_key?(entry, "idempotency_key")
    end

    test "an explicit idempotencyKey option is forwarded verbatim and logged", %{opts: opts} do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:key_header, Plug.Conn.get_req_header(conn, "idempotency-key")})
        Req.Test.json(conn, %{})
      end

      decoded =
        run_execute(
          opts,
          %{
            api: "idem",
            req: %{
              "method" => "POST",
              "path" => "/pets",
              "body" => %{"name" => "R", "species" => "dog"},
              "idempotencyKey" => "my-key-1"
            }
          },
          %{req_options: [plug: plug]}
        )

      assert_received {:key_header, ["my-key-1"]}
      assert [%{"idempotency_key" => "my-key-1"}] = decoded["calls"]
    end

    test "a key supplied via the headers map is honored, not regenerated", %{opts: opts} do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:key_header, Plug.Conn.get_req_header(conn, "idempotency-key")})
        Req.Test.json(conn, %{})
      end

      decoded =
        run_execute(
          opts,
          %{
            api: "idem",
            req: %{
              "method" => "POST",
              "path" => "/pets",
              "body" => %{"name" => "R", "species" => "dog"},
              "headers" => %{"Idempotency-Key" => "hdr-key"}
            }
          },
          %{req_options: [plug: plug]}
        )

      assert_received {:key_header, ["hdr-key"]}
      assert [%{"idempotency_key" => "hdr-key"}] = decoded["calls"]
    end

    test "idempotencyKey on an API with no configured header is an actionable error, not a call",
         %{opts: opts} do
      decoded =
        run_execute(
          opts,
          %{
            api: "petstore",
            req: %{"method" => "GET", "path" => "/pets", "idempotencyKey" => "k"}
          },
          %{}
        )

      assert decoded["result"]["error"] =~ "no idempotency header"
      assert decoded["calls"] == []
    end

    test "supplying the key twice (option and headers map) is an error", %{opts: opts} do
      decoded =
        run_execute(
          opts,
          %{
            api: "idem",
            req: %{
              "method" => "POST",
              "path" => "/pets",
              "idempotencyKey" => "a",
              "headers" => %{"idempotency-key" => "b"}
            }
          },
          %{}
        )

      assert decoded["result"]["error"] =~ "once"
      assert decoded["calls"] == []
    end

    # The load-bearing pairing: a run killed mid-mutation leaves an
    # in_flight entry CARRYING ITS KEY, so the model knows exactly what to
    # resend for a safe, deduped retry.
    test "an in_flight entry carries the auto-generated key", %{opts: opts} do
      handler_pid = self()

      Mock.set_response(fn _code, env ->
        caller = self()

        spawn_monitor(fn ->
          env.callbacks.request.("idem", %{
            "method" => "POST",
            "path" => "/pets",
            "body" => %{"name" => "R", "species" => "dog"}
          })
        end)

        assert caller == handler_pid

        receive do
          :in_dispatch -> :ok
        after
          2_000 -> raise "the request callback never reached dispatch"
        end

        {:error, {:wall_clock, 123}}
      end)

      blocked_plug = fn conn ->
        send(handler_pid, :in_dispatch)
        Process.sleep(5_000)
        Req.Test.json(conn, %{})
      end

      execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

      {:ok, result} =
        execute.handler.(%{"code" => "..."}, %{req_options: [plug: blocked_plug]})

      decoded = Jason.decode!(result)
      assert [entry] = decoded["calls"]
      assert entry["status"] == "in_flight"
      assert entry["idempotency_key"] =~ @uuid_re
    end
  end

  describe "search_tool_name/execute_tool_name collision guard (M1)" do
    test "raises when the two names collide via explicit execute_tool_name", %{opts: opts} do
      bad_opts = Keyword.put(opts, :execute_tool_name, "search_apis")
      assert_raise ArgumentError, ~r/must differ/, fn -> Tools.definitions(bad_opts) end
    end

    test "raises when the two names collide via explicit search_tool_name", %{opts: opts} do
      bad_opts = Keyword.put(opts, :search_tool_name, "execute_api_code")
      assert_raise ArgumentError, ~r/must differ/, fn -> Tools.definitions(bad_opts) end
    end
  end
end
