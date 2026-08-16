defmodule OapiCodemode.Artifact do
  @moduledoc "The ingestion output: sandbox spec payload plus the proxy's operation index."

  @enforce_keys [:spec, :operations]
  defstruct [
    :spec,
    :operations,
    :title,
    :default_base_url,
    tags: [],
    security_schemes: %{}
  ]

  @type t :: %__MODULE__{}
end
