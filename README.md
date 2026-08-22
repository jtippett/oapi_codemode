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

## Installation

```elixir
def deps do
  [
    {:oapi_codemode, "~> 0.4.0"},
    # the sandbox engine — ex_safejs is the one we use and prefer
    {:ex_safejs, "~> 0.3.1"}
  ]
end
```

**Use `OapiCodemode.Executor.SafeJS` on
[ex_safejs](https://github.com/jtippett/ex_safejs)
([hex](https://hex.pm/packages/ex_safejs)) unless you have a specific
reason not to.** It is our preferred sandbox and the one this library is
built around: QuickJS-NG embedded as a Rustler NIF with precompiled
binaries, so a hex dependency is the entire deployment story — nothing to
install in your image, no subprocess — and guest memory is genuinely
capped, which is not true of the V8 subprocess alternative. ex_safejs is an *optional*
dependency, so you must add it yourself alongside this library.

`Executor.Deno` is the supported alternative for runs whose latency is
dominated by several independent API calls — it is the only executor that
dispatches a guest's `Promise.all` concurrently — at the cost of a `deno`
2.x binary on `PATH`. See [Executors](#executors) for the full comparison.

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
    executor: OapiCodemode.Executor.SafeJS,
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
is making the call. See [Tool options and host context](#tool-options-and-host-context)
for the rest of what `host_ctx` accepts.

In tests, swap the executor for `OapiCodemode.Executor.Mock` (shipped in
`lib/`, not `test/support/`, precisely so hosts can use it) and drive the
callbacks from Elixir — no JS engine involved. There's a worked example in
[A complete integration](#a-complete-integration).

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

`register/4` takes the same config options as `ingest_and_register/4` (see
[Registration options](#registration-options)) and returns
`{:error, {:invalid_config_option, key}}` for an unrecognized one, same as
`ingest_and_register/4`.

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

### Refreshing a token

`resolve/4` runs on *every* request, so a host that tracks expiry just
refreshes there — proactively, before the call goes out. For the cases
expiry can't predict (revoked tokens, server-side session resets, an
`expires_in` you don't trust), implement the optional `unauthorized/4`
callback: the library calls it once when the upstream answers 401 to a
credential you supplied.

```elixir
@impl true
def unauthorized("petstore", _security_scheme, _request, %{user_id: user_id}) do
  case MyApp.Tokens.refresh(user_id, :petstore) do
    {:ok, token} -> {:retry, {:bearer, token}}
    :error -> :pass
  end
end
```

`{:retry, credential}` re-sends the identical request exactly once with the
new credential attached — same method, URL, body bytes and idempotency key —
and returns whatever comes back, even another 401. `:pass` hands the 401
straight through. The same error contract as `resolve/4` applies. The
credential that *failed* is deliberately not passed to the callback: you
resolved it, so you can look it up, and the library won't put a live secret
into your refresh path. If the callback raises or returns something
unexpected, the original 401 is returned and the problem is logged. A 401 on
a request where `resolve/4` returned `:none` is never refreshed — no
credential was attached, so the 401 isn't about credential staleness.

## Telemetry

- `[:oapi_codemode, :request, :start]` — measurements `%{}`, metadata
  `%{api, operation, method}` (`operation` is `nil` until the request is
  matched).
- `[:oapi_codemode, :request, :stop]` — measurements `%{duration}`, metadata
  `%{api, operation, method, status, retried}`. `retried` says whether the
  response came from a credential-refresh retry.
- `[:oapi_codemode, :request, :retry]` — measurements `%{}`, metadata
  `%{api, operation, method, status: 401}`, emitted just before a refreshed
  credential is re-sent.
- `[:oapi_codemode, :request, :error]` — measurements `%{duration}`, metadata
  `%{api, operation, method, error}`, where `error` is the failing phase
  (`:match`, `:policy`, `:validate`, `:credentials`, `:transport`).

No metadata field ever carries a credential.

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
- `passthrough_headers` — request header names sandbox code may set via
  the request options' `headers` map (matched case-insensitively, forwarded
  downcased), e.g. `["idempotency-key"]`. Default `[]`: any header the model
  sets that isn't listed is a policy error, never a silent drop. Headers the
  library or the credential layer owns (`authorization`, `content-type`,
  `host`, ...) stay reserved even if you list them, and the emitted tool
  description only advertises a `headers` option when some API allows one.
- `auto_idempotency_header` — when set (e.g. `"idempotency-key"`), every
  mutating call (non-GET/HEAD) that doesn't carry a key gets a
  proxy-generated UUID v4 in that header, and the key used lands in the
  call log as `"idempotency_key"`. The model writes nothing in the normal
  path; it passes a logged key back via the `idempotencyKey` request option
  only to retry a call whose outcome is unknown. Reserved header names are
  rejected at registration with
  `{:error, {:invalid_idempotency_header, name}}`.
- `response_headers` — extra *response* header names surfaced to the
  sandbox for this API, on top of the built-in whitelist (`content-type`,
  `x-request-id`, `retry-after`, `x-ratelimit-*`). Register the marker your
  upstream sets on a deduplicated replay (e.g.
  `["idempotent-replayed"]`) — without it the model cannot tell "this
  executed" from "this was deduped", which is exactly what makes a
  same-key retry trustworthy.
- `validate` — `:strict` (default, rejects on the first schema mismatch),
  `:warn` (logs and proceeds), or `:off`.
- `max_response_bytes` — upstream response body cap surfaced to the
  sandbox (default `200_000`). A byte cap, not a character cap.

## Tool options and host context

`OapiCodemode.tools/1` (`OapiCodemode.Tools.definitions/1`) takes:

- `:registry`, `:executor`, `:resolver` — required.
- `:policy` — `:read_only` (default; the proxy rejects anything but
  GET/HEAD at the request level, whatever the host's own gating believes)
  or `:all`.
- `:max_calls` — intercepted `request()` calls allowed per execute run,
  default `100`, `:infinity` to disable. Calls past the limit come back to
  the sandbox as an error payload and only the first refusal is logged, so
  the call log stays bounded. This is the executor-independent bound on a
  guest that loops over cheap calls.
- `:timeout` — sandbox timeout in ms, default `30_000`. What it *means* is
  the executor's business: a wall-clock deadline under `Executor.Deno`, a
  JS compute budget under `Executor.SafeJS`.
- `:executor_opts` — a keyword list forwarded verbatim to the executor's
  `run/3`. For SafeJS: `[memory_limit: 128 * 1024 * 1024, wall_clock_ms: 60_000]`.
- `:max_result_tokens` — result-envelope budget, default `6000`.
- `:search_tool_name` / `:execute_tool_name` / `:include_search` — see
  below.

Descriptions are a snapshot of registry state at the moment `tools/1` is
called: register or unregister an API afterwards and you must re-emit the
tools, or the model is told about a surface that no longer exists. (The
handlers re-read the registry per call, so they stay correct either way.)

The second argument to a handler, `host_ctx`, is a map that may carry:

- `:context` — opaque identity handed to your credential resolver. Never
  reaches the sandbox.
- `:api_allowlist` — a list of registered API names this call may see and
  address. Absent means all; `[]` means none. Enforced at the
  request-dispatch boundary, with the sandbox globals filtered to match.
  The *descriptions* are built at `tools/1` time and are not
  allowlist-aware, so emit per-scope definitions if a description must not
  name the full set.
- `:req_options` — extra `Req` options for this call (e.g. a test plug).
- `:annotate_call` — a `payload -> map()` function run host-side on each
  intercepted call's response payload; the result is merged into that
  call's log entry, library keys winning. The call log carries no response
  body on purpose, so this is how a host records its own classification of
  a response ("this 403 was a step-up refusal, not an ordinary denial")
  somewhere sandbox code can neither forge nor suppress.

### Custom tool names, and a separate mutating tool

`:search_tool_name` (default `"search_apis"`) and `:execute_tool_name`
(default `"execute_api_code"`) rename the emitted tools — useful when a
host runs one registry per API instance and wants per-instance tool names
instead of one shared pair:

```elixir
OapiCodemode.tools(registry: reg, executor: OapiCodemode.Executor.SafeJS,
  resolver: MyApp.CredentialResolver, policy: :read_only,
  search_tool_name: "petstore_api_search", execute_tool_name: "petstore_api_execute")
```

A host that wants reads auto-approved and writes confirmed calls `tools/1`
twice — once with the defaults, once with `policy: :all`, a distinct
`:execute_tool_name`, and `include_search: false` (search only needs
offering once). Two names, so a tool-approval layer can gate on the name
alone without inspecting arguments:

```elixir
OapiCodemode.tools(registry: reg, executor: OapiCodemode.Executor.SafeJS,
  resolver: MyApp.CredentialResolver, policy: :all,
  execute_tool_name: "petstore_api_mutations", include_search: false)
```

## The execute result envelope

The execute handler returns JSON with a fixed key order — `calls`, `logs`,
then `result` or `error`:

```json
{
  "calls": [
    {"api": "petstore", "operation": "POST /pets", "status": 201,
     "duration_ms": 84, "idempotency_key": "5f1c..."}
  ],
  "logs": ["checking inventory"],
  "result": {"id": 42}
}
```

The order matters: truncation to `:max_result_tokens` chops the tail, so
the record of what the code actually did upstream survives a huge result.

A sandbox crash or timeout is *not* a tool error — it comes back as this
same envelope with `error` in place of `result`, because mutations may
have landed before the crash and the caller has to see them. A call that
was dispatched but hadn't returned when the run died stays in the log as
`{"status": "in_flight", "note": "...outcome is unknown... Verify before
retrying."}`. `{:error, message}` from a handler is reserved for failures
before the sandbox ever ran (a missing `code` argument).

## Executors

The sandbox that runs the LLM-written JS sits behind the
`OapiCodemode.Executor` behaviour. Swapping executors doesn't change how
you call `OapiCodemode.tools/1`.

| | SafeJS (preferred) | Deno | ZapCode | Mock |
|---|---|---|---|---|
| Engine | QuickJS-NG, Rustler NIF | V8 subprocess | zapcode interpreter, NIF | an Elixir function |
| Deployment | optional dep `ex_safejs`, precompiled | `deno` 2.x on `PATH` | optional dep `ex_zapcode` | none |
| Hard memory cap | yes, `ArrayBuffer`s included | no | yes, `max_memory` | n/a |
| `Promise.all` requests | serial | **concurrent** | serial | n/a |
| `:timeout` means | JS compute time only | wall clock, callbacks included | wall clock at suspension points | n/a |
| Search over big specs | yes | yes | engine-blocked (O(n²) scans) | n/a |

**`OapiCodemode.Executor.SafeJS`** — the one we use and recommend, behind
the optional [`ex_safejs`](https://github.com/jtippett/ex_safejs) dep
(QuickJS-NG embedded as a Rustler NIF, precompiled binaries; our hard fork
of quicksand, carrying the rquickjs 0.12 fix for the
timeout-during-promise-job BEAM abort,
[lpgauth/quicksand#2](https://github.com/lpgauth/quicksand/issues/2)).
Nothing to add to your image. QuickJS's own allocator is the sole memory
authority, so typed-array/`ArrayBuffer` bombs that walk past V8's heap
limit under Deno come back as a structured out-of-memory error here; size
the cap with `executor_opts: [memory_limit: bytes]`. Guest code is the async arrow the
tool descriptions teach — `await`, `.then`, `Promise.all`, regex — with
requests resolving serially. Its `:timeout` is a JS *compute* budget:
host-callback time doesn't count, so a guest looping over cheap
`request()` calls is unbounded in wall time unless you pass
`executor_opts: [wall_clock_ms: ms]` (`:max_calls` bounds the same class at
the tool layer regardless). A promise nothing can settle is reported as a
deadlock immediately rather than burning the timeout. A callback that
raises reaches the model as a fixed redacted string; the detail goes to
`Logger`.

**`OapiCodemode.Executor.Deno`** — a real sandbox driven over a `Port`
with a line-delimited JSON protocol, spawned with no permission flags plus
`--no-remote --no-npm`, so the child has no network, filesystem, or env
access and cannot resolve remote modules. Take it when a run's latency is
dominated by several independent API calls: it is the only executor that
dispatches `Promise.all` requests concurrently. The costs are the `deno`
2.x binary in every image that runs it (tested against 2.9.5) and V8's
lack of a hard memory cap.

**`OapiCodemode.Executor.ZapCode`** — behind the optional `ex_zapcode`
dep. Execute works end to end, but search over real specs is
engine-blocked (container copy semantics make scans O(n²)), the guest
dialect has no regex, and `console.log` output after the first API call is
dropped. Prefer SafeJS unless you specifically want zapcode's interpreter.

**`OapiCodemode.Executor.Mock`** — the test executor: the "sandbox" is an
Elixir function you set per test with `set_response/1`, receiving the code
string and the `env` whose `callbacks.request` you can invoke directly. It
ships in `lib/` so downstream hosts can point their whole test env at it.

## A complete integration

The shape below is lifted from a production host that exposes its own API
to an agent through these tools, anonymized (names, spec, surrounding
plumbing). It shows the pieces in the order you build them: one place that
picks the engine, one process that owns the registry, a resolver, and the
glue that runs a handler.

```elixir
# config/config.exs — one place picks the engine; test.exs overrides it.
config :my_app, MyApp.Codemode,
  executor: OapiCodemode.Executor.SafeJS,
  executor_opts: [memory_limit: 128 * 1024 * 1024, wall_clock_ms: 60_000]

# config/test.exs
config :my_app, MyApp.Codemode, executor: OapiCodemode.Executor.Mock
```

```elixir
# lib/my_app/codemode/loader.ex — owns the registry, registers once at boot.
defmodule MyApp.Codemode.Loader do
  use GenServer

  @api_name "billing"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def registry, do: MyApp.OapiRegistry

  def registered? do
    not is_nil(Process.whereis(registry())) and
      match?({:ok, _entry}, OapiCodemode.Registry.lookup(registry(), @api_name))
  end

  @impl true
  def init(_opts) do
    {:ok, _pid} = OapiCodemode.Registry.start_link(name: registry())
    {:ok, %{}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    :ok =
      OapiCodemode.ingest_and_register(
        registry(),
        @api_name,
        File.read!(Application.app_dir(:my_app, "priv/specs/billing.json")),
        base_url: "https://billing.example.com",
        auto_idempotency_header: "idempotency-key",
        response_headers: ["idempotent-replayed"]
      )

    {:noreply, state}
  end
end
```

Ingest happens in `handle_continue`, not `init`, so a slow parse doesn't
block the supervisor; the host this came from also runs the loader under
its own supervisor with `restart: :temporary` and a bounded restart count,
so a spec that will never parse leaves codemode unavailable rather than
taking the app down. `registered?/0` is what the tool layer checks before
advertising anything.

```elixir
# lib/my_app/codemode/credential_resolver.ex
defmodule MyApp.Codemode.CredentialResolver do
  @behaviour OapiCodemode.Credentials

  @api_name "billing"

  # Not part of the behaviour: mint once per tool call so the per-request
  # resolve/4 below is a map lookup, not a round trip.
  def prepare(user, grant) do
    context = %{user: user, grant: grant}

    with {:ok, {:bearer, token}} <- resolve(@api_name, nil, nil, context) do
      {:ok, Map.put(context, :token, token)}
    end
  end

  @impl true
  def resolve(@api_name, _scheme, _request, %{token: token}) when is_binary(token),
    do: {:ok, {:bearer, token}}

  def resolve(@api_name, _scheme, _request, %{user: user, grant: grant}) do
    case MyApp.Tokens.mint(user, grant) do
      {:ok, token} -> {:ok, {:bearer, token}}
      {:error, :revoked} -> {:error, "this connection's grant was revoked — reconnect to restore access"}
    end
  end

  def resolve(_api_name, _scheme, _request, _context),
    do: {:error, "no credential for this caller"}

  # 0.4.0 reactive refresh. The host this example came from doesn't
  # implement it yet — shown here because it's the answer for tokens whose
  # expiry you can't predict.
  @impl true
  def unauthorized(@api_name, _scheme, _request, %{user: user, grant: grant}) do
    case MyApp.Tokens.mint(user, grant, force: true) do
      {:ok, token} -> {:retry, {:bearer, token}}
      {:error, _reason} -> :pass
    end
  end
end
```

```elixir
# lib/my_app/codemode/tool_bridge.ex — the glue the host's tool modules call.
defmodule MyApp.Codemode.ToolBridge do
  alias MyApp.Codemode.{CredentialResolver, Loader}

  def tools(opts) do
    config = Application.fetch_env!(:my_app, MyApp.Codemode)

    OapiCodemode.tools(
      Keyword.merge(opts,
        registry: Loader.registry(),
        resolver: CredentialResolver,
        executor: Keyword.fetch!(config, :executor),
        executor_opts: Keyword.get(config, :executor_opts, [])
      )
    )
  end

  def run(tool_name, policy, args, user, grant) do
    if Loader.registered?() do
      with {:ok, context} <- CredentialResolver.prepare(user, grant) do
        tools =
          tools(
            policy: policy,
            search_tool_name: "search_billing_api",
            execute_tool_name: execute_tool_name(policy)
          )

        handler = Enum.find(tools, &(&1.name == tool_name)).handler

        handler.(args, %{
          context: context,
          req_options: [],
          annotate_call: &MyApp.Codemode.classify_call/1
        })
      end
    else
      {:error, "the API catalog is still loading — try again in a moment"}
    end
  end

  defp execute_tool_name(:read_only), do: "execute_billing_api_code"
  defp execute_tool_name(:all), do: "execute_billing_api_mutations"
end
```

Three host tool modules sit on top of that — `search_billing_api` and
`execute_billing_api_code` classified read-only, `execute_billing_api_mutations`
classified destructive — each a wrapper that resolves the caller's grant and
calls `ToolBridge.run/5` with the matching `policy`. The name split is what
the host's approval layer gates on; the proxy's `:read_only` policy is what
makes the read-only half true at the wire.

Testing needs no JS engine — with `Executor.Mock` configured for the test
env, the "sandbox" is a function that calls the request callback the way
guest code would:

```elixir
test "the read tool round-trips a GET through the host's plumbing" do
  OapiCodemode.Executor.Mock.set_response(fn _code, env ->
    response = env.callbacks.request.("billing", %{"method" => "GET", "path" => "/invoices"})
    {:ok, %{value: response, logs: []}}
  end)

  assert {:ok, json} =
           ToolBridge.run(
             "execute_billing_api_code",
             :read_only,
             %{"code" => "async () => {}"},
             user,
             grant
           )

  assert %{"result" => %{"status" => 200}} = Jason.decode!(json)
end
```

Two things worth copying: emit the tool definitions per turn rather than
per call where you can (`tools/1` reads the registry and builds
descriptions each time), and put a concurrency bound in front of `run/5` if
several agents share the node — the library bounds calls per run
(`:max_calls`) and time per run, not runs in flight.

## Design rationale

See
[`docs/plans/2026-08-16-openapi-search-execute-design.md`](https://github.com/jtippett/oapi_codemode/blob/master/docs/plans/2026-08-16-openapi-search-execute-design.md)
for the full design writeup — why search and execute are separate tools,
why validation and credentialing live in Elixir rather than the sandbox,
and how the registry, ingest pipeline, and proxy fit together.
