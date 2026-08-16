defmodule OapiCodemode.IngestXApiTest do
  @moduledoc """
  Real-world-scale ingest fixture: the X (Twitter) API v2 OpenAPI spec
  (~856KB, OpenAPI 3.0.0, 178 operations, 1491 `$ref`s — all same-document).

  This is the "tolerate dirty real specs" proof: unlike the synthetic
  clean/dirty fixtures, this is an actual vendor spec pulled from the wild,
  exercising the ingest pipeline at production scale (deref memoization,
  id derivation/dedup, matcher lookups) end to end.
  """

  use ExUnit.Case, async: true

  @moduletag :fixture_heavy

  alias OapiCodemode.{Artifact, Fixtures, Ingest}
  alias OapiCodemode.Proxy.Matcher

  @methods ~w(get post put patch delete head options)

  setup_all do
    {:ok, artifact} = Ingest.ingest(Fixtures.x_api())
    %{artifact: artifact}
  end

  test "ingests without raising" do
    assert {:ok, %Artifact{}} = Ingest.ingest(Fixtures.x_api())
  end

  test "operation count is pinned", %{artifact: artifact} do
    # Pinned after a first run against test/fixtures/specs/x_api.json.
    # Re-pin deliberately if the vendored spec is ever updated.
    assert length(artifact.operations) == 178
  end

  test "every operation has a valid id, method, and segments; ids are unique", %{
    artifact: artifact
  } do
    ids = Enum.map(artifact.operations, & &1.id)

    assert length(Enum.uniq(ids)) == length(ids)

    for op <- artifact.operations do
      assert is_binary(op.id) and op.id != ""
      assert op.method in @methods
      assert op.path == "/" or op.segments != []
    end
  end

  test "sandbox spec JSON-encodes", %{artifact: artifact} do
    assert {:ok, encoded} = Jason.encode(artifact.spec)

    # Curiosity: how much deref inlining expands the 856KB source. Pinned
    # loosely (a range) since minor spec edits shouldn't break this test.
    size = byte_size(encoded)
    assert size > 3_000_000 and size < 5_000_000

    refute encoded =~ ~s("$ref")
  end

  test "default base URL is the spec's server URL", %{artifact: artifact} do
    assert artifact.default_base_url == "https://api.x.com"
  end

  test "security schemes are extracted", %{artifact: artifact} do
    assert Map.keys(artifact.security_schemes) |> Enum.sort() ==
             ["BearerToken", "OAuth2UserToken", "UserToken"]

    assert artifact.security_schemes["BearerToken"]["type"] == "http"
    assert artifact.security_schemes["BearerToken"]["scheme"] == "bearer"
    assert artifact.security_schemes["OAuth2UserToken"]["type"] == "oauth2"
  end

  test "full ingest completes comfortably under 5 seconds" do
    raw = Fixtures.x_api()
    t0 = System.monotonic_time()
    assert {:ok, _artifact} = Ingest.ingest(raw)
    t1 = System.monotonic_time()

    ms = System.convert_time_unit(t1 - t0, :native, :millisecond)

    # Measured ~28ms locally; memoized deref keeps this well under budget
    # even though the spec has 1491 same-document $refs.
    assert ms < 5_000
  end

  test "matcher finds GET /2/tweets/{id} with bound params", %{artifact: artifact} do
    assert {:ok, op, %{"id" => "12345"}} =
             Matcher.match(artifact.operations, "get", "/2/tweets/12345")

    assert op.id == "getPostsById"
    assert op.path == "/2/tweets/{id}"
  end
end
