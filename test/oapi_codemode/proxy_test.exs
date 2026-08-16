defmodule OapiCodemode.ProxyTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias OapiCodemode.{Proxy, Ingest, ApiConfig, Fixtures, Artifact, Operation}
  alias OapiCodemode.Registry.Entry

  defmodule StaticResolver do
    @behaviour OapiCodemode.Credentials
    @impl true
    def resolve("petstore", _scheme, %{token: token}), do: {:ok, {:bearer, token}}
    def resolve(_, _, _), do: {:error, :no_credential}
  end

  defmodule NoAuthResolver do
    @behaviour OapiCodemode.Credentials
    @impl true
    def resolve(_api_name, _scheme, _context), do: {:ok, :none}
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

    capture_log(fn ->
      assert {:error, %{phase: :credentials}} =
               Proxy.request(
                 entry,
                 "petstore",
                 %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 1}},
                 ctx
               )
    end)
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

    # I4: headers come back as a map, matching the TS `Record<string,string>`
    # the execute tool declares.
    assert resp.headers["x-request-id"] == "req-9"
    refute Map.has_key?(resp.headers, "x-secret-internal")
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

  describe "custom-operation pipeline wiring (I3, I5, M9)" do
    defp custom_entry(operations) do
      artifact = %Artifact{spec: %{}, operations: operations, security_schemes: %{}}

      %Entry{
        artifact: artifact,
        config: %ApiConfig{base_url: "https://api.example.com", validate: :strict}
      }
    end

    defp noauth_ctx do
      %{
        resolver: NoAuthResolver,
        context: %{},
        policy: :all,
        req_options: [plug: {Req.Test, OapiCodemodeStub}]
      }
    end

    # I3: an unserializable query value (nested map, no deepObject style)
    # must surface as a clean :validate-phase error, not crash the request
    # pipeline inside Query.encode/1.
    test "unserializable query param surfaces as a :validate-phase error" do
      op = %Operation{
        id: "op",
        method: "get",
        path: "/items",
        segments: ["items"],
        parameters: [
          %{
            "name" => "filter",
            "in" => "query",
            "required" => false,
            "schema" => %{"type" => "object"}
          }
        ]
      }

      entry = custom_entry([op])

      assert {:error, %{phase: :validate, message: msg}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{
                   "method" => "GET",
                   "path" => "/items",
                   "query" => %{"filter" => %{"a" => %{"b" => 1}}}
                 },
                 noauth_ctx()
               )

      assert msg =~ "filter"
    end

    # I5: a path param bound by the matcher is now validated against its
    # schema; a bad value rejects before any HTTP call.
    test "invalid path param surfaces as a :validate-phase error" do
      op = %Operation{
        id: "op",
        method: "get",
        path: "/items/{id}",
        segments: ["items", {:param, "id"}],
        parameters: [
          %{
            "name" => "id",
            "in" => "path",
            "required" => true,
            "schema" => %{"type" => "integer"}
          }
        ]
      }

      entry = custom_entry([op])

      assert {:error, %{phase: :validate, message: msg}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{"method" => "GET", "path" => "/items/abc"},
                 noauth_ctx()
               )

      assert msg =~ "id"
      assert msg =~ "integer"
    end

    # M9: a path param value is RFC 3986 path-segment encoded, not
    # www-form encoded — a space becomes "%20" (not "+").
    test "path param with a space is percent-encoded, not plus-encoded" do
      op = %Operation{
        id: "op",
        method: "get",
        path: "/items/{code}",
        segments: ["items", {:param, "code"}],
        parameters: [%{"name" => "code", "in" => "path", "required" => true, "schema" => %{}}]
      }

      entry = custom_entry([op])

      Req.Test.stub(OapiCodemodeStub, fn conn ->
        assert conn.request_path == "/items/a%20b"
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{status: 200}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{"method" => "GET", "path" => "/items/a b"},
                 noauth_ctx()
               )
    end

    # M9: a path param value that carries an already-percent-encoded slash
    # (a literal "%2F"/".." traversal attempt smuggled in as segment text)
    # must not be decoded into an extra path segment — it stays as one
    # inert, double-escaped segment on the wire.
    test "a percent-encoded traversal attempt inside a path param stays neutralized" do
      op = %Operation{
        id: "op",
        method: "get",
        path: "/items/{code}",
        segments: ["items", {:param, "code"}],
        parameters: [%{"name" => "code", "in" => "path", "required" => true, "schema" => %{}}]
      }

      entry = custom_entry([op])

      Req.Test.stub(OapiCodemodeStub, fn conn ->
        assert conn.request_path == "/items/..%252f..%252fetc%252fpasswd"
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{status: 200}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{"method" => "GET", "path" => "/items/..%2f..%2fetc%2fpasswd"},
                 noauth_ctx()
               )
    end
  end

  describe "security boundary (C1, C2, I2, I3, I5, M2)" do
    defmodule ExpiredResolver do
      @behaviour OapiCodemode.Credentials
      @impl true
      def resolve(_, _, _), do: {:error, {:expired, "tok-SECRET"}}
    end

    defmodule MalformedSecretResolver do
      @behaviour OapiCodemode.Credentials
      @impl true
      def resolve(_, _, _), do: {:ok, {:bearer, "tok-SECRET\n"}}
    end

    defmodule QueryKeyResolver do
      @behaviour OapiCodemode.Credentials
      @impl true
      def resolve(_, _, _), do: {:ok, {:api_key, "sk-QUERY-SECRET"}}
    end

    defp free_entry(operations, opts \\ []) do
      artifact = %Artifact{
        spec: %{},
        operations: operations,
        security_schemes: Keyword.get(opts, :security_schemes, %{})
      }

      config =
        struct!(
          ApiConfig,
          Keyword.merge(
            [base_url: "https://api.example.com", validate: :off],
            Keyword.take(opts, [:max_response_bytes, :validate, :security_scheme])
          )
        )

      %Entry{artifact: artifact, config: config}
    end

    defp free_ctx(resolver \\ NoAuthResolver) do
      %{
        resolver: resolver,
        context: %{},
        policy: :all,
        req_options: [plug: {Req.Test, OapiCodemodeStub}]
      }
    end

    defp get_op(path, segments, params \\ []) do
      %Operation{id: "op", method: "get", path: path, segments: segments, parameters: params}
    end

    # C1(a): Mint's invalid-header errors embed the raw credential value, so
    # a transport error message must never reach the caller — only a fixed
    # string plus the exception's module name.
    test "transport errors return a fixed message, with detail only in the log" do
      entry = free_entry([get_op("/items", ["items"])])

      ctx = %{
        free_ctx()
        | req_options: [plug: fn conn -> Req.Test.transport_error(conn, :econnrefused) end]
      }

      log =
        capture_log(fn ->
          assert {:error, %{phase: :transport, message: msg}} =
                   Proxy.request(entry, "custom", %{"method" => "GET", "path" => "/items"}, ctx)

          assert msg == "upstream request failed (Req.TransportError)"
        end)

      assert log =~ "econnrefused"
    end

    # C1(b): a host resolver's failure reason can embed a token; neither the
    # token nor the reason detail may appear in the returned message.
    test "credential resolution failures are redacted" do
      entry = free_entry([get_op("/items", ["items"])])

      log =
        capture_log(fn ->
          assert {:error, %{phase: :credentials, message: msg}} =
                   Proxy.request(
                     entry,
                     "custom",
                     %{"method" => "GET", "path" => "/items"},
                     free_ctx(ExpiredResolver)
                   )

          assert msg == "credential resolution failed"
          refute msg =~ "tok-SECRET"
          refute msg =~ "expired"
        end)

      assert log =~ "tok-SECRET"
    end

    # C1(c): a malformed secret is rejected in the credentials phase, before
    # Mint can echo it back inside an invalid_header_value error.
    test "a credential with a non-printable byte is rejected before the request" do
      entry =
        free_entry([get_op("/items", ["items"])],
          security_schemes: %{"bearerAuth" => %{"type" => "http", "scheme" => "bearer"}},
          security_scheme: "bearerAuth"
        )

      Req.Test.stub(OapiCodemodeStub, fn _conn -> flunk("no HTTP should happen") end)

      assert {:error, %{phase: :credentials, message: msg}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{"method" => "GET", "path" => "/items"},
                 free_ctx(MalformedSecretResolver)
               )

      assert msg == "credential contains non-printable characters"
      refute msg =~ "tok-SECRET"
    end

    # C2: an LLM-supplied query key that collides with an auth query key
    # would let sandbox code overwrite (or read back) the injected
    # credential. Reject in the policy phase, before any request is built.
    test "an LLM query key colliding with the auth query key is rejected" do
      entry =
        free_entry([get_op("/items", ["items"])],
          security_schemes: %{
            "keyAuth" => %{"type" => "apiKey", "in" => "query", "name" => "api_key"}
          },
          security_scheme: "keyAuth"
        )

      Req.Test.stub(OapiCodemodeStub, fn _conn -> flunk("no HTTP should happen") end)

      assert {:error, %{phase: :policy, message: msg}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{"method" => "GET", "path" => "/items", "query" => %{"api_key" => "attacker"}},
                 free_ctx(QueryKeyResolver)
               )

      assert msg == "query parameter api_key is reserved for authentication"
    end

    test "a non-colliding query leaves exactly one auth query param on the wire" do
      entry =
        free_entry([get_op("/items", ["items"])],
          security_schemes: %{
            "keyAuth" => %{"type" => "apiKey", "in" => "query", "name" => "api_key"}
          },
          security_scheme: "keyAuth"
        )

      Req.Test.stub(OapiCodemodeStub, fn conn ->
        assert Plug.Conn.fetch_query_params(conn).query_params["api_key"] == "sk-QUERY-SECRET"
        assert length(Regex.scan(~r/(^|&)api_key=/, conn.query_string)) == 1
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{status: 200}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{"method" => "GET", "path" => "/items", "query" => %{"limit" => 1}},
                 free_ctx(QueryKeyResolver)
               )
    end

    # I2: rawBody with a non-binary body raises ArgumentError deep inside Req
    # ("not iodata"). Reject it as a request-shape problem instead.
    test "rawBody with a non-string body is a validate error" do
      op = %Operation{id: "op", method: "post", path: "/items", segments: ["items"]}
      entry = free_entry([op])

      Req.Test.stub(OapiCodemodeStub, fn _conn -> flunk("no HTTP should happen") end)

      assert {:error, %{phase: :validate, message: "rawBody requires a string body"}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{
                   "method" => "POST",
                   "path" => "/items",
                   "rawBody" => true,
                   "body" => %{"a" => 1}
                 },
                 free_ctx()
               )
    end

    test "rawBody with a string body is sent verbatim" do
      op = %Operation{id: "op", method: "post", path: "/items", segments: ["items"]}
      entry = free_entry([op])

      Req.Test.stub(OapiCodemodeStub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert raw == "a,b\n1,2\n"
        assert Plug.Conn.get_req_header(conn, "content-type") == ["text/csv"]
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{status: 200}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{
                   "method" => "POST",
                   "path" => "/items",
                   "rawBody" => true,
                   "contentType" => "text/csv",
                   "body" => "a,b\n1,2\n"
                 },
                 free_ctx()
               )
    end

    # I3(a): the cap is a BYTE cap. String.slice/3 counted graphemes, so a
    # 100-"byte" cap let 200 bytes of multibyte text through.
    test "a multibyte body is capped by bytes, not graphemes" do
      entry = free_entry([get_op("/items", ["items"])], max_response_bytes: 100)

      Req.Test.stub(OapiCodemodeStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, String.duplicate("é", 300))
      end)

      assert {:ok, %{body: body}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{"method" => "GET", "path" => "/items"},
                 free_ctx()
               )

      [prefix, _marker] = String.split(body, "\n[truncated:", parts: 2)
      assert byte_size(prefix) <= 100
      assert String.valid?(prefix)
    end

    test "a byte cap landing mid-codepoint trims back to a valid boundary" do
      entry = free_entry([get_op("/items", ["items"])], max_response_bytes: 101)

      Req.Test.stub(OapiCodemodeStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, String.duplicate("é", 300))
      end)

      assert {:ok, %{body: body}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{"method" => "GET", "path" => "/items"},
                 free_ctx()
               )

      [prefix, _] = String.split(body, "\n[truncated:", parts: 2)
      assert String.valid?(prefix)
      assert byte_size(prefix) == 100
    end

    # I3(b): raw invalid-UTF8 bytes flowing onward crash Jason.encode!
    # downstream. Wrap them in a base64 envelope instead.
    test "a non-UTF8 body comes back base64-wrapped, not as raw bytes" do
      entry = free_entry([get_op("/items", ["items"])])
      latin1 = <<"name,city\nJos", 0xE9, ",Z", 0xFC, "rich\n">>

      Req.Test.stub(OapiCodemodeStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/csv")
        |> Plug.Conn.send_resp(200, latin1)
      end)

      assert {:ok, %{body: body}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{"method" => "GET", "path" => "/items"},
                 free_ctx()
               )

      assert body["encoding"] == "base64"
      assert Base.decode64!(body["data"]) == latin1
      assert body["note"] =~ "not valid UTF-8"
      assert body["truncated"] == false
      # the whole envelope survives JSON encoding — the downstream crash repro
      assert is_binary(Jason.encode!(body))
    end

    test "an oversized non-UTF8 body is truncated inside the envelope, not marked in text" do
      entry = free_entry([get_op("/items", ["items"])], max_response_bytes: 16)
      blob = :binary.copy(<<0xE9, 0xFF>>, 50)

      Req.Test.stub(OapiCodemodeStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, blob)
      end)

      assert {:ok, %{body: body}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{"method" => "GET", "path" => "/items"},
                 free_ctx()
               )

      assert body["truncated"] == true
      assert body["bytes"] == 100
      assert byte_size(Base.decode64!(body["data"])) == 16
      refute body["data"] =~ "truncated: response exceeded"
    end

    # I3(c): an oversized decoded-JSON body used to be silently replaced by a
    # truncated, unparseable string. Return a structured marker instead.
    test "an oversized JSON body becomes a structured preview, not a broken string" do
      entry = free_entry([get_op("/items", ["items"])], max_response_bytes: 50)

      Req.Test.stub(OapiCodemodeStub, fn conn ->
        Req.Test.json(conn, %{"items" => Enum.map(1..50, &%{"id" => &1})})
      end)

      assert {:ok, %{body: body}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{"method" => "GET", "path" => "/items"},
                 free_ctx()
               )

      assert body["truncated"] == true
      assert body["bytes"] > 50
      assert is_binary(body["preview"])
      assert byte_size(body["preview"]) <= 50
    end

    # I5: a redirect must come back as data. Following it would re-send the
    # Authorization header to whatever host the upstream names.
    test "redirects are not followed" do
      entry = free_entry([get_op("/items", ["items"])])
      {:ok, hits} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(OapiCodemodeStub, fn conn ->
        Agent.update(hits, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_header("location", "https://evil.example.com/steal")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:ok, %{status: 302}} =
               Proxy.request(
                 entry,
                 "custom",
                 %{"method" => "GET", "path" => "/items"},
                 free_ctx()
               )

      assert Agent.get(hits, & &1) == 1
    end

    test "a host can re-enable redirects through req_options" do
      entry = free_entry([get_op("/items", ["items"])])
      {:ok, hits} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(OapiCodemodeStub, fn conn ->
        n = Agent.get_and_update(hits, &{&1 + 1, &1 + 1})

        if n == 1 do
          conn
          |> Plug.Conn.put_resp_header("location", "https://api.example.com/landed")
          |> Plug.Conn.send_resp(302, "")
        else
          Req.Test.json(conn, %{"landed" => true})
        end
      end)

      ctx = free_ctx()
      ctx = %{ctx | req_options: ctx.req_options ++ [redirect: true]}

      assert {:ok, %{status: 200, body: %{"landed" => true}}} =
               Proxy.request(entry, "custom", %{"method" => "GET", "path" => "/items"}, ctx)

      assert Agent.get(hits, & &1) == 2
    end

    # M2: the error telemetry event was missing duration and the matched
    # operation, so a failing operation was invisible in dashboards.
    test "the error telemetry event carries duration and the matched operation" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:oapi_codemode, :request, :error]])
      entry = free_entry([get_op("/items", ["items"])], validate: :strict)

      capture_log(fn ->
        assert {:error, %{phase: :credentials}} =
                 Proxy.request(
                   entry,
                   "custom",
                   %{"method" => "GET", "path" => "/items"},
                   free_ctx(ExpiredResolver)
                 )
      end)

      assert_receive {[:oapi_codemode, :request, :error], ^ref, %{duration: d},
                      %{api: "custom", operation: "op", error: :credentials}}

      assert is_integer(d)
    end

    test "the error telemetry event reports a nil operation when matching failed" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:oapi_codemode, :request, :error]])
      entry = free_entry([get_op("/items", ["items"])])

      assert {:error, %{phase: :match}} =
               Proxy.request(entry, "custom", %{"method" => "GET", "path" => "/nope"}, free_ctx())

      assert_receive {[:oapi_codemode, :request, :error], ^ref, %{duration: _},
                      %{operation: nil, error: :match}}
    end
  end
end
