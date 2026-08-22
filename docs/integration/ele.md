# Integrating oapi_codemode into ele

Guide for a session working in the ele repo (`elephants-labs/ele-core`,
locally `~/Desktop/elephants/ele`). It assumes ele context but zero
oapi_codemode context. Library contracts below are a cache of the code as of
2026-08-21 (library 0.4.0) — the moduledocs in `lib/oapi_codemode/` and the
README are the source of truth; verify against them if anything looks off.

Whenever this integration surfaces friction with the library — a bug, a
missing affordance, a doc that lied — append an entry to `FEEDBACK.md` in the
library repo (`~/Desktop/elixir/general_api_client`). That log drives the
library's release passes. Do this as you go, not at the end.

## What the library gives you

Two LLM tools generated from dropped-in OpenAPI specs, Cloudflare
search-and-execute style:

- `search_apis` — the model submits a JS async arrow function that runs in a
  no-network JS sandbox (`Executor.SafeJS`) against the dereferenced specs as data
  (`specs.<name>.paths[...]`). Only what the function returns enters model
  context (token-capped with an instructive truncation trailer).
- `execute_api_code` — the model's JS calls
  `apis.<name>.request({method, path, query, body})`. Each call is
  intercepted, matched + validated against the spec in Elixir, credentialed
  by a resolver ele implements, and executed via Req. Credentials never enter
  the sandbox. Errors come back as data the model can read and correct from.

## Library contract cheat-sheet

```elixir
# deps (both on hex; ex_safejs is an optional dep you add yourself):
{:oapi_codemode, "~> 0.4.0"},
{:ex_safejs, "~> 0.3.1"}

# supervision:
{OapiCodemode.Registry, name: Ele.OapiRegistry}

# registration (boot): name must match ^[A-Za-z_][A-Za-z0-9_]*$ (JS identifier)
OapiCodemode.ingest_and_register(Ele.OapiRegistry, "stripe", File.read!(path),
  base_url: "https://api.stripe.com",   # optional if the spec's servers[] is right
  sandbox_globals: %{"accountId" => "..."},  # optional; JS receives context.stripe.accountId
  auto_idempotency_header: "idempotency-key", # mutations are auto-keyed; key lands in the call log
  response_headers: ["idempotent-replayed"]   # extend the response whitelist so replays are visible
)

# tool emission:
OapiCodemode.tools(
  registry: Ele.OapiRegistry,
  executor: OapiCodemode.Executor.SafeJS, # in-process QuickJS-NG NIF, nothing to install
  executor_opts: [memory_limit: 128 * 1024 * 1024, wall_clock_ms: 60_000],
  resolver: Ele.OapiCredentialResolver,   # you write this, see below
  policy: :read_only                      # proxy rejects non-GET
)
# => [%{name:, description:, input_schema:, handler: fn args, host_ctx -> ... end}]
# handler returns {:ok, json_string} | {:error, message}
# host_ctx: %{context: opaque_map_for_resolver, req_options: extra_req_opts,
#             api_allowlist: ["names this call may address"],   # optional
#             annotate_call: fn payload -> %{} end}             # optional

# mutating variant (separate tool identity, for ele's safety gating):
OapiCodemode.tools(..., policy: :all,
  execute_tool_name: "execute_api_mutations", include_search: false)

# resolver behaviour (resolve/4 runs per request, so a host that tracks
# expiry refreshes there; unauthorized/4 is the optional reactive hook for
# expiry you can't predict):
defmodule Ele.OapiCredentialResolver do
  @behaviour OapiCodemode.Credentials
  @impl true
  def resolve(api_name, _scheme, request, context) do
    # `request` is the resolved destination — method, base_url, host, path —
    # resolved before credential attachment, so a host that wants spend-time
    # allowed-hosts enforcement can check it here instead of (or in addition
    # to) at registration time.
    {:ok, {:bearer, token}}   # or {:api_key, v} | {:basic, u, p} | :none | {:error, r}
  end

  # optional (0.4.0): called once when the upstream answers 401 to a
  # credential resolve/4 supplied. {:retry, cred} re-sends the identical
  # request once; :pass hands the 401 back unchanged.
  @impl true
  def unauthorized(api_name, _scheme, _request, context), do: :pass
end
```

Gotchas already learned so you don't relearn them: a binary `{:error,
message}` from your resolver crosses to the model *verbatim* — keep secrets
out of it. Any non-binary `{:error, reason}` (e.g. `{:expired, token}`) is
logged in full and replaced with a fixed, redacted string before the model
sees it — that's the one case where the reason is redacted, not resolver
errors in general; the execute result envelope is `{"calls": [...], "logs":
[...], "result" | "error": ...}` and call metadata survives sandbox crashes
— surface it in tool-call UI if you can; a call that was in flight when a
run died stays in that log as `{"status": "in_flight"}` rather than
vanishing; `OapiCodemode.Executor.Mock` (in lib, deliberately) lets ele's
tests run without a JS engine at all.

**Registry scope is a host decision, not a library one.** The example above
uses one boot-time registry for the whole app — fine when every caller is
equally authorized to reach every registered API. When callers have
different authorization to different APIs (the common case once a host has
more than a handful of specs, or a per-tenant/per-agent authorization model),
scope registries — one registry per authorization boundary, started/torn
down with it — to whatever grain the host actually gates tool access at.
Follow the host's *tool-authorization* grain, not its *tenancy* grain: they
often coincide, but not always, and getting this wrong means an authorized
caller's sandbox can search and call specs it was never granted (see
`gentility.md` for a host where per-tenant scoping alone would have been
wrong).

## Steps

### 1. Add the deps and supervision

Add `{:oapi_codemode, "~> 0.4.0"}` and `{:ex_safejs, "~> 0.3.1"}` (the
optional engine dep the recommended executor needs), start a `Registry` in
ele's supervision tree. Done when ele compiles and boots with the registry
running.

### 2. Decide the spec source and credential source with James

Two decisions this guide cannot make (ask, don't assume):

- **Which APIs, from where**: likely `priv/specs/*.{json,yaml}` registered at
  boot, but confirm the initial spec list.
- **Where outbound API credentials live**: ele's explored code (2026-08-16)
  showed no obvious per-org outbound-credential store; config/env per API is
  the likely v1. The resolver's `context` receives whatever the tool glue
  passes (see step 3), so per-org resolution can come later without contract
  changes.

### 3. Write the three tool modules

Ele tool shape (verify against `lib/ele/user_mcp/tool.ex`): modules using
`use Ele.UserMCP.Tool`, callbacks `name/0`, `description/0`,
`input_schema/0`, `safety/0`, `execute(args, scope, context)`, registered in
`Ele.UserMCP.ToolManifest`'s per-surface lists.

Mapping:

| ele module | library tool | safety |
|---|---|---|
| `SearchApis` | `search_apis` | `:read_only` |
| `ExecuteApiCode` | `execute_api_code`, `policy: :read_only` | `:read_only` |
| `ExecuteApiMutations` | `execute_api_mutations`, `policy: :all` | `:mutating` |

Glue per module: call `OapiCodemode.tools/1` **once per process/turn, not
per callback** (emission copies artifacts out of ETS — a known cost), find
your tool by name, and:

- `description/0` → the emitted description (ele's optional
  `effective_description/1` fits better if descriptions must track registry
  changes — check how other dynamic tools in ele handle this).
- `input_schema/0` → the emitted schema (it's `{"code": string}`).
- `execute(args, scope, context)` → `handler.(args, %{context: %{scope: scope}})`,
  mapping `{:ok, json}` → `{:ok, json}` and passing errors through. The
  `%{scope: scope}` map is what your resolver receives — put whatever
  identity it needs there.

The proxy enforces read-only at the request level regardless of what ele's
safety gate believes, so the `:read_only` classification on `ExecuteApiCode`
is backed by a real guarantee, not an honor system.

Done when: all three tools appear in the manifest for whichever surface James
wants first (suggest `:playground`), and ele's architecture checks pass
(these tools are runtime primitives — they must not wrap a UserAPI Action;
check whether `runtime_primitive: true` or equivalent applies).

### 4. Deployment: nothing to deploy

`OapiCodemode.Executor.SafeJS` (ex_safejs ≥ 0.3.1, QuickJS-NG as a Rustler
NIF with precompiled binaries) is the recommended executor and needs no
image changes at all: no `deno` to re-add to the Dockerfile ele stripped in
March 2026, no subprocess, no network config. It is the only executor with
a genuine hard memory cap on guest code — size it with
`executor_opts: [memory_limit: bytes]`.

One contract to know: SafeJS's `:timeout` is a JS *compute* budget that
excludes host-callback time, so a script looping over cheap `request()`
calls is otherwise unbounded in wall time. Pass
`executor_opts: [wall_clock_ms: <hard ceiling>]` wherever ele meters a run,
and leave the tools' `:max_calls` (100 per run by default) in place — it
bounds the same abuse at the tool layer for every executor.

`Executor.Deno` remains available if ele ever needs truly concurrent
`Promise.all` (SafeJS resolves requests serially); that is the only reason
to take the `deno` 2.x binary back into the image (the library is tested
against 2.9.5). It is not the default path.

Done when: a staging deploy runs the e2e smoke below.

### 5. Verify end to end

In ele's test suite: point the test env at `OapiCodemode.Executor.Mock`,
register a fixture spec, and assert the glue plumbs args/scope through (no
JS engine needed). Then one test through the real SafeJS sandbox. For
stubbed upstreams, pass `req_options: [plug: fn conn -> ... end]` in the
handler's `host_ctx` — a closure plug; `Req.Test.stub/2` is process-scoped
and an executor may invoke callbacks from spawned Tasks (Deno does), so
named stubs won't reliably be visible there.

Done when: a generation-server conversation can ask "what pets endpoints
exist?" and get a search result, and an execute call round-trips against a
real or stubbed API with the credential attached by the resolver.

### 6. Log feedback

Reread the friction you hit and make sure each item is in the library's
`FEEDBACK.md`. Integration is not done until the log reflects it.
