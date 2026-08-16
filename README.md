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

## Credential resolver

Implement the `OapiCodemode.Credentials` behaviour to tell the library
*what* credential to use for a given API and caller; the library figures
out *how* to attach it from the spec's `securityScheme`.

```elixir
defmodule MyApp.CredentialResolver do
  @behaviour OapiCodemode.Credentials

  @impl true
  def resolve("petstore", _security_scheme, %{user_id: user_id}) do
    {:ok, {:bearer, MyApp.Tokens.fetch!(user_id, :petstore)}}
  end

  def resolve(_api_name, _security_scheme, _context) do
    {:ok, :none}
  end
end
```

`resolve/3` returns `{:ok, {:bearer, token}}`, `{:ok, {:basic, user,
pass}}`, `{:ok, {:api_key, value}}`, `{:ok, :none}`, or `{:error,
reason}`. The credential value is attached to the outgoing request by
`OapiCodemode.Credentials.attach/2` and never crosses into the sandbox
or gets logged in a tool call transcript.

## Executor status

The sandbox that runs the LLM-written JS sits behind the
`OapiCodemode.Executor` behaviour:

- **`OapiCodemode.Executor.Mock`** — available now. Runs an Elixir
  function in place of JS; used by this library's own test suite and
  handy for exercising the plumbing (globals in, callbacks out, results
  back) without a JS runtime.
- **Subprocess Deno executor** — in progress. A real sandbox with no
  network access of its own, driven over a `Port` with a line-delimited
  JSON protocol. No Node/npm dependency.

The `Executor` behaviour contract is stable; swapping executors doesn't
change how you call `OapiCodemode.tools/1`.

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
