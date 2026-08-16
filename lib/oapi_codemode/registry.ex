defmodule OapiCodemode.Registry do
  @moduledoc """
  Holds ingested artifacts and per-API config in ETS. No persistence:
  hosts re-register at boot from wherever they keep specs.
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

  @spec register(GenServer.server(), String.t(), Artifact.t(), ApiConfig.t()) ::
          :ok | {:error, term()}
  def register(server, api_name, %Artifact{} = artifact, %ApiConfig{} = config) do
    GenServer.call(server, {:register, api_name, artifact, config})
  end

  @spec lookup(GenServer.server(), String.t()) :: {:ok, %Entry{}} | {:error, :unknown_api}
  def lookup(server, api_name) do
    table = GenServer.call(server, :table)

    case :ets.lookup(table, api_name) do
      [{^api_name, entry}] -> {:ok, entry}
      [] -> {:error, :unknown_api}
    end
  end

  @spec list(GenServer.server()) :: [{String.t(), %Entry{}}]
  def list(server) do
    server |> GenServer.call(:table) |> :ets.tab2list() |> Enum.sort()
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
        entry = %Entry{artifact: artifact, config: %{config | base_url: base_url}}
        :ets.insert(state.table, {name, entry})
        {:reply, :ok, state}
    end
  end

  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  defp resolve_base_url(artifact, config),
    do: config.base_url || artifact.default_base_url
end
