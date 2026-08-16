defmodule OapiCodemode.ToolsTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.{Tools, Registry, Ingest, ApiConfig, Fixtures}
  alias OapiCodemode.Executor.Mock

  defmodule NoneResolver do
    @behaviour OapiCodemode.Credentials
    @impl true
    def resolve(_, _, _), do: {:ok, :none}
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
      assert %{"petstore" => %{"paths" => _}} = env.globals["specs"]
      {:ok, %{value: [%{"path" => "/pets"}], logs: []}}
    end)

    search = Tools.definitions(opts) |> Enum.find(&(&1.name == "search_apis"))
    assert {:ok, result} = search.handler.(%{"code" => "async () => spec"}, %{})
    assert result =~ ~s([{"path":"/pets"}])
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
    test "context and apiNames globals reach the sandbox", %{reg: reg, opts: opts} do
      {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())

      :ok =
        Registry.register(reg, "petstore", art, %ApiConfig{context: %{"storeId" => "s1"}})

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
end
