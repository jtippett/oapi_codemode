defmodule OapiCodemode.CredentialsTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Credentials

  @bearer_scheme %{"type" => "http", "scheme" => "bearer"}
  @basic_scheme %{"type" => "http", "scheme" => "basic"}
  @header_key %{"type" => "apiKey", "in" => "header", "name" => "X-Api-Key"}
  @query_key %{"type" => "apiKey", "in" => "query", "name" => "api_key"}

  test "bearer credential becomes Authorization header" do
    assert {:ok, %{headers: [{"authorization", "Bearer tok123"}], query: %{}}} =
             Credentials.attach(@bearer_scheme, {:bearer, "tok123"})
  end

  test "basic credential is base64 encoded" do
    assert {:ok, %{headers: [{"authorization", "Basic " <> b64}], query: %{}}} =
             Credentials.attach(@basic_scheme, {:basic, "user", "pass"})

    assert Base.decode64!(b64) == "user:pass"
  end

  test "apiKey header uses the scheme's header name" do
    assert {:ok, %{headers: [{"X-Api-Key", "k"}], query: %{}}} =
             Credentials.attach(@header_key, {:api_key, "k"})
  end

  test "apiKey query uses the scheme's param name" do
    assert {:ok, %{headers: [], query: %{"api_key" => "k"}}} =
             Credentials.attach(@query_key, {:api_key, "k"})
  end

  test ":none attaches nothing" do
    assert {:ok, %{headers: [], query: %{}}} = Credentials.attach(nil, :none)
  end

  test "credential/scheme mismatch is an error naming both" do
    assert {:error, msg} = Credentials.attach(@bearer_scheme, {:api_key, "k"})
    assert msg =~ "api_key"
    assert msg =~ "bearer"
  end

  test "oauth2 scheme accepts a bearer token (OAuth access tokens are bearer at the wire)" do
    scheme = %{"type" => "oauth2", "flows" => %{}}

    assert {:ok, %{headers: [{"authorization", "Bearer at-42"}]}} =
             Credentials.attach(scheme, {:bearer, "at-42"})
  end
end
