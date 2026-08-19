defmodule OapiCodemode.ApiConfig do
  @moduledoc "Per-API registration config. Everything the spec cannot know."

  defstruct base_url: nil,
            # name of a securityScheme in the spec, an inline scheme map, or nil (first in spec)
            security_scheme: nil,
            # model-visible values injected as sandbox globals for this API (e.g. account ids)
            sandbox_globals: %{},
            validate: :strict,
            # max upstream response body bytes surfaced to the sandbox
            max_response_bytes: 200_000,
            # header names sandbox code may set via the request options'
            # "headers" map (matched case-insensitively, forwarded downcased) —
            # e.g. ["idempotency-key"]. Anything not listed is a policy error,
            # and credential/library headers are reserved even when listed.
            passthrough_headers: [],
            # per-API Req options (e.g. egress proxy connect_options), appended before
            # call-time host_ctx.req_options: for scalar options (e.g. :connect_options,
            # :redirect) call-time wins on conflict; :headers and :params are MERGED
            # (call-time wins on key collision, registration-time entries otherwise
            # survive) — the proxy merges :params itself before handing off to Req,
            # which only entry-merges :headers on its own
            req_options: []

  @type t :: %__MODULE__{}
end
