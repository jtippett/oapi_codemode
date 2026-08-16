defmodule OapiCodemode.EndToEndTest do
  @moduledoc """
  Full stack: real Deno sandbox (deno on PATH) driving `search_apis` and
  `execute_api_code`, with the upstream HTTP call stubbed via `Req.Test`.

  ## Req.Test process-scoping

  `OapiCodemode.Executor.Deno` dispatches each intercepted `request()` call
  from its own `Task.start/1` process (see `dispatch_callback/4` in
  `lib/oapi_codemode/executor/deno.ex`) so concurrent `Promise.all` calls
  can be in flight together. `Req.Test` stubs registered with
  `Req.Test.stub(name, plug)` + `plug: {Req.Test, name}` are owned by the
  calling process via `nimble_ownership` (confirmed by reading
  `deps/req/lib/req/test.ex` and `Req.Plug.call_plug/2` in
  `deps/req/lib/req/plug.ex`) — an unrelated, unallowed `Task` process has
  no access to another process's stub, so that combination would 500 with
  an ownership error from inside the callback, not reach our plug at all.

  `Req.Plug.call_plug/2` also accepts a bare 1-arity function
  (`is_function(plug, 1)`) with no ownership lookup whatsoever. Passing
  `req_options: [plug: fn conn -> ... end]` — a closure, not a
  `{Req.Test, name}` tuple — sidesteps the ownership system entirely: the
  closure is just data, callable from any process, and can still assert on
  the connection and capture whatever the test needs by value. That is the
  approach used below.

  This test is `async: false` regardless (it spawns a `deno` subprocess per
  case) and tagged `:deno` so it is skipped in environments without Deno on
  PATH, per `test/test_helper.exs`.
  """

  use ExUnit.Case, async: false
  @moduletag :deno

  alias OapiCodemode.{Registry, Fixtures}

  defmodule Resolver do
    @behaviour OapiCodemode.Credentials
    @impl true
    def resolve("petstore", _scheme, _request, _ctx), do: {:ok, {:bearer, "e2e-token"}}
    def resolve(_api, _scheme, _request, _ctx), do: {:ok, :none}
  end

  setup do
    reg = start_supervised!({Registry, name: nil})
    :ok = OapiCodemode.ingest_and_register(reg, "petstore", Fixtures.clean_3_1())

    opts = [
      registry: reg,
      executor: OapiCodemode.Executor.Deno,
      resolver: Resolver,
      policy: :read_only
    ]

    %{reg: reg, opts: opts}
  end

  test "search finds operations via JS over the spec; execute calls one through the real proxy",
       %{opts: opts} do
    [search, execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

    assert search.name == "search_apis"
    assert execute.name == "execute_api_code"

    # 1. Search: LLM-shaped JS filters the spec-as-data for GET operations
    # tagged "pets".
    {:ok, found} =
      search.handler.(
        %{
          "code" => """
          async () => {
            const hits = [];
            for (const [path, methods] of Object.entries(specs.petstore.paths)) {
              if (methods.get?.tags?.includes("pets")) {
                hits.push({ path, summary: methods.get.summary });
              }
            }
            return hits;
          }
          """
        },
        %{}
      )

    decoded_found = Jason.decode!(found)

    assert Enum.any?(
             decoded_found,
             &(&1["path"] == "/pets" and &1["summary"] == "List all pets")
             # listPets is the GET /pets operation the search above surfaces.
           )

    # 2. Execute: LLM-shaped JS calls apis.petstore.request(...), which the
    # Deno bootstrap intercepts and routes through Elixir -> Proxy -> stub.
    plug = fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer e2e-token"]
      Req.Test.json(conn, %{"pets" => [%{"name" => "Rex"}]})
    end

    {:ok, result} =
      execute.handler.(
        %{
          "code" => """
          async () => {
            const r = await apis.petstore.request({ method: "GET", path: "/pets", query: { limit: 10 } });
            return r.body.pets.map(p => p.name);
          }
          """
        },
        %{req_options: [plug: plug]}
      )

    decoded = Jason.decode!(result)
    assert decoded["result"] == ["Rex"]

    assert [%{"operation" => "GET /pets", "status" => 200} = call] = decoded["calls"]
    assert call["api"] == "petstore"
    assert is_integer(call["duration_ms"])
  end

  test "execute against a non-existent path surfaces the [match] error as data, not a crash",
       %{opts: opts} do
    [_search, execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

    # No upstream stub needed: the matcher rejects before any HTTP call.
    {:ok, result} =
      execute.handler.(
        %{
          "code" => """
          async () => {
            const r = await apis.petstore.request({ method: "GET", path: "/nope" });
            return r;
          }
          """
        },
        %{}
      )

    # The model-visible envelope must still decode as JSON even though the
    # request failed — the failure is data inside it, not a thrown error.
    decoded = Jason.decode!(result)

    assert decoded["result"]["error"] =~ "[match]"
    # Nearest-suggestion behavior (Matcher) should point back at real ops.
    assert decoded["result"]["error"] =~ "GET /pets"

    assert [%{"operation" => "GET /nope", "status" => "error", "api" => "petstore"}] =
             decoded["calls"]
  end

  test "x_api fixture: search finds getPostsById through the real sandbox (4MB globals payload)",
       %{reg: reg} do
    :ok = OapiCodemode.ingest_and_register(reg, "x_api", Fixtures.x_api())

    opts = [
      registry: reg,
      executor: OapiCodemode.Executor.Deno,
      resolver: Resolver,
      policy: :read_only
    ]

    [search, _execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

    code = """
    async () => {
      const hits = [];
      for (const [path, methods] of Object.entries(specs.x_api.paths)) {
        if (!path.includes("tweets")) continue;
        for (const [method, op] of Object.entries(methods)) {
          if (op && typeof op === "object" && op.operationId) {
            hits.push({ path, method, operationId: op.operationId });
          }
        }
      }
      return hits;
    }
    """

    {elapsed_us, {:ok, found}} =
      :timer.tc(fn -> search.handler.(%{"code" => code}, %{}) end)

    elapsed_ms = elapsed_us / 1000
    IO.puts("x_api fixture search wall time: #{Float.round(elapsed_ms, 1)} ms")
    assert elapsed_ms < 10_000

    decoded = Jason.decode!(found)
    assert Enum.any?(decoded, &(&1["operationId"] == "getPostsById"))
  end
end
