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
            # when set (e.g. "idempotency-key"), every mutating call
            # (non-GET/HEAD) that doesn't supply a key gets a proxy-generated
            # UUID v4 in this header; the key used (auto or explicit) is
            # recorded in the call log as "idempotency_key". Sandbox code can
            # supply its own via the idempotencyKey request option (or the
            # headers map — this name is implicitly passthrough-allowed).
            # Stored downcased; reserved header names are rejected at
            # registration.
            auto_idempotency_header: nil,
            # extra RESPONSE header names surfaced to the sandbox for this API
            # (case-insensitive), on top of the built-in whitelist
            # (content-type, x-request-id, retry-after, x-ratelimit-*) — e.g.
            # ["idempotent-replayed"] so the model can see a dedup marker.
            response_headers: [],
            # per-API Req options (e.g. egress proxy connect_options), appended before
            # call-time host_ctx.req_options: for scalar options (e.g. :connect_options,
            # :redirect) call-time wins on conflict; :headers and :params are MERGED
            # (call-time wins on key collision, registration-time entries otherwise
            # survive) — the proxy merges :params itself before handing off to Req,
            # which only entry-merges :headers on its own
            req_options: []

  @type t :: %__MODULE__{}
end
