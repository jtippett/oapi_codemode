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

  # C1: a malformed (non-tuple) credential from a buggy host resolver must
  # never have its value inspected/interpolated into the error — that value
  # could be a bare secret string.
  test "a non-tuple credential fails closed without leaking its value" do
    assert {:error, msg} = Credentials.attach(@bearer_scheme, "sk-live-SECRET")
    refute msg =~ "SECRET"
    assert msg =~ "credential must be"
  end

  test "nil credential fails closed with a generic message" do
    assert {:error, msg} = Credentials.attach(@bearer_scheme, nil)
    assert msg =~ "credential must be"
  end

  # I6: RFC 7235 scheme tokens are case-insensitive; a host resolver or spec
  # author writing "Bearer"/"Basic" must not fail closed.
  test "capitalized Bearer scheme is accepted" do
    scheme = %{"type" => "http", "scheme" => "Bearer"}

    assert {:ok, %{headers: [{"authorization", "Bearer tok"}]}} =
             Credentials.attach(scheme, {:bearer, "tok"})
  end

  test "capitalized Basic scheme is accepted" do
    scheme = %{"type" => "http", "scheme" => "Basic"}

    assert {:ok, %{headers: [{"authorization", "Basic " <> _}]}} =
             Credentials.attach(scheme, {:basic, "user", "pass"})
  end

  # M4: a colon in the username would silently corrupt the decoded pair
  # (RFC 7617 splits on the first colon), so reject it up front.
  test "basic auth username containing a colon is rejected" do
    assert {:error, msg} = Credentials.attach(@basic_scheme, {:basic, "a:b", "c"})
    assert msg =~ "colon"
  end

  # M5: apiKey in cookie attaches as a Cookie header.
  test "apiKey cookie scheme attaches a Cookie header" do
    scheme = %{"type" => "apiKey", "in" => "cookie", "name" => "session"}

    assert {:ok, %{headers: [{"cookie", "session=abc123"}], query: %{}}} =
             Credentials.attach(scheme, {:api_key, "abc123"})
  end

  # P-C1: a credential VALUE carrying a non-printable byte (the classic
  # secret-with-a-trailing-newline) must be rejected here, before Mint sees
  # it — Mint's invalid-header error embeds the raw value in its message.
  # The rejection must never echo the value.
  test "bearer token with a trailing newline is rejected without echoing it" do
    assert {:error, msg} = Credentials.attach(@bearer_scheme, {:bearer, "tok-SECRET\n"})
    assert msg == "credential contains non-printable characters"
    refute msg =~ "SECRET"
  end

  test "api key with an embedded CR is rejected" do
    assert {:error, msg} = Credentials.attach(@header_key, {:api_key, "k\r\nX-Admin: 1"})
    assert msg == "credential contains non-printable characters"
    refute msg =~ "X-Admin"
  end

  test "basic auth password with a control byte is rejected" do
    assert {:error, msg} = Credentials.attach(@basic_scheme, {:basic, "user", "pa\0ss"})
    assert msg == "credential contains non-printable characters"
  end

  test "query api key with a newline is rejected" do
    assert {:error, "credential contains non-printable characters"} =
             Credentials.attach(@query_key, {:api_key, "k\n"})
  end

  test "printable non-ASCII credentials are still accepted" do
    assert {:ok, %{headers: [{"authorization", "Basic " <> b64}]}} =
             Credentials.attach(@basic_scheme, {:basic, "üser", "pässwörd"})

    assert Base.decode64!(b64) == "üser:pässwörd"
  end

  test "a non-binary credential value fails closed with the shape error" do
    assert {:error, msg} = Credentials.attach(@bearer_scheme, {:bearer, 42})
    assert msg =~ "credential must be"
  end

  # The shape-mismatch message names the credential's tag — which is only a
  # tag if it's an atom. A resolver that returns the *value* first
  # ({"tok-...", :oops}) would otherwise interpolate the secret into a binary
  # error message that crosses to the sandbox verbatim.
  test "a mismatched credential whose first element is not an atom never echoes it" do
    assert {:error, msg} = Credentials.attach(@bearer_scheme, {"tok-secret", :oops})
    refute msg =~ "tok-secret"
    assert msg == "credential must be {:bearer, _}, {:basic, _, _}, {:api_key, _}, or :none"
  end

  test "a mismatched credential with an atom tag still names the shape" do
    assert {:error, msg} = Credentials.attach(@bearer_scheme, {:api_key, "v"})
    assert msg =~ "api_key"
    assert msg =~ "does not fit security scheme"
  end

  # M8: an apiKey header name that isn't a valid HTTP token must be rejected,
  # and the (potentially malicious, multiline) name must never be echoed
  # back verbatim in the error message.
  test "apiKey header name with CRLF injection is rejected without echoing it" do
    scheme = %{"type" => "apiKey", "in" => "header", "name" => "X-K\r\nX-Admin: 1"}

    assert {:error, msg} = Credentials.attach(scheme, {:api_key, "v"})
    refute msg =~ "X-Admin"
    refute msg =~ "\r\n"
  end
end
