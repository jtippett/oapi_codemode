# OapiCodemode

OpenAPI search-and-execute for LLM agents, in Elixir — [Cloudflare
codemode](https://blog.cloudflare.com/code-mode/) style, but the sandbox
never sees your credentials.

Drop in one or more OpenAPI specs and get two tools for your agent's tool
loop:

- **`search_apis`** — the LLM writes JS that filters the ingested specs as
  plain data (`specs.<name>.paths`, ...) inside a sandbox. No network
  access; it's just exploring the shape of the API surface.
- **`execute_api_code`** — the LLM writes JS that calls
  `apis.<name>.request({...})`. Each call is intercepted at the sandbox
  boundary and handled entirely in Elixir: matched against the spec,
  validated, credentialed, and sent over the wire. The result comes back
  into the sandbox as data.

Because the request never actually executes inside the sandbox, the
sandbox never holds an API key, bearer token, or any other secret —
credentials are attached host-side, after the JS has finished running.

## Why spec-as-data search

Specs can be huge, and dumping every operation into the system prompt
wastes context and drowns the model in noise. Instead, the spec is
handed to the model as *data* it can query with code: filter by tag,
grep summaries, pull out just the operations it needs. This is the same
idea behind Cloudflare's codemode — let the model write code against
tools instead of chaining tool calls one at a time — applied to OpenAPI
specs specifically.

## Quickstart

```elixir
# 1. Start a registry (usually under your app's supervision tree).
{:ok, registry} = OapiCodemode.Registry.start_link(name: nil)

# 2. Ingest a spec and register it with the config the spec itself can't
#    know (base URL, which security scheme to use, per-tenant context).
:ok =
  OapiCodemode.ingest_and_register(
    registry,
    "petstore",
    File.read!("petstore.json"),
    base_url: "https://api.petstore.example.com/v1"
  )

# The API name becomes a JavaScript identifier inside the sandbox
# (`apis.petstore`, `specs.petstore`, `context.petstore`), so it must match
# /^[A-Za-z_][A-Za-z0-9_]*$/ — "my-api" and "2fast" are rejected with
# {:error, {:invalid_api_name, name}}.

# 3. Get the tool definitions.
tools =
  OapiCodemode.tools(
    registry: registry,
    executor: OapiCodemode.Executor.Mock,
    resolver: MyApp.CredentialResolver,
    policy: :read_only
  )
```

Each entry in `tools` looks like:

```elixir
%{
  name: "search_apis" | "execute_api_code",
  description: "...",
  input_schema: %{...},
  handler: fn args, host_ctx -> {:ok, json} | {:error, message} end
}
```

Wire the handlers into your host's tool loop — whatever calls tools by
name and feeds results back to the model:

```elixir
Enum.find(tools, &(&1.name == tool_name)).handler.(
  tool_args,
  %{context: %{user_id: current_user.id}}
)
```

`host_ctx.context` is opaque to the library — it's handed straight to
your credential resolver so it can look up the right token for whoever
is making the call.

### Caching a parsed spec across registrations

`ingest_and_register/4` parses and registers in one call — fine for a
boot-time registry that ingests each spec once. Hosts that build a registry
more often than that (per loop start, per request, ...) should parse once
and cache the result: `OapiCodemode.ingest/1` is the pure ingest step, and
`OapiCodemode.register/4` registers an already-ingested `%Artifact{}`
without re-parsing it.

```elixir
{:ok, artifact} = OapiCodemode.ingest(File.read!("petstore.json"))
# ... stash `artifact` in your own cache, keyed however you invalidate it ...
:ok = OapiCodemode.register(registry, "petstore", artifact, base_url: "https://api.petstore.example.com/v1")
```

`register/4` takes the same config options as `ingest_and_register/4`
(`base_url`, `security_scheme`, `sandbox_globals`, `req_options`, `validate`,
`max_response_bytes`) and returns `{:error, {:invalid_config_option, key}}`
for an unrecognized one, same as `ingest_and_register/4`.

## Credential resolver

Implement the `OapiCodemode.Credentials` behaviour to tell the library
*what* credential to use for a given API and caller; the library figures
out *how* to attach it from the spec's `securityScheme`.

```elixir
defmodule MyApp.CredentialResolver do
  @behaviour OapiCodemode.Credentials

  @impl true
  def resolve("petstore", _security_scheme, _request, %{user_id: user_id}) do
    {:ok, {:bearer, MyApp.Tokens.fetch!(user_id, :petstore)}}
  end

  def resolve(_api_name, _security_scheme, _request, _context) do
    {:ok, :none}
  end
end
```

`resolve/4` returns `{:ok, {:bearer, token}}`, `{:ok, {:basic, user,
pass}}`, `{:ok, {:api_key, value}}`, `{:ok, :none}`, or `{:error,
reason}`. The credential value is attached to the outgoing request by
`OapiCodemode.Credentials.attach/2` and never crosses into the sandbox
or gets logged in a tool call transcript.

The third argument, `request`, is the resolved destination — `%{method:,
base_url:, host:, path:}` — computed *before* credential attachment, so a
resolver can enforce a spend-time allowlist (exact host, https-only, ...) at
the same choke point it resolves credentials, not just at registration time.
`path` is the OpenAPI path template (unsubstituted); the full wire path is
`base_url`'s path prefix, if any, plus the substituted path.

**Error contract:** return a binary `{:error, message}` and it crosses to
the sandbox/model *verbatim* — never put a credential or other secret in
that string. Return any non-binary reason (`{:error, {:expired, token}}`,
`{:error, :not_found}`, ...) and the library logs it in full via `Logger`
but replaces it with a fixed, redacted string before it reaches the model.

## Registration options

`ingest_and_register/4` and `register/4` take the same `ApiConfig` options:

- `base_url` — overrides the spec's `servers[]`; required if the spec has
  none or picks the wrong one.
- `security_scheme` — either the *name* of a `securityScheme` from the
  spec's `components`, `nil` (use the first scheme the matched operation
  declares), or an **inline scheme map** — e.g. `%{"type" => "http",
  "scheme" => "bearer"}` — for specs that omit or mis-declare
  `securitySchemes` entirely. The host, not the spec, usually knows the true
  auth kind; an inline map lets it say so directly instead of forcing a
  schemeless spec through `:none`.
- `sandbox_globals` — a model-visible map merged into the JS `context`
  global for this API (e.g. `%{"accountId" => "..."}` → `context.petstore.accountId`
  in the sandbox). Model-visible: never put secrets here — this is not the
  same `context` as the resolver's `context` argument, which is
  host-identity data and never enters the sandbox.
- `req_options` — a per-API keyword list of `Req.new/1` options (e.g.
  `connect_options` for an egress proxy), appended ahead of the call-time
  `host_ctx.req_options` passed to the tool handler. Scalar options (like
  `:connect_options` or `:redirect`) let the call-time value win on
  conflict; `:headers` and `:params` are *merged* (call-time wins on key
  collision, registration-time entries survive otherwise), so entries from
  both layers survive. (`:headers` merging is `Req`'s own doing; `:params`
  is merged by the proxy itself before the request reaches `Req` — `Req`
  only entry-merges options across separate `Req.new`/`Req.merge` calls, so
  a single combined options list with two `:params` entries would otherwise
  let the later one silently replace the earlier one wholesale.)
- `validate` — `:strict` (default, rejects on the first schema mismatch),
  `:warn` (logs and proceeds), or `:off`.
- `max_response_bytes` — upstream response body cap surfaced to the
  sandbox (default `200_000`).

## Custom tool names

`OapiCodemode.tools/1` accepts `:search_tool_name` (default `"search_apis"`)
and `:execute_tool_name` (default `"execute_api_code"`) to rename the
emitted tools — useful when a host runs one registry per API instance and
wants per-instance tool names instead of one shared pair:

```elixir
OapiCodemode.tools(registry: reg, executor: OapiCodemode.Executor.Deno,
  resolver: MyApp.CredentialResolver, policy: :read_only,
  search_tool_name: "petstore_api_search", execute_tool_name: "petstore_api_execute")
```

## Executor status

The sandbox that runs the LLM-written JS sits behind the
`OapiCodemode.Executor` behaviour:

- **`OapiCodemode.Executor.Mock`** — available now. Runs an Elixir
  function in place of JS; used by this library's own test suite and
  handy for exercising the plumbing (globals in, callbacks out, results
  back) without a JS runtime.
- **`OapiCodemode.Executor.Deno`** — available now. A real sandbox with no
  network access of its own, driven over a `Port` with a line-delimited
  JSON protocol. No Node/npm dependency; requires `deno` on `PATH`.
- **`OapiCodemode.Executor.Quicksand`** — available now, behind the
  optional dep `{:quicksand, "~> 0.1"}` (QuickJS-NG embedded as a Rustler
  NIF, precompiled binaries — nothing to install in the image). The only
  executor with a genuine hard memory cap: typed-array/`ArrayBuffer` bombs
  that escape V8's heap limit under Deno come back as a structured
  out-of-memory error here. **Synchronous contract**: guest code must be a
  sync arrow and `apis.x.request(...)` blocks — no `async`/`await`, no
  `Promise.all` — so tool descriptions must teach the sync dialect (see
  the moduledoc). Known upstream issue: until quicksand bumps rquickjs to
  0.12 ([lpgauth/quicksand#2](https://github.com/lpgauth/quicksand/issues/2)),
  a timeout that lands inside a running promise job aborts the whole node —
  don't run adversarial input on this executor until that release ships.
- **`OapiCodemode.Executor.ZapCode`** — execute works end-to-end behind the
  optional `ex_zapcode` dep, but search over real specs is engine-blocked
  (container copy semantics make scans O(n²)), and it runs in-BEAM, so it's
  for trusted/agent-authored code only.

The `Executor` behaviour contract is stable; swapping executors doesn't
change how you call `OapiCodemode.tools/1` — but note the Quicksand sync
dialect above when generating code.

## Design rationale

See
[`docs/plans/2026-08-16-openapi-search-execute-design.md`](docs/plans/2026-08-16-openapi-search-execute-design.md)
for the full design writeup — why search and execute are separate tools,
why validation and credentialing live in Elixir rather than the sandbox,
and how the registry, ingest pipeline, and proxy fit together.

## Installation

Not yet published to Hex. Pull it in as a path or git dependency:

```elixir
def deps do
  [
    {:oapi_codemode, github: "your-org/oapi_codemode"}
  ]
end
```
