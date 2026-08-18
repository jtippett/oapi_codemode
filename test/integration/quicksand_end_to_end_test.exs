defmodule OapiCodemode.QuicksandEndToEndTest do
  @moduledoc """
  Full stack on the QuickJS-NG NIF executor: `OapiCodemode.Executor.Quicksand`
  driving `search_apis` and `execute_api_code`, upstream HTTP stubbed via a
  bare plug closure (see the Req.Test process-scoping notes in
  `end_to_end_test.exs`).

  SYNCHRONOUS contract: guest code is a plain arrow and `apis.x.request(...)`
  is a blocking call — no `await`, no `Promise.all` (see `Executor.Quicksand`).
  """

  use ExUnit.Case, async: true
  @moduletag :quicksand

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
      executor: OapiCodemode.Executor.Quicksand,
      resolver: Resolver,
      policy: :read_only
    ]

    %{reg: reg, opts: opts}
  end

  test "search filters the spec; execute calls one operation through the real proxy",
       %{opts: opts} do
    [search, execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

    {:ok, found} =
      search.handler.(
        %{
          "code" => """
          () => {
            const hits = [];
            for (const entry of Object.entries(specs.petstore.paths)) {
              const methods = entry[1];
              if (methods.get && methods.get.tags && methods.get.tags.includes("pets")) {
                hits.push({ path: entry[0], summary: methods.get.summary });
              }
            }
            return hits;
          }
          """
        },
        %{}
      )

    assert Enum.any?(
             Jason.decode!(found),
             &(&1["path"] == "/pets" and &1["summary"] == "List all pets")
           )

    plug = fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer e2e-token"]
      Req.Test.json(conn, %{"pets" => [%{"name" => "Rex"}]})
    end

    {:ok, result} =
      execute.handler.(
        %{
          "code" => """
          () => {
            const r = apis.petstore.request({ method: "GET", path: "/pets", query: { limit: 10 } });
            return r.body.pets.map(p => p.name);
          }
          """
        },
        %{req_options: [plug: plug]}
      )

    decoded = Jason.decode!(result)
    assert decoded["result"] == ["Rex"]

    assert [%{"operation" => "GET /pets", "status" => 200, "api" => "petstore"}] =
             decoded["calls"]
  end

  test "several api calls in one run through the real proxy", %{opts: opts} do
    [_search, execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

    plug = fn conn ->
      n = conn.query_params["limit"] || "0"
      Req.Test.json(conn, %{"pets" => [%{"name" => "pet-#{n}"}]})
    end

    {:ok, result} =
      execute.handler.(
        %{
          "code" => """
          () => {
            const a = apis.petstore.request({ method: "GET", path: "/pets", query: { limit: 1 } });
            const b = apis.petstore.request({ method: "GET", path: "/pets", query: { limit: 2 } });
            return [a.body.pets[0].name, b.body.pets[0].name];
          }
          """
        },
        %{req_options: [plug: plug]}
      )

    decoded = Jason.decode!(result)
    assert decoded["result"] == ["pet-1", "pet-2"]
    assert length(decoded["calls"]) == 2
  end

  test "execute against a non-existent path surfaces the [match] error as data",
       %{opts: opts} do
    [_search, execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

    {:ok, result} =
      execute.handler.(
        %{"code" => ~S|() => apis.petstore.request({ method: "GET", path: "/nope" })|},
        %{}
      )

    decoded = Jason.decode!(result)
    assert decoded["result"]["error"] =~ "[match]"
    assert decoded["result"]["error"] =~ "GET /pets"

    assert [%{"operation" => "GET /nope", "status" => "error", "api" => "petstore"}] =
             decoded["calls"]
  end

  test "x_api fixture: search finds getPostsById through the NIF (4MB globals payload)",
       %{reg: reg} do
    :ok = OapiCodemode.ingest_and_register(reg, "x_api", Fixtures.x_api())

    opts = [
      registry: reg,
      executor: OapiCodemode.Executor.Quicksand,
      resolver: Resolver,
      policy: :read_only
    ]

    [search, _execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

    code = """
    () => {
      const hits = [];
      for (const pathEntry of Object.entries(specs.x_api.paths)) {
        const path = pathEntry[0];
        if (!path.includes("tweets")) continue;
        for (const opEntry of Object.entries(pathEntry[1])) {
          const op = opEntry[1];
          if (op && typeof op === "object" && op.operationId) {
            hits.push({ path, method: opEntry[0], operationId: op.operationId });
          }
        }
      }
      return hits;
    }
    """

    {elapsed_us, {:ok, found}} =
      :timer.tc(fn -> search.handler.(%{"code" => code}, %{}) end)

    elapsed_ms = elapsed_us / 1000
    IO.puts("x_api fixture search wall time (quicksand): #{Float.round(elapsed_ms, 1)} ms")
    assert elapsed_ms < 10_000

    decoded = Jason.decode!(found)
    assert Enum.any?(decoded, &(&1["operationId"] == "getPostsById"))
  end
end
