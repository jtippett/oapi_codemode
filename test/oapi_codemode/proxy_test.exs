defmodule OapiCodemode.ProxyTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.{Proxy, Ingest, ApiConfig, Fixtures}
  alias OapiCodemode.Registry.Entry

  defmodule StaticResolver do
    @behaviour OapiCodemode.Credentials
    @impl true
    def resolve("petstore", _scheme, %{token: token}), do: {:ok, {:bearer, token}}
    def resolve(_, _, _), do: {:error, :no_credential}
  end

  setup do
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())

    entry = %Entry{
      artifact: art,
      config: %ApiConfig{base_url: "https://petstore.example.com/v1"}
    }

    ctx = %{
      resolver: StaticResolver,
      context: %{token: "tok-1"},
      policy: :all,
      req_options: [plug: {Req.Test, OapiCodemodeStub}]
    }

    %{entry: entry, ctx: ctx}
  end

  test "happy path: GET with auth and query", %{entry: entry, ctx: ctx} do
    Req.Test.stub(OapiCodemodeStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok-1"]
      assert conn.request_path == "/v1/pets"
      assert conn.query_string =~ "limit=5"
      Req.Test.json(conn, %{"pets" => []})
    end)

    assert {:ok, resp} =
             Proxy.request(
               entry,
               "petstore",
               %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 5}},
               ctx
             )

    assert resp.status == 200
    assert resp.body == %{"pets" => []}
  end

  test "path params substitute into the URL", %{entry: entry, ctx: ctx} do
    Req.Test.stub(OapiCodemodeStub, fn conn ->
      assert conn.request_path == "/v1/pets/42"
      Req.Test.json(conn, %{"id" => "42"})
    end)

    assert {:ok, %{status: 200}} =
             Proxy.request(entry, "petstore", %{"method" => "GET", "path" => "/pets/42"}, ctx)
  end

  test "unknown path rejects with suggestions before any HTTP", %{entry: entry, ctx: ctx} do
    assert {:error, %{phase: :match, message: msg}} =
             Proxy.request(entry, "petstore", %{"method" => "GET", "path" => "/petz"}, ctx)

    assert msg =~ "GET /pets"
  end

  test "validation failure rejects before any HTTP", %{entry: entry, ctx: ctx} do
    assert {:error, %{phase: :validate, message: msg}} =
             Proxy.request(entry, "petstore", %{"method" => "GET", "path" => "/pets"}, ctx)

    assert msg =~ "limit"
  end

  test "read_only policy rejects non-GET", %{entry: entry, ctx: ctx} do
    ctx = %{ctx | policy: :read_only}

    assert {:error, %{phase: :policy, message: msg}} =
             Proxy.request(
               entry,
               "petstore",
               %{
                 "method" => "POST",
                 "path" => "/pets",
                 "body" => %{"name" => "R", "species" => "dog"}
               },
               ctx
             )

    assert msg =~ "read-only"
  end

  test "credential failure is distinct from upstream 401", %{entry: entry, ctx: ctx} do
    ctx = %{ctx | context: %{}}

    assert {:error, %{phase: :credentials}} =
             Proxy.request(
               entry,
               "petstore",
               %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 1}},
               ctx
             )
  end

  test "upstream errors pass through as responses", %{entry: entry, ctx: ctx} do
    Req.Test.stub(OapiCodemodeStub, fn conn ->
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "slow down"})
    end)

    assert {:ok, %{status: 429, body: %{"error" => _}}} =
             Proxy.request(
               entry,
               "petstore",
               %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 1}},
               ctx
             )
  end

  test "JSON body is posted; response headers are whitelisted", %{entry: entry, ctx: ctx} do
    Req.Test.stub(OapiCodemodeStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw)["species"] == "dog"

      conn
      |> Plug.Conn.put_resp_header("x-secret-internal", "hide-me")
      |> Plug.Conn.put_resp_header("x-request-id", "req-9")
      |> Req.Test.json(%{"ok" => true})
    end)

    {:ok, resp} =
      Proxy.request(
        entry,
        "petstore",
        %{"method" => "POST", "path" => "/pets", "body" => %{"name" => "R", "species" => "dog"}},
        ctx
      )

    assert {"x-request-id", "req-9"} in resp.headers
    refute Enum.any?(resp.headers, fn {k, _} -> k == "x-secret-internal" end)
  end

  test "emits telemetry", %{entry: entry, ctx: ctx} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:oapi_codemode, :request, :stop]])

    Req.Test.stub(OapiCodemodeStub, fn conn -> Req.Test.json(conn, %{}) end)

    {:ok, _} =
      Proxy.request(
        entry,
        "petstore",
        %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 1}},
        ctx
      )

    assert_receive {[:oapi_codemode, :request, :stop], ^ref, %{duration: _},
                    %{api: "petstore", operation: "listPets", status: 200}}
  end
end
