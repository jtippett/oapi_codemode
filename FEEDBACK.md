# Integration feedback log

Append an entry whenever integrating this library into a host surfaces
friction: a bug, a missing affordance, a contract that didn't fit, a doc that
lied. Entries here drive the pre-hex-release pass.

Format per entry:

```
## <date> — <host repo> — <one-line summary>
**What happened:**
**What the library should do differently:**
**Severity:** blocking / annoying / cosmetic
```

<!-- entries below -->

## 2026-08-16 — gentility — schemeless specs cannot be credentialed

**What happened:** Design phase for the gentility integration. Gentility's
adapter configs store the true `auth_type` independently of the spec, and
real-world specs routinely omit or mis-declare `securitySchemes`. But
`Credentials.attach/2` is driven entirely by the spec's scheme: with
`scheme = nil` and a `{:bearer, token}` credential, the mismatch clause
(`credentials.ex:117`) errors. Only `:none` works against a schemeless spec,
so any integration whose spec lacks `securitySchemes` cannot be authed.
**What the library should do differently:** Let the host force an attachment
style — e.g. `ApiConfig.security_scheme` accepting an inline scheme map
(`%{"type" => "http", "scheme" => "bearer"}`) in addition to a named scheme
from the spec.
**Severity:** blocking
**Resolved:** 4ae4d49

## 2026-08-16 — gentility — no per-API req_options in ApiConfig

**What happened:** Gentility routes some integrations' outbound HTTP through
per-integration egress tunnels (Req `connect_options` pointing at a CONNECT
proxy). `req_options` only flows via `host_ctx` at tool-call time, shared
across every API a single `execute_api_code` call touches — per-API proxy
config has nowhere to live.
**What the library should do differently:** Add `req_options` to `ApiConfig`
(registration-time, per API), merged beneath call-time `host_ctx.req_options`.
**Severity:** annoying
**Resolved:** 8a7b97e

## 2026-08-16 — gentility — resolver never sees the request destination

**What happened:** Gentility's credential discipline is spend-time
destination allowlists (exact host, https only). `resolve(api_name, scheme,
context)` gets no URL/host, so the check can only happen at registration
time (sound, since the host fixes `base_url` and the agent only picks paths
— but it's one invariant instead of a per-spend check).
**What the library should do differently:** Pass the resolved request host
(or full URL) to `resolve/3` (e.g. in a request-info map) so hosts can
enforce spend-time allowlists at the resolver choke point.
**Severity:** annoying (defense-in-depth)
**Resolved:** 09d0e2d

## 2026-08-16 — gentility — two opposite-visibility things named `context`

**What happened:** `ApiConfig.context` is injected as sandbox globals
(model-visible). The resolver callback's `context` is host identity
(secret-adjacent). Same name, opposite trust levels; a host confusing them
leaks tenant data into the sandbox/transcript.
**What the library should do differently:** Rename `ApiConfig.context` to
`sandbox_globals` (or similar) before hex release, while renaming is cheap.
**Severity:** annoying (footgun, cosmetic fix)
**Resolved:** 1cddb8e

## 2026-08-16 — gentility — facade lacks a cached-artifact registration path

**What happened:** Gentility runs one registry per loop start (binding-is-
the-grant scoping; see next entry). Re-parsing a large OpenAPI spec on every
loop start is waste. `Ingest.ingest/1` is pure and `Registry.register/4`
exists, but the facade only blesses the coupled `ingest_and_register/4`, so
artifact caching means calling into `Registry` directly.
**What the library should do differently:** Bless a facade
`OapiCodemode.register/4` taking a pre-ingested `%Artifact{}` (and document
`Ingest.ingest/1` as the public way to produce one for caching).
**Severity:** cosmetic
**Resolved:** fabd316

## 2026-08-16 — gentility — search tool name is not configurable

**What happened:** Gentility surfaces the tools per API instance
(`x_api_search`, `x_api_execute`, `x_api_mutations` — one single-spec
registry per bound integration). `Tools.definitions/1` supports
`:execute_tool_name` but hardcodes `"search_apis"`, so the per-instance
naming scheme cannot cover search.
**What the library should do differently:** Add a `:search_tool_name`
option (default `"search_apis"`), symmetric with `:execute_tool_name`.
**Severity:** annoying
**Resolved:** e47fd6a

## 2026-08-16 — gentility — integration guide's per-org registry advice is stale

**What happened:** `docs/integration/gentility.md` prescribes one registry
per organization. That predates gentility's loop-integrations phases 1–3
landing: the authorization model is now binding-is-the-grant
(`looper_integrations`), and a per-org registry would let any loop's sandbox
search and call every org spec, bound or not. Relitigated with James as the
guide invites: decided per-looper registries, built at loop start from bound
integrations, resolver re-checks the binding per request.
**What the library should do differently:** Update `gentility.md` step 1 to
per-looper scoping; note in `ele.md`'s generic guidance that registry scope
should follow the host's tool-authorization grain, not tenancy grain.
**Severity:** cosmetic (doc fix)
**Resolved:** docs update, this commit
