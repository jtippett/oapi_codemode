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
that path: two tools regardless of spec count, full-spec search in a sandbox,
deep schema validation, one choke point. The existing `Credential` machinery
is kept — it becomes the resolver's backend.

## Architecture decision already made (2026-08-16 session): per-org registries

Specs are per-organization in gentility, so one boot-time registry is wrong.
Run **one `OapiCodemode.Registry` per organization**, started lazily via a
`DynamicSupervisor` + process registry keyed by org id, populated from that
org's integration rows on first use, torn down / re-registered when the org's
integrations change. Tenant isolation then falls out structurally: an org's
sandbox can only see specs its own registry holds, and API names stay clean
JS identifiers with no org prefixes. (Library names must match
`^[A-Za-z_][A-Za-z0-9_]*$` — adapter slugs with hyphens need normalizing at
registration time; record the mapping so the resolver can find the
integration row from the api name.)

If the session disagrees with per-org registries after seeing current code,
that's a legitimate call to relitigate with James — but write the reasoning
into FEEDBACK.md either way.

## Steps

### 1. Dep + org-registry infrastructure

Add the git dep. Build `Gentility.OapiRegistries` (or similar): DynamicSupervisor,
`for_org(org_id) -> registry_pid` (start-and-populate on miss), invalidation
hook wherever integration rows are mutated. Populate via
`OapiCodemode.ingest_and_register/4` from each org OpenAPI integration's
stored spec + base URL.

Done when: two orgs with different specs get isolated registries, covered by
a test.

### 2. Credential resolver

`Gentility.OapiCredentialResolver` implementing `OapiCodemode.Credentials`:
`resolve(api_name, scheme, context)` where `context` carries org id + the
api-name→integration mapping from step 1. Delegate to the existing
`Credential` resolution that `AdapterExecutor.build_auth_headers/2` uses
today; return `{:bearer, _}` / `{:api_key, _}` / `{:basic, _, _}` per the
integration's auth kind. Keep gentility's secrets-by-name discipline: the
resolver reads the store per request; nothing persists in loop state.

Done when: resolver tests cover each auth kind plus the no-integration error.

### 3. Wire the tools into the cloud loop

Gentility's loop (`Gentility.CloudLoop.LoopServer`) dispatches tools through
a tagged-union router (builtin → adapter → mcp → tasks → integration) and
already advertises *dynamic* per-loop tools for adapters
(`build_advertised_adapter_tools/1`). Follow that dynamic path, not static
builtin modules: at loop start, if the org has OpenAPI integrations, emit

```elixir
OapiCodemode.tools(registry: org_registry, executor: OapiCodemode.Executor.Deno,
  resolver: Gentility.OapiCredentialResolver, policy: :read_only)
++ OapiCodemode.tools(..., policy: :all,
  execute_tool_name: "execute_api_mutations", include_search: false)
```

**once**, hold the emitted defs (closures included) in loop state for the
loop's lifetime, and add a router branch dispatching to them. Emission copies
spec artifacts out of ETS — per-loop-start is the right frequency, per-call
is not. Tool handler contract maps directly onto gentility's
`execute(args, context) :: {:ok,_} | {:error,_}` — pass
`%{context: %{organization_id: ..., api_integrations: mapping}}` as the
handler's `host_ctx`.

Gate `execute_api_mutations` behind whatever gentility uses for
mutating-action confirmation; the library's proxy independently enforces
read-only on the other tool, so the split is real at the wire.

Loop-policy hooks worth wiring now: the tool context's `net_access` /
allowed-URL config should gate whether these tools are advertised at all
(a per-call API allowlist inside the proxy is a known library deferral —
until it lands, gate at advertisement time).

Done when: a loop for an org with a registered spec sees exactly three new
tools with registry-derived descriptions, and a loop for an org without specs
sees none.

### 4. Deployment: Deno

Same as ele's step 4: `deno` 2.x binary in the prod image, no other config.
Check gentility's image build for where CLI binaries get added.

### 5. Verify, coexist, migrate

E2e in gentility's suite: Mock-executor test for the glue, one `@tag :deno`
test through the real sandbox (closure-plug `req_options` for stubbed
upstreams — named `Req.Test` stubs are process-scoped and won't reach the
executor's callback Tasks). Then run both paths in staging: the old
per-operation adapter tools and the new pair coexist safely (different tool
names). Migration — deprecating the per-operation advertisement — is a
later, separate decision with James once the new path has soaked.

Done when: a real cloud loop, against a staging org with one real API
integration, answers a question that requires search → execute → summarize.

### 6. Log feedback

Same as ele's step 6: the integration is done when `FEEDBACK.md` in the
library repo reflects every piece of friction this work surfaced.
