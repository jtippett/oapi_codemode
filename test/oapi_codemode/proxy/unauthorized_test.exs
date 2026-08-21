defmodule OapiCodemode.Proxy.UnauthorizedTest do
  @moduledoc """
  Reactive credential refresh: `Credentials.unauthorized/4` gets one chance to
  hand back a fresh credential when the upstream answers 401, and the library
  re-sends the identical request exactly once.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias OapiCodemode.{ApiConfig, Fixtures, Ingest, Proxy}
  alias OapiCodemode.Registry.Entry

  @old "tok-old-secret"
  @new "tok-new-secret"

  # The refresh behaviour is per-test: the resolver runs in the test process,
  # so the process dictionary is the simplest place to put it, and a
  # self-message is the call counter.
  defmodule RefreshResolver do
    @behaviour OapiCodemode.Credentials

    @impl true
    def resolve(_api, _scheme, _request, _ctx), do: {:ok, {:bearer, "tok-old-secret"}}

    @impl true
    def unauthorized(api, scheme, request, ctx) do
      send(self(), {:unauthorized_called, api, request})
      Process.get(:refresh).(api, scheme, request, ctx)
    end
  end

  defmodule PlainResolver do
    @behaviour OapiCodemode.Credentials

    @impl true
    def resolve(_api, _scheme, _request, _ctx), do: {:ok, {:bearer, "tok-old-secret"}}
  end

  # Implements the callback, but never supplies a credential: a 401 here is
  # the upstream refusing an ANONYMOUS request, not a stale token.
  defmodule AnonymousResolver do
    @behaviour OapiCodemode.Credentials

    @impl true
    def resolve(_api, _scheme, _request, _ctx), do: {:ok, :none}

    @impl true
    def unauthorized(api, _scheme, request, _ctx) do
      send(self(), {:unauthorized_called, api, request})
      {:retry, {:bearer, "tok-new-secret"}}
    end
  end

  setup do
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())

    entry = %Entry{
      artifact: art,
      config: %ApiConfig{
        base_url: "https://petstore.example.com/v1",
        auto_idempotency_header: "idempotency-key"
      }
    }

    ctx = %{
      resolver: RefreshResolver,
      context: %{tenant: "acme"},
      policy: :all,
      req_options: [plug: {Req.Test, OapiCodemodeUnauthorizedStub}]
    }

    %{entry: entry, ctx: ctx}
  end

  # Records every attempt (headers + raw body) and replies with the next
  # scripted response. The plug may run outside the test process, so the log
  # lives in an Agent rather than a mailbox.
  defp script(responses) do
    {:ok, agent} = Agent.start_link(fn -> {responses, []} end)

    Req.Test.stub(OapiCodemodeUnauthorizedStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      attempt = %{
        authorization: Plug.Conn.get_req_header(conn, "authorization"),
        idempotency_key: Plug.Conn.get_req_header(conn, "idempotency-key"),
        body: raw,
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string
      }

      responder =
        Agent.get_and_update(agent, fn {[next | rest], log} ->
          {next, {rest, log ++ [attempt]}}
        end)

      responder.(conn)
    end)

    agent
  end

  defp attempts(agent), do: Agent.get(agent, fn {_, log} -> log end)

  defp status(code, body) do
    fn conn -> conn |> Plug.Conn.put_status(code) |> Req.Test.json(body) end
  end

  defp post_pets do
    %{
      "method" => "POST",
      "path" => "/pets",
      "body" => %{"name" => "R", "species" => "dog"},
      "headers" => %{"idempotency-key" => "idem-abc"}
    }
  end

  defp get_pets, do: %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 1}}

  test "a 401 refreshed by the host is retried once with the new credential", %{
    entry: entry,
    ctx: ctx
  } do
    Process.put(:refresh, fn _api, _scheme, _request, _ctx -> {:retry, {:bearer, @new}} end)

    agent =
      script([
        status(401, %{"error" => "expired"}),
        fn conn ->
          conn
          |> Plug.Conn.put_resp_header("x-request-id", "req-2")
          |> Plug.Conn.put_resp_header("x-secret-internal", "hide-me")
          |> Req.Test.json(%{"ok" => true})
        end
      ])

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:oapi_codemode, :request, :stop],
        [:oapi_codemode, :request, :retry]
      ])

    assert {:ok, resp} = Proxy.request(entry, "petstore", post_pets(), ctx)
    assert resp.status == 200
    assert resp.body == %{"ok" => true}

    # Normalization applies to whichever response is returned.
    assert resp.headers["x-request-id"] == "req-2"
    refute Map.has_key?(resp.headers, "x-secret-internal")

    assert [first, second] = attempts(agent)
    assert first.authorization == ["Bearer #{@old}"]
    assert second.authorization == ["Bearer #{@new}"]

    # Everything but the credential is byte-identical, idempotency key included.
    assert first.body == second.body
    assert first.idempotency_key == ["idem-abc"]
    assert second.idempotency_key == ["idem-abc"]
    assert first.method == second.method
    assert first.path == second.path
    assert first.query == second.query

    assert_received {:unauthorized_called, "petstore", %{method: "post", path: "/pets"}}

    assert_receive {[:oapi_codemode, :request, :retry], ^ref, %{},
                    %{api: "petstore", operation: "createPet", method: "post", status: 401}}

    assert_receive {[:oapi_codemode, :request, :stop], ^ref, %{duration: _},
                    %{api: "petstore", status: 200, retried: true}}
  end

  test "no credential value appears in the retry telemetry meta", %{entry: entry, ctx: ctx} do
    Process.put(:refresh, fn _, _, _, _ -> {:retry, {:bearer, @new}} end)
    script([status(401, %{}), status(200, %{})])

    ref = :telemetry_test.attach_event_handlers(self(), [[:oapi_codemode, :request, :retry]])

    assert {:ok, %{status: 200}} = Proxy.request(entry, "petstore", get_pets(), ctx)

    assert_receive {[:oapi_codemode, :request, :retry], ^ref, %{}, meta}
    refute inspect(meta) =~ "tok-"
  end

  test ":pass hands the 401 back untouched, with one upstream call", %{entry: entry, ctx: ctx} do
    Process.put(:refresh, fn _, _, _, _ -> :pass end)
    agent = script([status(401, %{"error" => "nope"})])

    ref = :telemetry_test.attach_event_handlers(self(), [[:oapi_codemode, :request, :stop]])

    assert {:ok, %{status: 401, body: %{"error" => "nope"}}} =
             Proxy.request(entry, "petstore", get_pets(), ctx)

    assert length(attempts(agent)) == 1
    assert_received {:unauthorized_called, _, _}
    refute_received {:unauthorized_called, _, _}

    assert_receive {[:oapi_codemode, :request, :stop], ^ref, %{duration: _},
                    %{status: 401, retried: false}}
  end

  test "a raising callback yields the original 401 and never logs the token", %{
    entry: entry,
    ctx: ctx
  } do
    Process.put(:refresh, fn _, _, _, _ -> raise "boom #{@old}" end)
    agent = script([status(401, %{"error" => "nope"})])

    log =
      capture_log(fn ->
        assert {:ok, %{status: 401, body: %{"error" => "nope"}}} =
                 Proxy.request(entry, "petstore", get_pets(), ctx)
      end)

    assert length(attempts(agent)) == 1
    refute log =~ "tok-"
    assert log =~ "RuntimeError"
  end

  test "an exiting callback yields the original 401", %{entry: entry, ctx: ctx} do
    Process.put(:refresh, fn _, _, _, _ -> exit({:shutdown, @old}) end)
    agent = script([status(401, %{"error" => "nope"})])

    log =
      capture_log(fn ->
        assert {:ok, %{status: 401}} = Proxy.request(entry, "petstore", get_pets(), ctx)
      end)

    assert length(attempts(agent)) == 1
    refute log =~ "tok-"
  end

  test "an unexpected return shape yields the original 401 and is not logged verbatim", %{
    entry: entry,
    ctx: ctx
  } do
    Process.put(:refresh, fn _, _, _, _ -> {:retry_with, @old} end)
    agent = script([status(401, %{"error" => "nope"})])

    log =
      capture_log(fn ->
        assert {:ok, %{status: 401, body: %{"error" => "nope"}}} =
                 Proxy.request(entry, "petstore", get_pets(), ctx)
      end)

    assert length(attempts(agent)) == 1
    refute log =~ "tok-"
    assert log =~ "unexpected return"
    assert log =~ "petstore"
  end

  test "a second 401 is returned as-is; the callback runs exactly once", %{
    entry: entry,
    ctx: ctx
  } do
    Process.put(:refresh, fn _, _, _, _ -> {:retry, {:bearer, @new}} end)
    agent = script([status(401, %{"error" => "one"}), status(401, %{"error" => "two"})])

    assert {:ok, %{status: 401, body: %{"error" => "two"}}} =
             Proxy.request(entry, "petstore", get_pets(), ctx)

    assert length(attempts(agent)) == 2
    assert_received {:unauthorized_called, _, _}
    refute_received {:unauthorized_called, _, _}
  end

  test "a binary error crosses verbatim; a non-binary reason is logged and redacted", %{
    entry: entry,
    ctx: ctx
  } do
    Process.put(:refresh, fn _, _, _, _ -> {:error, "re-auth required at /settings"} end)
    script([status(401, %{})])

    assert {:error, %{phase: :credentials, message: "re-auth required at /settings"}} =
             Proxy.request(entry, "petstore", get_pets(), ctx)

    Process.put(:refresh, fn _, _, _, _ -> {:error, {:expired, "tok-secret"}} end)
    script([status(401, %{})])

    log =
      capture_log(fn ->
        assert {:error, %{phase: :credentials, message: message}} =
                 Proxy.request(entry, "petstore", get_pets(), ctx)

        refute message =~ "tok-secret"
        assert message == "credential refresh failed"
      end)

    # Same contract as resolve/4 (C1(b)): the reason is logged in full.
    assert log =~ "tok-secret"
  end

  test "an unattachable refreshed credential returns the original 401", %{
    entry: entry,
    ctx: ctx
  } do
    Process.put(:refresh, fn _, _, _, _ -> {:retry, {:api_key, @new}} end)
    agent = script([status(401, %{"error" => "nope"})])

    log =
      capture_log(fn ->
        assert {:ok, %{status: 401, body: %{"error" => "nope"}}} =
                 Proxy.request(entry, "petstore", get_pets(), ctx)
      end)

    assert length(attempts(agent)) == 1
    refute log =~ "tok-"
  end

  test "a refreshed credential of a malformed shape never reaches the log", %{
    entry: entry,
    ctx: ctx
  } do
    Process.put(:refresh, fn _, _, _, _ -> {:retry, {"tok-secret", :oops}} end)
    agent = script([status(401, %{"error" => "nope"})])

    log =
      capture_log(fn ->
        assert {:ok, %{status: 401, body: %{"error" => "nope"}}} =
                 Proxy.request(entry, "petstore", get_pets(), ctx)
      end)

    assert length(attempts(agent)) == 1
    refute log =~ "tok-secret"
  end

  # No credential was attached, so a 401 says nothing about credential
  # freshness — refreshing here would let an anonymous call escalate into an
  # authenticated one the resolver never sanctioned.
  test "a 401 on a request that carried no credential is not refreshed", %{
    entry: entry,
    ctx: ctx
  } do
    agent = script([status(401, %{"error" => "anonymous"})])
    ctx = %{ctx | resolver: AnonymousResolver}

    ref = :telemetry_test.attach_event_handlers(self(), [[:oapi_codemode, :request, :stop]])

    assert {:ok, %{status: 401, body: %{"error" => "anonymous"}}} =
             Proxy.request(entry, "petstore", get_pets(), ctx)

    assert length(attempts(agent)) == 1
    refute_received {:unauthorized_called, _, _}

    assert_receive {[:oapi_codemode, :request, :stop], ^ref, %{duration: _},
                    %{status: 401, retried: false}}
  end

  test "a resolver without unauthorized/4 passes the 401 through", %{entry: entry, ctx: ctx} do
    agent = script([status(401, %{"error" => "nope"})])
    ctx = %{ctx | resolver: PlainResolver}

    ref = :telemetry_test.attach_event_handlers(self(), [[:oapi_codemode, :request, :stop]])

    assert {:ok, %{status: 401, body: %{"error" => "nope"}}} =
             Proxy.request(entry, "petstore", get_pets(), ctx)

    assert length(attempts(agent)) == 1

    assert_receive {[:oapi_codemode, :request, :stop], ^ref, %{duration: _},
                    %{status: 401, retried: false}}
  end

  test "a 403 is never retried, even with the callback present", %{entry: entry, ctx: ctx} do
    Process.put(:refresh, fn _, _, _, _ -> flunk("403 must not trigger a refresh") end)
    agent = script([status(403, %{"error" => "forbidden"})])

    assert {:ok, %{status: 403}} = Proxy.request(entry, "petstore", get_pets(), ctx)

    assert length(attempts(agent)) == 1
    refute_received {:unauthorized_called, _, _}
  end

  test "a plain success reports retried: false", %{entry: entry, ctx: ctx} do
    script([status(200, %{"pets" => []})])

    ref = :telemetry_test.attach_event_handlers(self(), [[:oapi_codemode, :request, :stop]])

    assert {:ok, %{status: 200}} = Proxy.request(entry, "petstore", get_pets(), ctx)

    assert_receive {[:oapi_codemode, :request, :stop], ^ref, %{duration: _},
                    %{status: 200, retried: false}}
  end

  test "a transport failure on the retried send surfaces as a transport error", %{
    entry: entry,
    ctx: ctx
  } do
    Process.put(:refresh, fn _, _, _, _ -> {:retry, {:bearer, @new}} end)

    script([
      status(401, %{}),
      fn conn -> Req.Test.transport_error(conn, :econnrefused) end
    ])

    log =
      capture_log(fn ->
        assert {:error, %{phase: :transport, message: message}} =
                 Proxy.request(entry, "petstore", get_pets(), ctx)

        refute message =~ "tok-"
      end)

    assert log =~ "upstream request failed"
  end
end
