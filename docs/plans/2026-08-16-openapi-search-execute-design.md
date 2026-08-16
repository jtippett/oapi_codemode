# OpenAPI Search-and-Execute for Elixir — Design

**Date:** 2026-08-16
**Status:** Validated in brainstorming; ready for implementation planning.

## Purpose

Drop an OpenAPI spec (YAML or JSON, 3.0/3.1) into an Elixir host app and
expose it to an LLM as two codemode tools, following Cloudflare's
search-and-execute pattern:

- **search** — the LLM submits a JS async arrow function that runs in a
  sandbox against the dereferenced spec as data (`specs.stripe.paths[...]`).
  Only what the function returns enters model context.
- **execute** — the LLM submits code that calls
  `apis.stripe.request({method, path, query, body, ...})`. The call is
  intercepted, validated against the spec in Elixir, credentialed, and
  executed by Elixir. Credentials never enter the sandbox.

No per-operation tools, no TS codegen, no node dependency. The spec itself
is the documentation; the proxy is the type system.

Target hosts: gentility's cloud loops (`Gentility.CloudLoop.LoopServer`)
and ele's generation servers (`Ele.Generation.Runner`). The TS execution
environment is a separate, not-yet-built project; this library defines the
contract it must satisfy.

## Decisions and their reasons

| Decision | Reason |
|---|---|
| Elixir executes all HTTP; sandbox has no network | Credential custody, observability, one interception choke point |
| Spec-as-data + LLM-written search code (CF-literal); no TS codegen, no search index | Verified against CF's live server: search is code over `spec.paths`; describe is just more code because $refs are pre-resolved. Kills codegen, node, naming normalization, and the build/runtime lifecycle split |
| Validation in the proxy, not types in the sandbox | No typecheck gate exists; spec-grounded errors beat compile errors; catches mistakes before they burn real API calls |
| TS/JS as the sandbox language | Option value (typed layer later needs TS; MCPv2 pulls toward OpenAPI), JSON is native JS, no Python-subset walls. Executor seam stays language-agnostic anyway |
| Credential resolution is a host behaviour | Bearer and OAuth tokens look identical at the wire; acquisition/refresh is the host's job (gentility: `OrgIntegration`/`Credential`; secrets referenced by name, never in transcripts) |

## Components

### 1. Ingestion (pure function: raw spec → artifact)

- Parse YAML/JSON; structural validation only (warn and proceed on dirty
  specs, reject only the unusable).
- Dereference all `$ref`s inline (CF does this too). Break circular refs
  at a revisit limit with a `{"$circular": "SchemaName"}` marker.
- Normalize: derive stable operation IDs where missing or garbage
  (method + path fallback — the oaskit `cards_freeze_ALTIJVI` lesson),
  collect tag vocabulary, extract summaries. Optionally strip vendor
  extensions and oversized examples from the sandbox payload.
- Output: an Elixir map that serializes to the sandbox `specs` global,
  plus an operation index (method + path template → operation) for the
  proxy.

Because ingestion is pure, a build-time mix task and runtime
`register/3` are both thin callers. No node anywhere.

### 2. Registry

GenServer-owned ETS: `register(name, artifact, config)`, `lookup/1`,
`list/0`. Per-API config: base URL override (spec `servers` blocks lie),
security scheme selection, context values to inject as sandbox globals
(account IDs, org slugs), optional per-API caps. No persistence — hosts
re-register at boot from wherever they keep specs.

### 3. Tool layer (transport-agnostic)

Emits tool definitions as data (`name`, `description`, JSON Schema) plus
handler functions. Hosts wrap them:

- gentility: `Gentility.CloudLoop.Tool` —
  `execute(args, context) :: {:ok, _} | {:error, _} | {:ask_user, _}`
- ele: `Ele.UserMCP.Tool` — `execute(args, scope, context)`

Both need about a page of glue. MCP server transport is a later
mechanical wrapper (gen_mcp); no MCP client is involved.

**search** `{code}`: sandbox gets one global, `specs`, keyed by API name.
No auth, no callbacks — pure data. The tool description is assembled from
the registry at emission time: registered APIs with one-liners, per-API
tag vocabularies (truncated), TS declarations of the spec shape
(CF's `OperationInfo`/`PathItem` near-verbatim), and worked examples
(find-by-tag, get-requestBody-schema, cross-API keyword scan).

**execute** `{code, api?}`: sandbox gets `apis.<name>.request(opts)` plus
per-API context globals. `request` options:
`{method, path, query?, body?, contentType?, rawBody?}` — the escape
hatches copied from CF for multipart and non-JSON bodies. Response:
`{status, headers (whitelisted), body}` with body parsed per
content-type. We do not impose CF's `success`/`errors` envelope; upstream
APIs vary.

**Both tools**: result is the function's return value, JSON-serialized,
capped at a token-measured limit (~6k default, configurable) with CF's
instructive trailer ("Response was ~N tokens (limit: M). Use more
specific queries..."). Errors pass through prefixed by phase (sandbox
error vs. proxy rejection). Agent-facing errors carry no stack traces or
temp paths (ele's `formatError` lesson); full detail goes to Logger.

### 4. Executor behaviour (the TS-env contract)

```elixir
run(code, %{globals: map, callbacks: %{request: fun}}, opts)
  → {:ok, %{value: term, logs: [String.t()]}} | {:error, reason}
```

- `opts` includes `timeout`.
- Callbacks MUST support concurrent in-flight invocations
  (`Promise.all` — the Exile bridge's synchronous dispatch was a real
  limitation; ex_monty grew a futures API for exactly this).
- The boundary is JSON-native by construction (no structs cross it).
- The lib ships a `Mock` executor for plumbing tests and contract tests
  the real executor must pass (the ele contract-test lesson applied to
  the bridge).

First real executor: resurrect ele's Exile-based subprocess Deno bridge
(commit `a2a52478f` in ele-core — `eval(code, scope:, tool_handler:,
timeout:)` over line-delimited JSON). Subprocess isolation sidesteps the
NIF-crashes-BEAM class (deno_rider's AVX-512 segfault on Xeon Platinum
8175M). An in-process runtime can replace it behind the same behaviour.
Known warts to fix in resurrection: stale temp files, orphaned OS
processes, synchronous tool dispatch.

### 5. Request proxy

Pipeline for each intercepted `request()`:

1. **Match** method + path against the operation index (template
   segments bind). No match → error listing 3–5 nearest operations
   ranked by path similarity.
2. **Validate** path params, required query params, required body fields
   against the dereferenced schema (types, required, enums; not full
   JSON Schema arbitration in v1). Failure → error quoting the violated
   schema fragment. Per-API `validate: :off | :warn | :strict`
   (default `:strict`).
3. **Policy**: method policy per execute-handler invocation —
   `:read_only` (proxy rejects non-GET with a clear error) or `:all`.
   Hosts register two tool variants: `execute` (read-only, auto-approved
   in ele's safety model) and `execute_mutations` (declared `:mutating`,
   goes through host confirmation). Optional per-call API allowlist from
   host context (gentility's `net_allowed_urls` pattern). Enforcement
   lives in the proxy, so the guarantee is real.
4. **Authorize & build**: host implements
   `resolve(api_name, security_scheme, context) → {:ok, credential} | {:error, _}`,
   called per request; context is the opaque identity map the host passed
   into the handler (Scope/Principal). The lib attaches per the spec's
   scheme: `Authorization: Bearer` (covers bearer and OAuth tokens),
   apiKey header/query, HTTP basic. Stale token → 401 propagates; host
   hands a fresh one next call. Query serialization honors the spec's
   `style`/`explode` (the ele bracket-serializer bug).
5. **Execute** via Req: timeout, response size cap, no automatic retries
   in v1 (agents retry with judgment; blind POST retries are dangerous).
6. **Observe**: telemetry `[:lib, :request, :start | :stop | :error]`
   with api/operation/status/duration. Every call also lands in the
   execute result's metadata (operation, status, duration) so the tool
   result shows what the code actually did.

## Testing

- **Ingestion/registry**: golden-file tests over vendored real specs
  (Stripe, a small clean 3.1, a dirty 3.0 with circular refs, an oaskit
  dump); property tests for path matching and ID normalization.
- **Proxy**: Req.Test stubs; assert outgoing HTTP (auth placement, query
  serialization) and validation rejections with their exact messages.
- **End-to-end**: Mock executor for plumbing; a dev-only integration
  suite may evaluate real JS via `node -e` (tests need evaluation, not
  sandboxing). Executor contract tests ship in the lib.

No live APIs anywhere in the suite.

## Failure modes handled explicitly

Unregistered API name; spec/upstream drift (requests validated,
responses pass through untouched); oversized results (capped with
trailer, never silent); sandbox timeout (named limit in the error);
credential resolution failure (distinct from upstream 401).

## Non-goals for v1

TS codegen and typecheck gates, embeddings search, a prose-docs tool,
response validation, automatic retries, OAuth acquisition/refresh,
persistence, MCP server transport.

## Context: what the ecosystem taught us

- **CF's live server** (probed via MCP): search = code over `spec`;
  ~6k-token result cap with instructive trailer; `contentType`/`rawBody`
  escape hatches; tenant context (`accountId`) injected as a data
  global; search and execute are separate sandbox invocations; raw JS
  errors pass through.
- **ele runtime history**: deno_rider NIF (died: AVX-512 segfault) →
  Exile subprocess Deno (worked; warts) → deleted for ex_monty
  (Python-only). ex_monty's pause/resume snapshots, watchdogged
  callbacks, and always-clamped recursion caps are the local gold
  standard for sandbox-host bridges.
- **ele generation servers**: tools are modules with
  `execute(args, scope, context)`; safety classes gate execution before
  code runs — hence the proxy method policy.
- **gentility cloud loops**: already ships a shallow one-tool-per-operation
  OpenAPI adapter (`OpenAPIParser` + `AdapterExecutor`) that this library
  supersedes; its `Credential` machinery (bearer/api_key/basic/oauth2,
  Cloak-encrypted, secrets-by-name) becomes the host's resolver
  implementation.
- **ele SDK pipeline**: openapi-typescript + openapi-fetch + hand-written
  facade — the typed-layer road we deliberately deferred; nothing in this
  design forecloses it.
