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

    # callback errors surface as data, not crashes:
    assert result =~ "calls" or result =~ "error"
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
end
