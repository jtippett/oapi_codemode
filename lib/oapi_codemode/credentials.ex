defmodule OapiCodemode.Credentials do
  @moduledoc """
  Host-implemented credential resolution, library-implemented attachment.

  The host resolves *what* to attach (per request — so token refresh is the
  host's problem and stale tokens self-heal on the next call). The spec's
  securityScheme dictates *how* it is attached. Credential values never
  enter the sandbox or the transcript.
  """

  @type credential ::
          {:bearer, String.t()}
          | {:basic, String.t(), String.t()}
          | {:api_key, String.t()}
          | :none

  @doc """
  Resolve a credential for one request. `context` is the opaque identity map
  the host passed into the execute handler (tenant, user, org).
  """
  @callback resolve(api_name :: String.t(), scheme :: map() | nil, context :: map()) ::
              {:ok, credential()} | {:error, term()}

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

  defp do_attach(scheme, credential) when is_tuple(credential) and tuple_size(credential) > 0 do
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
