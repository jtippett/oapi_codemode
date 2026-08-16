defmodule OapiCodemode do
  @moduledoc """
  OpenAPI search-and-execute for LLM agents, Cloudflare-codemode style.

  Drop in an OpenAPI spec; get two tools: `search_apis` (LLM-written JS
  filters the spec as data in a sandbox) and `execute_api_code` (LLM-written
  JS calls `apis.<name>.request()`, intercepted, validated against the spec,
  credentialed, and executed in Elixir). Credentials never enter the sandbox.

  See docs/plans/2026-08-16-openapi-search-execute-design.md for the design.
  """

  alias OapiCodemode.{ApiConfig, Ingest, Registry, Tools}

  @doc "Ingest a raw spec and register it in one call."
  def ingest_and_register(registry, name, raw_spec, config_opts \\ []) do
    with {:ok, artifact} <- Ingest.ingest(raw_spec) do
      Registry.register(registry, name, artifact, struct!(ApiConfig, config_opts))
    end
  end

  @doc "Emit the search/execute tool definitions. See `OapiCodemode.Tools.definitions/1`."
  defdelegate tools(opts), to: Tools, as: :definitions
end
