defmodule OapiCodemode.ZapCodeEndToEndTest do
  @moduledoc """
  Full stack on the in-process NIF executor: `OapiCodemode.Executor.ZapCode`
  driving `search_apis` and `execute_api_code`, with the upstream HTTP call
  stubbed via a bare plug closure (see the Req.Test process-scoping notes in
  `end_to_end_test.exs` — ZapCode dispatches callbacks from spawned worker
  processes too, so the same ownership-sidestep applies).

  Mirrors the Deno end-to-end file, plus the two shapes that were engine
  blockers before zapcode eaa546a: multiple api calls in one run, and
  Promise.all over api calls.
  """

  use ExUnit.Case, async: true
  @moduletag :zapcode

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
      executor: OapiCodemode.Executor.ZapCode,
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

    # Safe-dialect version of the idiomatic search (see the skipped test
    # below and R2.1–R2.3, R2.7 in ex_zapcode's findings): pair indexing
    # instead of for-of head destructuring, && guards instead of ?., and
    # member chains hoisted to consts before entering the object literal.
    {:ok, found} =
      search.handler.(
        %{
          "code" => """
          async () => {
            const hits = [];
            for (const entry of Object.entries(specs.petstore.paths)) {
              const methods = entry[1];
              if (methods.get && methods.get.tags && methods.get.tags.includes("pets")) {
                const path = entry[0];
                const summary = methods.get.summary;
                hits.push({ path: path, summary: summary });
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
           )

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

  # ENGINE GAP cluster (zapcode, "round 2" findings in
  # ex_zapcode/SANDBOX_HARDENING_PLAN.md): for-of head destructuring silently
  # binds undefined (R2.1), nested for-of silently truncates (R2.2), and any
  # `?.` inside a for-of body trips "invalid iterator state" (R2.3). This
  # test is the idiomatic LLM shape — the Deno e2e runs it verbatim — and
  # exercises R2.1 + R2.3 together. Unskip when the iterator-state fix lands.
  @tag skip: "zapcode engine: for-of iterator-state cluster (R2.1–R2.3)"
  test "search with idiomatic for-of entry destructuring", %{opts: opts} do
    [search, _execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

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

    assert Enum.any?(
             Jason.decode!(found),
             &(&1["path"] == "/pets" and &1["summary"] == "List all pets")
           )
  end

  # The shape that was hard-blocked before engine eaa546a: the second
  # apis.<name>.request of a run used to find `apis` clobbered.
  test "execute makes several api calls in one run through the real proxy", %{opts: opts} do
    [_search, execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

    plug = fn conn ->
      n = conn.query_params["limit"] || "0"
      Req.Test.json(conn, %{"pets" => [%{"name" => "pet-#{n}"}]})
    end

    {:ok, result} =
      execute.handler.(
        %{
          "code" => """
          async () => {
            const a = await apis.petstore.request({ method: "GET", path: "/pets", query: { limit: 1 } });
            const b = await apis.petstore.request({ method: "GET", path: "/pets", query: { limit: 2 } });
            const c = await apis.petstore.request({ method: "GET", path: "/pets", query: { limit: 3 } });
            return [a, b, c].map(r => r.body.pets[0].name);
          }
          """
        },
        %{req_options: [plug: plug]}
      )

    decoded = Jason.decode!(result)
    assert decoded["result"] == ["pet-1", "pet-2", "pet-3"]
    assert length(decoded["calls"]) == 3
    assert Enum.all?(decoded["calls"], &(&1["status"] == 200))
  end

  # Also blocked before eaa546a: suspending inside Promise.all failed
  # snapshot capture. Resolves serially (accepted zapcode constraint).
  test "execute via Promise.all over api calls works end to end", %{opts: opts} do
    [_search, execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

    plug = fn conn ->
      Req.Test.json(conn, %{"pets" => [%{"name" => "pet-#{conn.query_params["limit"]}"}]})
    end

    {:ok, result} =
      execute.handler.(
        %{
          "code" => """
          async () => {
            const [a, b] = await Promise.all([
              apis.petstore.request({ method: "GET", path: "/pets", query: { limit: 1 } }),
              apis.petstore.request({ method: "GET", path: "/pets", query: { limit: 2 } })
            ]);
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

  test "execute against a non-existent path surfaces the [match] error as data, not a crash",
       %{opts: opts} do
    [_search, execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

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

    decoded = Jason.decode!(result)

    assert decoded["result"]["error"] =~ "[match]"
    assert decoded["result"]["error"] =~ "GET /pets"

    assert [%{"operation" => "GET /nope", "status" => "error", "api" => "petstore"}] =
             decoded["calls"]
  end

  # ENGINE GAP (zapcode R2.9 + R2.6): array indexing is O(n) — container
  # deep-copied per access — so scanning a real spec is O(n²) time, and the
  # for-of dialect instead accumulates per-iteration copies as live memory
  # (this search peaked >661MB against a 512MB cap on the 4MB fixture).
  # Search over multi-MB specs is infeasible in the current engine in any
  # dialect. Unskip when containers get reference/COW semantics.
  @tag skip: "zapcode engine: O(n²) iteration / live-copy growth on large specs (R2.9)"
  test "x_api fixture: search finds getPostsById through the NIF (4MB globals payload)",
       %{reg: reg} do
    :ok = OapiCodemode.ingest_and_register(reg, "x_api", Fixtures.x_api())

    # Value-typed representation costs far more than the JSON size: the 4MB
    # x_api globals measure ~50MB live, Object.entries deep-copies whatever
    # it iterates, and this nested search loop peaks >333MB — so search over
    # real specs needs several times zapcode's 64MB default cap. This is
    # what :executor_opts is for; the cap stays hard, just sized for the
    # workload (R2.6 in ex_zapcode's findings).
    opts = [
      registry: reg,
      executor: OapiCodemode.Executor.ZapCode,
      executor_opts: [limits: %{max_memory: 512 * 1024 * 1024}],
      resolver: Resolver,
      policy: :read_only
    ]

    [search, _execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

    # Safe dialect: classic `for` for the inner loop (nested for-of silently
    # truncates, R2.2) and member chains hoisted before the push (R2.7).
    code = """
    async () => {
      const hits = [];
      for (const pathEntry of Object.entries(specs.x_api.paths)) {
        const path = pathEntry[0];
        if (!path.includes("tweets")) continue;
        const ops = Object.entries(pathEntry[1]);
        for (let i = 0; i < ops.length; i++) {
          const method = ops[i][0];
          const op = ops[i][1];
          if (op && typeof op === "object" && op.operationId) {
            const operationId = op.operationId;
            hits.push({ path: path, method: method, operationId: operationId });
          }
        }
      }
      return hits;
    }
    """

    {elapsed_us, {:ok, found}} =
      :timer.tc(fn -> search.handler.(%{"code" => code}, %{}) end)

    elapsed_ms = elapsed_us / 1000
    IO.puts("x_api fixture search wall time (zapcode): #{Float.round(elapsed_ms, 1)} ms")
    assert elapsed_ms < 10_000

    decoded = Jason.decode!(found)
    assert Enum.any?(decoded, &(&1["operationId"] == "getPostsById"))
  end
end
