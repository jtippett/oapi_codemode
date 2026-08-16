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

  @doc "Ingest a raw spec into an `%Artifact{}` for caching. See `register/4`."
  defdelegate ingest(raw_spec), to: Ingest

  @doc """
  Register a pre-ingested artifact. Hosts that cache `%Artifact{}`s (ingest is
  pure) use this to skip re-parsing; `ingest_and_register/4` remains the
  one-shot path.
  """
  def register(registry, name, %OapiCodemode.Artifact{} = artifact, config_opts \\ []) do
    with {:ok, config} <- build_config(config_opts) do
      Registry.register(registry, name, artifact, config)
    end
  end

  @doc """
  Ingest a raw spec and register it in one call.

  Returns `{:error, {:invalid_config_option, key}}` rather than raising when
  `config_opts` contains a key `ApiConfig` doesn't define (e.g. a typo'd
  option name) — a host building config from user/config-file input gets a
  value it can act on instead of a `KeyError` crash.
  """
  def ingest_and_register(registry, name, raw_spec, config_opts \\ []) do
    with {:ok, artifact} <- ingest(raw_spec) do
      register(registry, name, artifact, config_opts)
    end
  end

  defp build_config(config_opts) do
    {:ok, struct!(ApiConfig, config_opts)}
  rescue
    KeyError -> {:error, {:invalid_config_option, first_unknown_key(config_opts)}}
  end

  defp first_unknown_key(config_opts) do
    known = ApiConfig.__struct__() |> Map.from_struct() |> Map.keys() |> MapSet.new()

    config_opts
    |> Keyword.keys()
    |> Enum.find(&(&1 not in known))
  end

  @doc "Emit the search/execute tool definitions. See `OapiCodemode.Tools.definitions/1`."
  defdelegate tools(opts), to: Tools, as: :definitions
end
