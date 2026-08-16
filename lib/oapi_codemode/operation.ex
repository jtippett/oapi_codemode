defmodule OapiCodemode.Operation do
  @moduledoc "One HTTP operation extracted from a spec, ready for matching and validation."

  @enforce_keys [:id, :method, :path, :segments]
  defstruct [
    :id,
    :method,
    :path,
    :segments,
    :summary,
    tags: [],
    parameters: [],
    request_body: nil,
    security: nil
  ]

  @type t :: %__MODULE__{}
end
