defmodule OapiCodemode.Registry do
  @moduledoc """
  Holds ingested artifacts and per-API config in ETS. No persistence:
  hosts re-register at boot from wherever they keep specs.

  Reads pay one GenServer.call to fetch the table ref — deliberate: lookups
  happen a handful of times per LLM tool call, so the hop is noise next to
  the LLM turn and the upstream HTTP request, and it keeps unnamed
  per-test registries isolated (a :named_table would not).
  """

  use GenServer
  alias OapiCodemode.{Artifact, ApiConfig}

  defmodule Entry do
    @enforce_keys [:artifact, :config]
    defstruct [:artifact, :config]
  end

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  # The api name is used verbatim as a JS identifier inside the sandbox:
  # `apis.<name>.request()`, `specs.<name>`, `context.<name>`. `$` is legal
  # in a JS identifier but pointless here, so keep the alphabet boring.
  @api_name_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  Register an ingested artifact under `api_name`.

  `api_name` must be a valid JS identifier — it becomes a property name on
  the sandbox globals. Returns `{:error, {:invalid_api_name, name}}`
  otherwise, or `{:error, :no_base_url}` when neither the config nor the
  spec supplies a server URL.
  """
  @spec register(GenServer.server(), String.t(), Artifact.t(), ApiConfig.t()) ::
          :ok | {:error, {:invalid_api_name, term()} | :no_base_url}
  def register(server, api_name, %Artifact{} = artifact, %ApiConfig{} = config) do
    cond do
      not (is_binary(api_name) and Regex.match?(@api_name_re, api_name)) ->
        {:error, {:invalid_api_name, api_name}}

      not valid_idempotency_header?(config.auto_idempotency_header) ->
        {:error, {:invalid_idempotency_header, config.auto_idempotency_header}}

      true ->
        GenServer.call(server, {:register, api_name, artifact, config})
    end
  end

  # A reserved header (authorization, content-type, ...) as the idempotency
  # header would collide with credential attach or the body encoder.
  defp valid_idempotency_header?(nil), do: true

  defp valid_idempotency_header?(name) when is_binary(name) and name != "",
    do: not OapiCodemode.Proxy.reserved_header?(String.downcase(name))

  defp valid_idempotency_header?(_), do: false

  @spec lookup(GenServer.server(), String.t()) :: {:ok, %Entry{}} | {:error, :unknown_api}
  def lookup(server, api_name) do
    table = GenServer.call(server, :table)

    case :ets.lookup(table, api_name) do
      [{^api_name, entry, _meta}] -> {:ok, entry}
      [] -> {:error, :unknown_api}
    end
  end

  @spec list(GenServer.server()) :: [{String.t(), %Entry{}}]
  def list(server) do
    server
    |> GenServer.call(:table)
    |> :ets.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort()
  end

  @doc """
  Projected read for the per-call hot paths (I3): each API's spec
  pre-encoded to JSON at registration — a refc binary, so reads share it
  rather than copy it — plus its model-visible `sandbox_globals`. Sorted by
  API name. Unlike `list/1`, this never copies full artifacts out of ETS,
  which costs tens of ms per call on multi-MB specs.
  """
  @spec sandbox_meta(GenServer.server()) :: [
          {String.t(),
           %{
             spec_json: String.t(),
             sandbox_globals: map(),
             auto_idempotency_header: String.t() | nil
           }}
        ]
  def sandbox_meta(server) do
    server
    |> GenServer.call(:table)
    |> :ets.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort()
  end

  @impl true
  def init(_opts) do
    {:ok, %{table: :ets.new(:oapi_codemode_registry, [:set, :protected, read_concurrency: true])}}
  end

  @impl true
  def handle_call({:register, name, artifact, config}, _from, state) do
    case resolve_base_url(artifact, config) do
      nil ->
        {:reply, {:error, :no_base_url}, state}

      base_url ->
        config = %{
          config
          | base_url: base_url,
            auto_idempotency_header: downcase_or_nil(config.auto_idempotency_header)
        }

        entry = %Entry{artifact: artifact, config: config}

        meta = %{
          spec_json: Jason.encode!(artifact.spec),
          sandbox_globals: config.sandbox_globals,
          auto_idempotency_header: config.auto_idempotency_header
        }

        :ets.insert(state.table, {name, entry, meta})
        {:reply, :ok, state}
    end
  end

  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  defp resolve_base_url(artifact, config),
    do: config.base_url || artifact.default_base_url

  defp downcase_or_nil(nil), do: nil
  defp downcase_or_nil(name), do: String.downcase(name)
end
