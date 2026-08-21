defmodule OapiCodemode.Credentials do
  @moduledoc """
  Host-implemented credential resolution, library-implemented attachment.

  The host resolves *what* to attach, per request; the spec's securityScheme
  dictates *how* it is attached. Credential values never enter the sandbox or
  the transcript.

  Refresh has two modes, and a host can use either or both:

    * **Proactive** — `resolve/4` runs on every request, so a host that knows
      a token's expiry refreshes inside `resolve/4` before handing it back.
    * **Reactive** — `unauthorized/4` (optional) is called when the upstream
      answers 401 to a credential `resolve/4` supplied: for revoked tokens,
      server-side session resets, and the many APIs whose `expires_in` cannot
      be trusted. Returning `{:retry, credential}` re-sends the identical
      request once with the new credential.
  """

  @type credential ::
          {:bearer, String.t()}
          | {:basic, String.t(), String.t()}
          | {:api_key, String.t()}
          | :none

  @typedoc """
  Where the request is going, resolved before credential attachment.

  `path` is the OpenAPI path *template* — path params are not substituted
  (e.g. `"/pets/{id}"`, not `"/pets/42"`). `base_url` may itself include a
  path prefix (e.g. `"https://api.example.com/v1"`); the full wire path is
  `base_url`'s path segment concatenated with the substituted `path`, not
  `path` alone. `method` is always lowercase (`"get"`, not `"GET"`).
  """
  @type request_info :: %{
          method: String.t(),
          base_url: String.t(),
          host: String.t() | nil,
          path: String.t()
        }

  @doc """
  Resolve a credential for one request. `context` is the opaque identity map
  the host passed into the execute handler (tenant, user, org).

  **Error contract:** a binary `{:error, message}` crosses back to the
  sandbox/model *verbatim* — hosts must keep secrets out of binary error
  messages. Any non-binary `{:error, reason}` (e.g. `{:expired, token}`) is
  logged in full and replaced with a fixed, redacted string before it
  reaches the sandbox.
  """
  @callback resolve(
              api_name :: String.t(),
              scheme :: map() | nil,
              request :: request_info(),
              context :: map()
            ) :: {:ok, credential()} | {:error, term()}

  @doc """
  Called once when the upstream answers 401 after a credential from `resolve/4`
  was attached. Return `{:retry, credential}` to have the library re-attach the
  new credential and re-send the same request exactly once; return `:pass` to
  hand the 401 back unchanged. Same error contract as resolve/4: a binary
  `{:error, msg}` crosses verbatim; any non-binary reason is logged and
  replaced with a fixed string. If this callback raises/exits/returns garbage,
  the ORIGINAL 401 response is returned (never converted into a transport error).
  """
  # The credential that FAILED is deliberately not an argument: it would put a
  # live secret into every host's refresh code (and its logs) for no gain — the
  # host resolved it and can look it up itself from api_name + context.
  @callback unauthorized(
              api_name :: String.t(),
              scheme :: map() | nil,
              request :: request_info(),
              context :: map()
            ) :: {:retry, credential()} | :pass | {:error, term()}

  @optional_callbacks unauthorized: 4

  # RFC 7230 token charset — what's legal in an HTTP header field name.
  @header_token_re ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/

  @shape_error "credential must be {:bearer, _}, {:basic, _, _}, {:api_key, _}, or :none"

  @doc """
  Turn a resolved credential into headers and query params for one request.

  Credential *values* are screened for non-printable bytes first: a secret
  with a stray newline (the classic env-var-with-trailing-`\\n`) would
  otherwise reach Mint, whose `invalid_header_value` error embeds the raw
  value in its message and leaks it into whatever logs that message. Errors
  from here never echo the credential.
  """
  @spec attach(map() | nil, credential()) ::
          {:ok, %{headers: [{String.t(), String.t()}], query: map()}} | {:error, String.t()}
  def attach(scheme, credential) do
    with :ok <- check_values(credential_values(credential)) do
      do_attach(normalize_scheme(scheme), credential)
    end
  end

  defp credential_values({:bearer, token}), do: [token]
  defp credential_values({:api_key, value}), do: [value]
  defp credential_values({:basic, user, pass}), do: [user, pass]
  defp credential_values(_), do: []

  defp check_values(values) do
    cond do
      not Enum.all?(values, &is_binary/1) -> {:error, @shape_error}
      Enum.all?(values, &printable?/1) -> :ok
      true -> {:error, "credential contains non-printable characters"}
    end
  end

  # C0 controls, DEL, and C1 controls are the bytes that break header
  # framing (CR/LF) or that no real credential contains. Printable non-ASCII
  # stays legal — basic-auth passwords are base64'd anyway.
  defp printable?(value) do
    String.valid?(value) and
      Enum.all?(String.to_charlist(value), fn c ->
        c >= 0x20 and c != 0x7F and not (c >= 0x80 and c <= 0x9F)
      end)
  end

  # RFC 7235 auth-scheme tokens are case-insensitive; normalize once so
  # "Bearer"/"Basic" (capitalized, RFC-legal) don't fail closed.
  defp normalize_scheme(%{"scheme" => s} = scheme) when is_binary(s),
    do: %{scheme | "scheme" => String.downcase(s)}

  defp normalize_scheme(scheme), do: scheme

  defp do_attach(_scheme, :none), do: {:ok, %{headers: [], query: %{}}}

  defp do_attach(%{"type" => "http", "scheme" => "bearer"}, {:bearer, token}),
    do: {:ok, %{headers: [{"authorization", "Bearer " <> token}], query: %{}}}

  # OAuth2 access tokens are bearer tokens at the wire.
  defp do_attach(%{"type" => "oauth2"}, {:bearer, token}),
    do: {:ok, %{headers: [{"authorization", "Bearer " <> token}], query: %{}}}

  defp do_attach(%{"type" => "openIdConnect"}, {:bearer, token}),
    do: {:ok, %{headers: [{"authorization", "Bearer " <> token}], query: %{}}}

  defp do_attach(%{"type" => "http", "scheme" => "basic"}, {:basic, user, pass}) do
    if String.contains?(user, ":") do
      {:error,
       "basic auth username must not contain a colon (RFC 7617 splits on the first colon)"}
    else
      {:ok,
       %{
         headers: [{"authorization", "Basic " <> Base.encode64(user <> ":" <> pass)}],
         query: %{}
       }}
    end
  end

  defp do_attach(%{"type" => "apiKey", "in" => "header", "name" => name}, {:api_key, value}) do
    if Regex.match?(@header_token_re, name) do
      {:ok, %{headers: [{name, value}], query: %{}}}
    else
      {:error,
       "apiKey header name is not a valid HTTP header token (disallowed characters, e.g. " <>
         "whitespace or CR/LF); refusing to attach"}
    end
  end

  defp do_attach(%{"type" => "apiKey", "in" => "query", "name" => name}, {:api_key, value}),
    do: {:ok, %{headers: [], query: %{name => value}}}

  defp do_attach(%{"type" => "apiKey", "in" => "cookie", "name" => name}, {:api_key, value}),
    do: {:ok, %{headers: [{"cookie", "#{name}=#{value}"}], query: %{}}}

  # Only an ATOM first element is a shape *tag* worth naming. A resolver that
  # returns the value first ({"tok-...", :oops}) would otherwise interpolate a
  # live secret into a binary message that crosses to the sandbox verbatim —
  # those fall through to the fixed @shape_error below.
  defp do_attach(scheme, credential)
       when is_tuple(credential) and tuple_size(credential) > 0 and
              is_atom(elem(credential, 0)) do
    {:error,
     "credential shape #{credential |> elem(0) |> to_string()} does not fit security scheme " <>
       inspect(Map.take(scheme || %{}, ["type", "scheme", "in", "name"]))}
  end

  # Fallback for anything that isn't a recognized credential tuple (or is
  # malformed, e.g. a bare string a buggy resolver returned). Never
  # inspect/interpolate `credential` here — it may hold a raw secret and
  # this message can end up in logs or crash traces.
  defp do_attach(_scheme, _credential), do: {:error, @shape_error}
end
