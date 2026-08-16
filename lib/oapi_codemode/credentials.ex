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

  @spec attach(map() | nil, credential()) ::
          {:ok, %{headers: [{String.t(), String.t()}], query: map()}} | {:error, String.t()}
  def attach(_scheme, :none), do: {:ok, %{headers: [], query: %{}}}

  def attach(%{"type" => "http", "scheme" => "bearer"}, {:bearer, token}),
    do: {:ok, %{headers: [{"authorization", "Bearer " <> token}], query: %{}}}

  # OAuth2 access tokens are bearer tokens at the wire.
  def attach(%{"type" => "oauth2"}, {:bearer, token}),
    do: {:ok, %{headers: [{"authorization", "Bearer " <> token}], query: %{}}}

  def attach(%{"type" => "openIdConnect"}, {:bearer, token}),
    do: {:ok, %{headers: [{"authorization", "Bearer " <> token}], query: %{}}}

  def attach(%{"type" => "http", "scheme" => "basic"}, {:basic, user, pass}),
    do:
      {:ok,
       %{headers: [{"authorization", "Basic " <> Base.encode64(user <> ":" <> pass)}], query: %{}}}

  def attach(%{"type" => "apiKey", "in" => "header", "name" => name}, {:api_key, value}),
    do: {:ok, %{headers: [{name, value}], query: %{}}}

  def attach(%{"type" => "apiKey", "in" => "query", "name" => name}, {:api_key, value}),
    do: {:ok, %{headers: [], query: %{name => value}}}

  def attach(scheme, credential) do
    {:error,
     "credential shape #{credential |> elem(0) |> to_string()} does not fit security scheme " <>
       inspect(Map.take(scheme || %{}, ["type", "scheme", "in", "name"]))}
  end
end
