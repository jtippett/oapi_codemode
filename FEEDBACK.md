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

## 2026-08-16 — gentility — ingest is not total over malformed specs

**What happened:** Reviewer-reported: gentility stores tenant-uploaded
OpenAPI specs, so `OapiCodemode.ingest/1` must be total — it must return
`{:error, _}` for any malformed shape, never raise. It raised
`Protocol.UndefinedError` on a plausible-but-malformed spec: a path item
with `"parameters" => "nope"` (non-list), or an operation with
`"tags" => "nope"` (non-list). Auditing `Normalize` for the same pattern
(`Enum`/`MapSet` over a spec-supplied value with no list guard) turned up
three more live crash sites in the same module: top-level `paths` being a
non-map/list, `requestBody.content` being a non-map, and operation-level
`parameters` being non-list (distinct from the path-level case above).
**What the library should do differently:** Fixed rather than deferred —
`Normalize` now applies the same lenient-ignore policy already established
for `info` in `Ingest.info_map/1`: a field with the wrong shape is treated
as absent (empty list / no body / no paths) instead of raising, and ingest
still succeeds with the garbage field dropped.
**Severity:** blocking
**Resolved:** this commit

**Update (2026-08-17):** That fix was itself incomplete. A follow-up
review found three more live crash sites, empirically verified, not
covered by the pass above: `Ingest.ingest/1` reading
`get_in(deref, ["components", "securitySchemes"])`, which raises when
`components` is a non-map (`FunctionClauseError`/`ArgumentError`
depending on shape); `Normalize.extract_body/1` reading `media["schema"]`
without checking the media object itself is a map (a `content` entry
whose value is e.g. a string raises); and `Normalize.list_or_empty/1`
checking only that `parameters` is a list, not that its elements are
maps (`["nope"]` passes the guard and raises later in `param_key/1`).
Same lenient-ignore policy applied to all three: the malformed field (or,
for parameter elements, just the malformed element) is dropped, ingest
still succeeds. Also added a rescue backstop around the whole of
`Ingest.ingest/1` so the next unaudited crash site downgrades to
`{:error, {:malformed_spec, _}}` instead of raising, with the exception
message truncated so it can't leak large spec content back to the caller.
Closed in this commit.

## 2026-08-16 — gentility — Deno executor leaked a stray port message into the host's long-lived caller

**What happened:** Discovered by the first real end-to-end test of
`OapiCodemode.Executor.Deno` through gentility's `LoopServer` (every other
oapi codemode test in that suite injects `Executor.Mock` instead — the
Deno path had never actually run inside a host process before). `run/3`
opened its `Port` on whatever process called it. `LoopServer` calls
`Executor.run/3` synchronously from inside `handle_info` while dispatching
a tool call, so the port — and its messages — belonged to the GenServer
itself. The `{:exit_status, _}` message the OS sends when the `deno`
child dies can arrive after the "done" line is already processed and
`run/3` has returned (the child writes "done" to stdout and calls
`Deno.exit(0)` back-to-back; the two notifications race independently).
That straggler sat in the GenServer's mailbox and landed on the next
unrelated `handle_info`, crashing the loop with a `FunctionClauseError` —
100% of the time in practice, since by the time `run/3`'s `after` clause
runs the child has usually already exited.
**What the library should do differently:** Fixed — `run/3` now runs the
whole port lifecycle inside a throwaway `Task.async/1`, so any message
that outlives the run dies with that task's mailbox instead of leaking
into the caller. `do_run/3` was made total (never raises) via a `safe_run/3`
rescue wrapper specifically so `Task.await/2` always gets a normal return
value rather than an EXIT — an EXIT from a crashed task is not
`rescue`-able the way `OapiCodemode.Tools.run_sandbox/3` (and any other
caller) expects an executor's raise to be. Regression test:
`test/oapi_codemode/executor/deno_test.exs` — "no stray port messages leak
into the calling process after run/3 returns".
**Severity:** blocking
**Resolved:** this commit

**Follow-up (2026-08-17):** that first fix was incomplete on two counts,
both closed now. (1) `Task.async/1` LINKS the task to the caller, so a
caller that traps exits — the normal setup for a host GenServer, i.e. the
exact caller this entry is about — still received a straggler,
`{:EXIT, pid, :normal}`, when the task finished; the original regression
test did not trap exits, so it passed. `run/3` now uses an unlinked
`spawn_monitor` and consumes/flushes the `:DOWN` before returning. (2)
`:timeout` was a per-receive IDLE timer, so sandbox code calling a
callback in an infinite loop reset it forever; the outer
`Task.await(timeout + 5_000)` backstop then EXITed the caller (an exit is
not `rescue`-able, so it tore straight through
`Tools.run_sandbox/3`), and the task died from a signal, skipping its
`after` clause and orphaning a spinning `deno` child. The timeout is now
a real wall-clock deadline threaded through every `receive`, `run/3`
always returns `{:ok, _} | {:error, _}` (never exits/raises into the
caller), and the backstop reaps the child by the OS pid the worker
reports at spawn. Regression tests: "no stray messages leak into a
trap_exit caller after run/3 returns" and "callback traffic cannot
outlive the timeout (deadline, not idle timer)".
