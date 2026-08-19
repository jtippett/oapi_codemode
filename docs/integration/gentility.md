# Integrating oapi_codemode into gentility

Guide for a session working in the gentility repo (locally
`~/Desktop/elixir/root`, app `:gentility` — not the gentility-* directories).
It assumes gentility context but zero oapi_codemode context. Read the
"What the library gives you" and "Library contract cheat-sheet" sections of
`docs/integration/ele.md` (sibling file) first — they apply verbatim and are
not repeated here. Host-side facts below are a cache of a 2026-08-16
exploration; verify module names against the live code.

Whenever this integration surfaces friction with the library, append an entry
to `FEEDBACK.md` in the library repo (`~/Desktop/elixir/general_api_client`)
as you go. That log drives the pre-hex-release pass.

## Why gentility is the interesting host

Gentility already has the per-operation version of this feature: per-org
OpenAPI specs stored as adapter rows (`Gentility.Integrations.OpenAPIParser`
parsing them shallowly, `AdapterExecutor` executing calls with credentials
from Cloak-encrypted `Gentility.Integrations.Credential`), each operation
advertised to the model as a separate prefixed tool. This library supersedes
that path: a fixed three tools per bound API regardless of its operation
count, full-spec search in a sandbox, deep schema validation, one choke
point. The existing `Credential` machinery
is kept — it becomes the resolver's backend.

## Architecture decision (2026-08-16 session, superseding per-org registries): per-integration single-spec registries scoped to looper bindings

An earlier pass of this guide suggested one registry per organization. That
is now known to be wrong: gentility's authorization model for API access is
binding-is-the-grant (`looper_integrations` — a loop can only reach the
integrations explicitly bound to it), and a per-org registry would let any
loop search and call *every* org spec regardless of binding, quietly
bypassing that model. Full reasoning in
`docs/plans/2026-08-16-looper-oapi-codemode-design.md` in the gentility repo.

Instead: **one single-spec `OapiCodemode.Registry` per bound openapi
integration**, started at loop start from that looper's bound integrations
only, linked to (and dying with) the loop process. Zero bound openapi
integrations → no registries, no tools, zero overhead. Tools are named
**per API instance**, using the integration's slug verbatim as both the
registry's api name and the tool-name prefix:

- `<slug>_api_search`
- `<slug>_api_execute` (read-only)
- `<slug>_api_mutations` (all methods)

Single-spec registries mean each `<slug>_api_search` tool's description
covers exactly that one API — no cross-integration bleed, and API names stay
clean JS identifiers with no org- or org-plus-slug prefixing. The adapter
slug must already satisfy `^[A-Za-z_][A-Za-z0-9_]*$` (a valid JS identifier
and ReqLLM tool name once suffixed) — no normalization, no collision
mapping; non-conforming slugs are skipped with a logged warning, and new
openapi adapter slugs get a changeset validation to prevent them arising.

Cache `%Artifact{}`s (from `OapiCodemode.ingest/1`, which is pure) in ETS
keyed by `{adapter_config_id, updated_at}` so repeated loop starts don't
re-parse large specs, and register the cached artifact via the facade
`OapiCodemode.register/4` (skips re-parsing; `ingest_and_register/4` remains
the one-shot convenience path for callers without a cache).

If a session disagrees with this scoping after seeing current code, that's a
legitimate call to relitigate with James — but write the reasoning into
FEEDBACK.md either way.

## Steps

### 1. Dep + per-loop registry infrastructure

Add the git dep. At `LoopServer` start (in `handle_continue`, not `init`):
collect the looper's bound integrations whose resource is an openapi adapter
config. For each eligible one, start an unnamed single-spec
`OapiCodemode.Registry` linked to the LoopServer, and register its cached
`%Artifact{}` (via the ETS cache + `OapiCodemode.register/4` described
above) under the integration's slug. Keep the `slug → org_integration_id`
mapping in loop state so the resolver can find the integration row from the
api name.

Done when: a loop with one bound openapi integration gets exactly one
registry holding that integration's spec, and a loop with no bound openapi
integrations starts no registries — both covered by tests.

### 2. Credential resolver

`Gentility.OapiCredentialResolver` implementing `OapiCodemode.Credentials`:
`resolve(api_name, scheme, request, context)` where `context` carries the
looper id + the api-name→integration mapping from step 1, and `request`
(new in `resolve/4`) carries the resolved destination (`method`, `base_url`,
`host`, `path`) so the resolver can enforce a spend-time allowed-hosts check
per request, not just at registration time. Per call, the resolver:

1. Re-checks the binding — `CloudLoop.integration_still_bound?/2` — so an
   unbind revokes access on the next call, even mid-`execute_api_code`.
2. Loads the credential fresh from the encrypted row (no secrets in loop
   state).
3. Checks `request.host` against `credential.allowed_hosts` (reusing the
   logic behind `AuthedRequest.check_destination/2`, not duplicating it).
4. Maps the credential's `auth_type` to `{:bearer, _}` / `{:api_key, _}` /
   `{:basic, _, _}`.

Keep gentility's secrets-by-name discipline throughout: the resolver reads
the store per request; nothing persists in loop state.

Done when: resolver tests cover each auth kind, the no-longer-bound error,
and the allowed-hosts rejection.

### 3. Wire the tools into the cloud loop

Gentility's loop (`Gentility.CloudLoop.LoopServer`) dispatches tools through
a tagged-union router (builtin → adapter → mcp → tasks → integration) and
already advertises *dynamic* per-loop tools for adapters
(`build_advertised_adapter_tools/1`). Follow that dynamic path, not static
builtin modules: at loop start, for each bound openapi integration's
single-spec registry from step 1, emit its own tool trio, naming each with
the integration's slug via `:search_tool_name` / `:execute_tool_name`:

```elixir
OapiCodemode.tools(registry: reg, executor: OapiCodemode.Executor.SafeJS,
  resolver: Gentility.Integrations.OapiCredentialResolver, policy: :read_only,
  search_tool_name: "#{slug}_api_search", execute_tool_name: "#{slug}_api_execute")
++ OapiCodemode.tools(registry: reg, executor: OapiCodemode.Executor.SafeJS,
  resolver: Gentility.Integrations.OapiCredentialResolver, policy: :all,
  execute_tool_name: "#{slug}_api_mutations", include_search: false)
```

**once per integration, once per loop start**, hold the emitted defs
(closures included) in loop state for the loop's lifetime, and add a router
branch dispatching to them. Emission copies spec artifacts out of ETS —
per-loop-start is the right frequency, per-call is not. Tool handler
contract maps directly onto gentility's
`execute(args, context) :: {:ok,_} | {:error,_}` — pass
`%{context: %{looper_id: ..., api_integrations: mapping}, req_options: [...]}`
as the handler's `host_ctx`.

Both `<slug>_api_execute` and `<slug>_api_mutations` are advertised whenever
an openapi integration is bound — parity with the per-operation adapter
tools, which already allow mutations. The separate `<slug>_api_mutations`
name exists for audit visibility and a future gating hook, not because
mutations are otherwise blocked; the library's proxy independently enforces
read-only on the `_api_execute` tool, so that half of the split is real at
the wire today.

Loop-policy hooks worth wiring now: the tool context's `net_access` /
allowed-URL config should gate whether these tools are advertised at all
(a per-call API allowlist inside the proxy is a known library deferral —
until it lands, gate at advertisement time).

Done when: a loop with one bound openapi integration (slug `x`) sees exactly
three new tools — `x_api_search`, `x_api_execute`, `x_api_mutations` — with
registry-derived descriptions, and a loop with no bound openapi integrations
sees none.

### 4. Deployment: nothing

`Executor.SafeJS` (ex_safejs ≥ 0.3.0, QuickJS-NG as a Rustler NIF with
precompiled binaries) is the recommended executor for untrusted
model-written code: nothing to add to the prod image, a genuine hard
memory cap (typed-array bombs that escape V8's heap limit under Deno come
back as structured out-of-memory errors), and the same async-arrow dialect
as Deno, so no prompt changes. It's an optional dep — add
`{:ex_safejs, "~> 0.3.1"}` to gentility's mix.exs.

One contract to know: SafeJS's `:timeout` is a JS *compute* budget that
excludes host-callback time. A loop that meters runs (LoopServer
deadlines, billing) should pass
`executor_opts: [wall_clock_ms: <hard ceiling>]`; the tools' default
`:max_calls` (100 per run) already bounds call-count abuse either way.

`Executor.Deno` remains the alternative if a loop needs regex in guest code
or truly concurrent `Promise.all` (SafeJS runs requests serially); it needs
the `deno` 2.x binary in the prod image.

### 5. Verify, coexist, migrate

E2e in gentility's suite: Mock-executor test for the glue, one test
through the real SafeJS sandbox (closure-plug `req_options` for stubbed
upstreams — named `Req.Test` stubs are process-scoped and won't reach the
executor's callback Tasks). Then run both paths in staging: the old
per-operation adapter tools and the new per-integration trios coexist safely
(different tool names). Migration — deprecating the per-operation
advertisement — is a later, separate decision with James once the new path
has soaked.

Done when: a real cloud loop, against a staging org with one real API
integration, answers a question that requires search → execute → summarize.

### 6. Log feedback

Same as ele's step 6: the integration is done when `FEEDBACK.md` in the
library repo reflects every piece of friction this work surfaced.
