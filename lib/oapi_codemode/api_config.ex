defmodule OapiCodemode.ApiConfig do
  @moduledoc "Per-API registration config. Everything the spec cannot know."

  defstruct base_url: nil,
            # name of the securityScheme to use; nil = first one in the spec
            security_scheme: nil,
            # values injected as sandbox globals for this API (e.g. account ids)
            context: %{},
            validate: :strict,
            # max upstream response body bytes surfaced to the sandbox
            max_response_bytes: 200_000

  @type t :: %__MODULE__{}
end
