# Integration feedback log

Append an entry whenever integrating this library into a host surfaces
friction: a bug, a missing affordance, a contract that didn't fit, a doc that
lied. Entries here drive the library's release passes.

*Status note, 2026-08-21:* the library is on hex (0.4.0) — "pre-hex-release
pass" above is now just "the next release". Every entry below is resolved;
the log stays as the record of why the contracts look the way they do.

Format per entry:

```
## <date> — <host repo> — <one-line summary>
**What happened:**
**What the library should do differently:**
**Severity:** blocking / annoying / cosmetic
```

<!-- entries below -->

## 2026-08-20 — ele (live dogfooding) — callback-raise exception text reaches the model-visible envelope

**What happened:** Driving the tools against a real dev server, a host
infra exception ("plug Tidewave is running too late...") landed verbatim
in the model's envelope error. SafeJS's moduledoc claimed the real
exception message was "host-side only", but the executor's
`{:error, %{message: ...}}` flows through `Tools.normalize_error` into
the envelope; `sanitize/1` bounds length, not content. Exception text can
embed paths, query fragments, or credentials (the C1 lesson, unapplied to
this path).
**What the library should do differently:** Redact like the resolver
path: full detail to Logger, fixed string to the model.
**Severity:** annoying (security-relevant)
**Resolved:** this commit, at both layers — `Executor.SafeJS` matches
ex_safejs's `:host_error` kind and returns a fixed "host-side error"
message (kind is guest-forgeable, but forging it only redacts the guest's
own error, so gating redaction on it is safe); `Tools.normalize_error`
redacts `{:raised, _}` (an executor's own raise) the same way for every
executor. Guest JS errors stay verbatim — the model caused those and can
fix them. Regression tests assert the detail reaches logs and not the
envelope.

## 2026-08-20 — ele (live dogfooding) — the "no regex" claim is false for SafeJS

**What happened:** Guest code ran global match, replace, lookaheads, and
named groups through the whole stack. The no-regex belief was
zapcode/quicksand-era and survived into SafeJS's moduledoc, the gentility
guide's "Deno if you need regex" line, and ele's pinned descriptions —
steering codegen toward clumsy string methods for no reason. (Verified
independently library-side before deleting the claim.)
**What the library should do differently:** Delete the false teaching;
pin the capability so it can't silently regress.
**Severity:** cosmetic (but it was actively mis-steering codegen)
**Resolved:** this commit — moduledoc and gentility guide corrected
(zapcode's own no-regex note stays: that one is true, enforced at parse
time); a SafeJS regression test pins matchAll/named groups/replace/
lookahead. Deno's remaining edge is truly concurrent Promise.all only.

## 2026-08-20 — ele (live dogfooding) — Req plug adapter hands hosts a pre-fetched conn

**What happened:** Req's `:plug` adapter (used for loopback/dev and test
stubs) delivers a conn with `body_params`/`params` already fetched —
empty maps even on a bare GET. Any host plug asserting it runs
pre-parsing raises on every proxied call; Tidewave did, on every dev
loopback request.
**What the library should do differently:** Nothing in code — this is
Req adapter behavior, worked around host-side (ele: conn-reset wrapper
plug). Documented in the gentility integration guide so the next Phoenix
host with Tidewave in dev doesn't rediscover it.
**Severity:** cosmetic (host-side)
**Resolved:** this commit (docs note); host workaround in ele

## 2026-08-19 — ele (design request from James) — hand-written idempotency headers are too much to ask of the model

**What happened:** With passthrough + response_headers in place the
idempotency loop worked, but only if the model remembered to generate and
send a key on every mutation — "making them write headers is a bit much"
(James). In practice the only case that NEEDS a key the model can reason
about is retry-after-ambiguity, and that case needs the key of the
*original* attempt, which nothing recorded.
**What the library should do differently:** Key mutations automatically
and record the key where retries can find it.
**Severity:** annoying
**Resolved:** this commit — `ApiConfig.auto_idempotency_header` (e.g.
"idempotency-key"; reserved names rejected at registration): every
mutating call without an explicit key gets a proxy-generated UUID v4 in
that header; the key used (auto or explicit) is recorded in the call-log
entry as `"idempotency_key"` — including on `in_flight` entries, which is
the load-bearing pairing: a killed run's indeterminate mutation carries
exactly the key to resend. First-class `idempotencyKey` request option as
explicit-supply sugar (precedence: option > headers-map entry > auto;
supplying both is an error; the configured header is implicitly
passthrough-allowed). Descriptions teach it only when configured, framed
as reuse-a-logged-key-to-retry, never invent-your-own. Semantics verified
ele-side: unique-per-attempt keys never dedupe intentional repeats;
same-key retry after a step-up executes fresh; a killed-mid-request row
409s fail-closed.

## 2026-08-19 — ele — response-header whitelist hides the idempotent-replay marker

**What happened:** Adopting header passthrough for idempotency keys in
ele: scripts could now SEND an `idempotency-key`, and ele's
`Idempotency-Key` plug replayed repeats correctly — but the sandbox
could never see that a replay happened. The proxy whitelists response
headers (`content-type`, `x-request-id`, `retry-after`, `x-ratelimit-*`)
and ele's `idempotent-replayed: true` marker was silently stripped, so
the model couldn't distinguish "this executed" from "this was deduped" —
exactly the signal that makes retry-with-the-same-key trustworthy. Ele's
first e2e asserted on the marker and got `nil` while the replay itself
worked.
**What the library should do differently:** Let the host extend the
response whitelist per API. Resolved in 0.2.1 —
`ApiConfig.response_headers` (case-insensitive in, downcased out); ele
registers `response_headers: ["idempotent-replayed"]` beside
`passthrough_headers: ["idempotency-key"]` and the e2e sees the marker.
**Severity:** annoying
**Resolved:** 0.2.1

## 2026-08-19 — ele — a killed run's envelope omits mutations that already landed

**What happened:** Follow-on from the wall-clock entry below, caught by
ele's review of the fix: the call log recorded a call only AFTER
`dispatch` returned. A wall-clock kill (or executor crash) landing while
a mutation was in flight — upstream accepted the write, response not yet
back — produced a timeout envelope with no record of that call. The
model's only history of what a run did is the envelope, so an omitted
landed mutation reads as "never attempted" and invites a replay, which
without idempotency keys duplicates a real write. The I1 principle
("mutations may have landed before the crash — the tool result must show
what the code actually did") was stated but not upheld across the
in-flight window.
**What the library should do differently:** Record before dispatch,
finalize after. Fixed — each call now logs an `"in_flight"` placeholder
(keyed by ref) before dispatch and is replaced in place with the final
entry when dispatch returns; a run that dies mid-call leaves
`{"status": "in_flight", "note": "...outcome is unknown... Verify before
retrying."}` in the envelope. Completed runs never show one. Envelope
order became dispatch-start order as a side effect. Regression test:
"a run killed mid-dispatch leaves the in-flight call in the envelope".
**Severity:** blocking (for mutation-capable hosts)
**Resolved:** this commit

## 2026-08-19 — ele — SafeJS compute-budget timeout reopens the unbounded-callback-traffic bug class

**What happened:** Adopting `Executor.SafeJS` in ele (swapping off
Quicksand) reintroduced a problem this log already records the Deno
executor fixing ("callback traffic cannot outlive the timeout — deadline,
not idle timer"). ex_safejs's `:timeout` is a JS *compute* budget that
deliberately excludes host-callback time — the moduledoc presents this as
a feature ("a slow host call never reads as guest misbehavior"), and for
a single call it is. But it means the engine can never end a script that
loops over cheap `apis.<name>.request(...)` calls: each call's host time
is free, so the run's wall-clock duration is unbounded. Any host that
meters runs (a concurrency semaphore, billing, a request deadline) loses
its bound, and `Tools.execute`'s call-log `Agent` — plain BEAM memory,
outside the engine's `memory_limit` — grows one entry per call, without
limit. Ele caught this in review (P1) and wrapped SafeJS in its own
executor: run the eval in a `Task`, `Task.yield(wall_clock_ms) ||
Task.shutdown(:brutal_kill)`, return `{:error, {:timeout, ms}}`. That
works well — killing the task cancels the in-flight callback with it, the
call-log Agent lives in the handler's process so the envelope still
reports completed calls, and the killed process's runtime resource is
reclaimed — but every adopting host would have to know to build it.
**What the library should do differently:** Give `Executor.SafeJS` a
`:wall_clock_ms` option doing exactly the Task-wrap above (or push a real
wall deadline into ex_safejs's interrupt handler, which would also
re-bound a run the moment a callback returns). Independently,
`Tools.execute` could take a `:max_calls` per run so the call log is
bounded even under an executor with no wall clock. The Deno executor's
deadline covers callbacks; the executor-status docs should state per
executor whether the timeout is wall-clock or compute-only — that
difference is a resource-bound contract, not an implementation detail.
**Severity:** blocking (for any host metering runs; worked around in ele)
**Resolved:** this commit — three layers, per the entry's own asks:
`Executor.SafeJS` takes `:wall_clock_ms` (unlinked worker killed at the
deadline → `{:error, {:wall_clock, ms}}`, straggler-safe for trap_exit
callers, distinct from `{:timeout, ms}` so hosts can tell compute
exhaustion from wall time); `Tools` bounds EVERY executor with
`:max_calls` (default 100, `:infinity` opt-out; slot-reserved so
concurrent callbacks can't race past it; only the first refusal is
logged so the call log itself stays bounded); and the SafeJS moduledoc,
README executor list, and gentility guide now state per executor whether
the timeout is wall-clock or compute-only. The in-engine wall deadline
(re-bound on callback return) is queued in the ex_safejs ROADMAP — ele
can drop its Task-wrap in favor of `:wall_clock_ms` now.

## 2026-08-19 — ele — library does not compile as a dependency (optional-dep struct expansion)

**What happened:** First `mix deps.compile oapi_codemode` in ele after the
Quicksand pin failed with `== Type checking failed with errors ==`.
`Executor.ZapCode` pattern-matched `%ExZapcode.Exception{...}` in two
clauses; struct expansion requires the module at compile time, and
`ex_zapcode` is an optional dep (a *path* dep, even) that no consumer has,
so Elixir 1.20's type checker hard-errors. It compiled in this repo only
because ex_zapcode is present here. Plain remote calls to absent optional
modules (`ExZapcode.start/2`, `Quicksand.eval/3`) only warn — the struct
form is the one fatal construct.
**What the library should do differently:** Never expand an optional dep's
struct. Fixed here by matching `%{__struct__: ExZapcode.Exception, ...}` —
a plain map pattern needing no module. A pre-hex-release check worth
keeping: compile the library in a scratch project with NO optional deps.
**Severity:** blocking
**Resolved:** this commit

## 2026-08-19 — ele — no per-call header passthrough (re-log; idempotency keys blocked)

**What happened:** Re-recording an entry originally written 2026-08-17
that was lost from this file during the executor work (ele's design doc
and PR notes still cite it). Sandbox JS can put a `headers` key in the
request options object, but nothing library-side reads it: there is no
path from sandbox-supplied data into outgoing request headers
(`bootstrap`/preamble → `Proxy.request/4`, re-verified against the
Quicksand executor 2026-08-19). ele wants an allowlisted passthrough —
concretely `idempotency-key` — so a model that replays a mutation after a
step-up round-trip dedupes server-side. Until then
`execute_ele_api_mutations`' description carries "never replay a
completed call" as the only protection.
**What the library should do differently:** Read an optional `headers`
map from the request options and forward only host-allowlisted keys
(per-API config, e.g. `ApiConfig.passthrough_headers`), dropping
everything else. Alternatively let the host's credential resolver see and
amend outgoing headers per call.
**Severity:** annoying
**Resolved:** this commit — `ApiConfig.passthrough_headers` allowlist;
the request options' `headers` map forwards allowlisted names
(case-insensitive in, downcased out). One deliberate divergence from the
ask: a non-allowlisted header is an explicit `[policy]` error naming the
allowed set, NOT a silent drop — a dropped idempotency key is an
invisible failure, the model must learn immediately that its header
never arrived. Credential and library headers (authorization, cookie,
content-type, ...) are reserved even when allowlisted, and a
scheme-specific auth header is rejected post-attach (C2 sibling).

## 2026-08-19 — ele — tool descriptions are executor-unaware (async dialect on a sync engine)

**What happened:** `Tools.Descriptions` (and `Tools`' `@code_schema`) teach
the async dialect — "Submit an async arrow function", `await`,
`Promise.all` examples — but under `Executor.Quicksand` that dialect
doesn't run: an async arrow returns an unresolved Promise, serialized as
`{}`. ele pins its MCP tool descriptions statically (its architecture
check requires it) and had tests asserting pinned == emitted; those had to
be loosened to guard only the registry-derived lines, with the contract
text forked to a sync version by hand. The Quicksand commit message
already flags this follow-up; recording the concrete consumer cost.
**What the library should do differently:** Make `definitions/1` ask the
executor for its contract text (a `code_contract/0` callback on
`OapiCodemode.Executor`, say) so descriptions and input-schema hints match
the engine actually configured. Once emitted text is executor-correct, ele
can return to pin-to-emitted verbatim (its preferred drift guard).
**Severity:** annoying
**Resolved:** overtaken by events, 2026-08-19 — the ex_safejs fork fixed
the async contract, so every shipping executor now runs the dialect the
emitter teaches and ele's pinned text matches it again. A
`code_contract/0` callback would still be the right shape if a
sync-only executor ever returns.

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
