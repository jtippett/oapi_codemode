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

  @spec attach(map() | nil, credential()) ::
          {:ok, %{headers: [{String.t(), String.t()}], query: map()}} | {:error, String.t()}
  def attach(scheme, credential), do: do_attach(normalize_scheme(scheme), credential)

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
  defp do_attach(_scheme, _credential) do
    {:error, "credential must be {:bearer, _}, {:basic, _, _}, {:api_key, _}, or :none"}
  end
end
