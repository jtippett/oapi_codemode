# OpenAPI Search-and-Execute Library Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build `oapi_codemode`, an Elixir library that turns dropped-in OpenAPI specs into two codemode LLM tools (search and execute) with a validating, credential-injecting request proxy.

**Architecture:** Specs are ingested (parsed, $ref-dereferenced, normalized) into artifacts held in an ETS registry. The `search` tool runs LLM-written JS against the spec-as-data in a sandbox; the `execute` tool runs JS whose `request()` calls are intercepted by a host callback into an Elixir proxy that matches, validates, credentials, and executes the HTTP call. The sandbox is behind an `Executor` behaviour; a Mock executor serves tests, and a subprocess-Deno executor (resurrecting ele's Exile-bridge design, commit `a2a52478f` in ele-core) is the first real one. Design rationale: `docs/plans/2026-08-16-openapi-search-execute-design.md`.

**Tech Stack:** Elixir ~> 1.17, `yaml_elixir`, `jason`, `req` (+ `plug` for Req.Test), `telemetry`. Deno (subprocess, no NIF) for the real executor. No node/npm anywhere.

**Conventions for every task:** TDD (test first, watch it fail, minimal code, watch it pass), commit after each task. Run tests with `mix test <path> --seed 0`. All modules under the `OapiCodemode` namespace. Use @superpowers:test-driven-development and @superpowers:verification-before-completion.

---

### Task 1: Project scaffold

**Files:**
- Create: `mix.exs`, `lib/oapi_codemode.ex`, `.gitignore`, `.formatter.exs`

**Step 1: Generate the project in the repo root**

```bash
cd /Users/james/Desktop/elixir/general_api_client
mix new . --app oapi_codemode --module OapiCodemode
```

Answer `y` to "proceed with generation" (directory not empty — docs/ exists). If the generator refuses because of `.mcp.json`/`api_docs/`, generate into a temp dir and move `mix.exs`, `lib/`, `test/`, `.formatter.exs`, `.gitignore` in — do NOT delete `.mcp.json`, `api_docs/`, or `docs/`.

**Step 2: Set deps in `mix.exs`**

```elixir
defp deps do
  [
    {:yaml_elixir, "~> 2.11"},
    {:jason, "~> 1.4"},
    {:req, "~> 0.5"},
    {:telemetry, "~> 1.2"},
    {:plug, "~> 1.16", only: :test}
  ]
end
```

**Step 3: Verify**

Run: `mix deps.get && mix test`
Expected: the generated doctest passes (or delete the placeholder test and `mix test` reports 0 failures).

**Step 4: Commit**

```bash
git add mix.exs lib test .formatter.exs .gitignore mix.lock
git commit -m "chore: scaffold oapi_codemode mix project"
```

---

### Task 2: Test fixtures

**Files:**
- Create: `test/fixtures/specs/clean_3_1.json`
- Create: `test/fixtures/specs/dirty_3_0.yaml`
- Create: `test/support/fixtures.ex`
- Modify: `mix.exs` (elixirc_paths for test support)

**Step 1: Add elixirc_paths to `mix.exs` project/0**

```elixir
def project do
  [
    app: :oapi_codemode,
    version: "0.1.0",
    elixir: "~> 1.17",
    elixirc_paths: elixirc_paths(Mix.env()),
    start_permanent: Mix.env() == :prod,
    deps: deps()
  ]
end

defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

**Step 2: Write `test/fixtures/specs/clean_3_1.json`** — a small, well-formed 3.1 spec exercising: bearer auth, path params, required+enum query params, array query param, a required request body with nested object, and tags.

```json
{
  "openapi": "3.1.0",
  "info": { "title": "Petstore", "version": "1.0.0", "description": "A small clean spec." },
  "servers": [{ "url": "https://petstore.example.com/v1" }],
  "components": {
    "securitySchemes": {
      "bearerAuth": { "type": "http", "scheme": "bearer" }
    },
    "schemas": {
      "Pet": {
        "type": "object",
        "required": ["name", "species"],
        "properties": {
          "name": { "type": "string" },
          "species": { "type": "string", "enum": ["dog", "cat", "bird"] },
          "owner": {
            "type": "object",
            "required": ["email"],
            "properties": { "email": { "type": "string" } }
          }
        }
      }
    }
  },
  "security": [{ "bearerAuth": [] }],
  "paths": {
    "/pets": {
      "get": {
        "operationId": "listPets",
        "summary": "List all pets",
        "tags": ["pets"],
        "parameters": [
          { "name": "limit", "in": "query", "required": true, "schema": { "type": "integer" } },
          { "name": "status", "in": "query", "schema": { "type": "string", "enum": ["available", "adopted"] } },
          { "name": "tags", "in": "query", "schema": { "type": "array", "items": { "type": "string" } }, "style": "form", "explode": false }
        ],
        "responses": { "200": { "description": "ok" } }
      },
      "post": {
        "operationId": "createPet",
        "summary": "Create a pet",
        "tags": ["pets"],
        "requestBody": {
          "required": true,
          "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Pet" } } }
        },
        "responses": { "201": { "description": "created" } }
      }
    },
    "/pets/{petId}": {
      "get": {
        "operationId": "getPet",
        "summary": "Get a pet by id",
        "tags": ["pets"],
        "parameters": [{ "name": "petId", "in": "path", "required": true, "schema": { "type": "string" } }],
        "responses": { "200": { "description": "ok" } }
      },
      "delete": {
        "operationId": "deletePet",
        "summary": "Delete a pet",
        "tags": ["pets"],
        "parameters": [{ "name": "petId", "in": "path", "required": true, "schema": { "type": "string" } }],
        "responses": { "204": { "description": "gone" } }
      }
    }
  }
}
```

**Step 3: Write `test/fixtures/specs/dirty_3_0.yaml`** — missing operationIds, a circular $ref, apiKey-in-query auth, no servers block:

```yaml
openapi: 3.0.3
info:
  title: Dirty API
  version: 0.0.1
components:
  securitySchemes:
    keyAuth:
      type: apiKey
      in: query
      name: api_key
  schemas:
    Node:
      type: object
      properties:
        label:
          type: string
        parent:
          $ref: '#/components/schemas/Node'
security:
  - keyAuth: []
paths:
  /nodes/{id}:
    get:
      summary: Fetch a node
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Node'
  /nodes:
    post:
      summary: Create a node
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/Node'
      responses:
        '201':
          description: created
```

**Step 4: Write `test/support/fixtures.ex`**

```elixir
defmodule OapiCodemode.Fixtures do
  @fixtures Path.expand("../fixtures/specs", __DIR__)

  def raw(name), do: File.read!(Path.join(@fixtures, name))
  def clean_3_1, do: raw("clean_3_1.json")
  def dirty_3_0, do: raw("dirty_3_0.yaml")
end
```

**Step 5: Verify and commit**

Run: `mix test` — Expected: compiles, 0 failures.

```bash
git add test mix.exs
git commit -m "test: add spec fixtures (clean 3.1 JSON, dirty 3.0 YAML with circular ref)"
```

---

### Task 3: Ingest.Parser — parse and structurally validate

**Files:**
- Create: `lib/oapi_codemode/ingest/parser.ex`
- Test: `test/oapi_codemode/ingest/parser_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemode.Ingest.ParserTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Ingest.Parser
  alias OapiCodemode.Fixtures

  test "parses JSON specs" do
    assert {:ok, %{"openapi" => "3.1.0"}} = Parser.parse(Fixtures.clean_3_1())
  end

  test "parses YAML specs" do
    assert {:ok, %{"openapi" => "3.0.3"}} = Parser.parse(Fixtures.dirty_3_0())
  end

  test "rejects non-spec JSON" do
    assert {:error, {:invalid_spec, _}} = Parser.parse(~s({"hello": "world"}))
  end

  test "rejects OpenAPI 2 (swagger)" do
    assert {:error, {:invalid_spec, msg}} = Parser.parse(~s({"swagger": "2.0", "paths": {}}))
    assert msg =~ "3.x"
  end

  test "rejects unparseable input" do
    assert {:error, {:parse_error, _}} = Parser.parse("{{{{not anything")
  end
end
```

**Step 2: Run to verify failure**

Run: `mix test test/oapi_codemode/ingest/parser_test.exs`
Expected: FAIL — module `OapiCodemode.Ingest.Parser` is not available.

**Step 3: Implement `lib/oapi_codemode/ingest/parser.ex`**

```elixir
defmodule OapiCodemode.Ingest.Parser do
  @moduledoc "Parses raw YAML/JSON into a map and checks it is an OpenAPI 3.x document."

  @spec parse(String.t()) :: {:ok, map()} | {:error, term()}
  def parse(raw) when is_binary(raw) do
    with {:ok, doc} <- decode(raw) do
      validate(doc)
    end
  end

  defp decode(raw) do
    trimmed = String.trim_leading(raw)

    if String.starts_with?(trimmed, ["{", "["]) do
      case Jason.decode(raw) do
        {:ok, doc} -> {:ok, doc}
        {:error, err} -> {:error, {:parse_error, Exception.message(err)}}
      end
    else
      case YamlElixir.read_from_string(raw) do
        {:ok, doc} -> {:ok, doc}
        {:error, err} -> {:error, {:parse_error, inspect(err)}}
      end
    end
  end

  defp validate(%{"openapi" => "3" <> _, "paths" => paths} = doc) when is_map(paths),
    do: {:ok, doc}

  defp validate(%{"swagger" => _}),
    do: {:error, {:invalid_spec, "OpenAPI 2 (swagger) is not supported; convert to 3.x"}}

  defp validate(doc) when is_map(doc),
    do: {:error, {:invalid_spec, "missing openapi 3.x version or paths"}}

  defp validate(_),
    do: {:error, {:invalid_spec, "document is not a map"}}
end
```

**Step 4: Run to verify pass** — `mix test test/oapi_codemode/ingest/parser_test.exs` → PASS.

**Step 5: Commit** — `git add lib test && git commit -m "feat: spec parser with structural validation"`

---

### Task 4: Ingest.Deref — inline $refs, break cycles

**Files:**
- Create: `lib/oapi_codemode/ingest/deref.ex`
- Test: `test/oapi_codemode/ingest/deref_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemode.Ingest.DerefTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Ingest.{Parser, Deref}
  alias OapiCodemode.Fixtures

  test "inlines local refs" do
    {:ok, spec} = Parser.parse(Fixtures.clean_3_1())
    deref = Deref.dereference(spec)

    schema =
      deref["paths"]["/pets"]["post"]["requestBody"]["content"]["application/json"]["schema"]

    assert schema["type"] == "object"
    assert "name" in schema["required"]
    refute Map.has_key?(schema, "$ref")
  end

  test "breaks circular refs with a marker" do
    {:ok, spec} = Parser.parse(Fixtures.dirty_3_0())
    deref = Deref.dereference(spec)

    node =
      deref["paths"]["/nodes"]["post"]["requestBody"]["content"]["application/json"]["schema"]

    assert node["type"] == "object"
    assert node["properties"]["parent"] == %{"$circular" => "Node"}
  end

  test "leaves unresolvable refs marked" do
    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{"/x" => %{"get" => %{"responses" => %{}}}},
      "junk" => %{"$ref" => "#/components/schemas/Missing"},
      "external" => %{"$ref" => "other.yaml#/Foo"}
    }

    deref = Deref.dereference(spec)
    assert deref["junk"] == %{"$unresolved" => "#/components/schemas/Missing"}
    assert deref["external"] == %{"$unresolved" => "other.yaml#/Foo"}
  end
end
```

**Step 2: Run to verify failure** — module not available.

**Step 3: Implement `lib/oapi_codemode/ingest/deref.ex`**

```elixir
defmodule OapiCodemode.Ingest.Deref do
  @moduledoc """
  Resolves all same-document $refs inline so sandbox code never chases references.

  Circular refs become `%{"$circular" => name}`; external or dangling refs
  become `%{"$unresolved" => ref}`. Sandbox code can detect both markers.
  """

  @spec dereference(map()) :: map()
  def dereference(spec) when is_map(spec), do: walk(spec, spec, MapSet.new())

  defp walk(%{"$ref" => ref}, root, stack) when is_binary(ref) do
    cond do
      MapSet.member?(stack, ref) ->
        %{"$circular" => ref_name(ref)}

      not String.starts_with?(ref, "#/") ->
        %{"$unresolved" => ref}

      true ->
        case resolve_pointer(root, ref) do
          {:ok, target} -> walk(target, root, MapSet.put(stack, ref))
          :error -> %{"$unresolved" => ref}
        end
    end
  end

  defp walk(map, root, stack) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, walk(v, root, stack)} end)

  defp walk(list, root, stack) when is_list(list),
    do: Enum.map(list, &walk(&1, root, stack))

  defp walk(other, _root, _stack), do: other

  defp resolve_pointer(root, "#/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce_while({:ok, root}, fn key, {:ok, acc} ->
      case acc do
        %{^key => value} -> {:cont, {:ok, value}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp ref_name(ref), do: ref |> String.split("/") |> List.last()
end
```

**Step 4: Run to verify pass. Step 5: Commit** — `"feat: $ref dereferencer with cycle breaking"`

---

### Task 5: Operation extraction and ID normalization

**Files:**
- Create: `lib/oapi_codemode/operation.ex`
- Create: `lib/oapi_codemode/ingest/normalize.ex`
- Test: `test/oapi_codemode/ingest/normalize_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemode.Ingest.NormalizeTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Ingest.{Parser, Deref, Normalize}
  alias OapiCodemode.{Fixtures, Operation}

  defp operations(fixture) do
    {:ok, spec} = Parser.parse(fixture)
    spec |> Deref.dereference() |> Normalize.operations()
  end

  test "keeps existing operationIds" do
    ops = operations(Fixtures.clean_3_1())
    assert Enum.any?(ops, &(&1.id == "listPets"))
    assert Enum.any?(ops, &(&1.id == "deletePet"))
  end

  test "derives ids from method + path when missing" do
    ops = operations(Fixtures.dirty_3_0())
    assert Enum.any?(ops, &(&1.id == "get_nodes_by_id"))
    assert Enum.any?(ops, &(&1.id == "post_nodes"))
  end

  test "parses path templates into segments" do
    ops = operations(Fixtures.clean_3_1())
    get_pet = Enum.find(ops, &(&1.id == "getPet"))
    assert get_pet.segments == ["pets", {:param, "petId"}]
    assert get_pet.method == "get"
  end

  test "captures parameters, request body schema, and tags" do
    ops = operations(Fixtures.clean_3_1())
    create = Enum.find(ops, &(&1.id == "createPet"))
    assert create.request_body["schema"]["type"] == "object"
    assert create.request_body["required"] == true
    assert create.tags == ["pets"]

    list = Enum.find(ops, &(&1.id == "listPets"))
    assert Enum.any?(list.parameters, &(&1["name"] == "limit" and &1["required"]))
  end

  test "deduplicates colliding ids with a numeric suffix" do
    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/a" => %{"get" => %{"operationId" => "dup", "responses" => %{}}},
        "/b" => %{"get" => %{"operationId" => "dup", "responses" => %{}}}
      }
    }

    ops = Normalize.operations(spec)
    assert Enum.map(ops, & &1.id) |> Enum.sort() == ["dup", "dup_2"]
  end
end
```

**Step 2: Run to verify failure.**

**Step 3: Implement.** `lib/oapi_codemode/operation.ex`:

```elixir
defmodule OapiCodemode.Operation do
  @moduledoc "One HTTP operation extracted from a spec, ready for matching and validation."

  @enforce_keys [:id, :method, :path, :segments]
  defstruct [
    :id,
    :method,
    :path,
    :segments,
    :summary,
    tags: [],
    parameters: [],
    request_body: nil,
    security: nil
  ]

  @type t :: %__MODULE__{}
end
```

`lib/oapi_codemode/ingest/normalize.ex`:

```elixir
defmodule OapiCodemode.Ingest.Normalize do
  @moduledoc """
  Extracts a flat operation list from a dereferenced spec, deriving stable
  readable ids where operationId is missing (the oaskit `cards_freeze_ALTIJVI`
  lesson: never trust upstream ids to exist or be usable).
  """

  alias OapiCodemode.Operation

  @methods ~w(get post put patch delete head options)

  @spec operations(map()) :: [Operation.t()]
  def operations(spec) do
    spec
    |> Map.get("paths", %{})
    |> Enum.sort_by(fn {path, _} -> path end)
    |> Enum.flat_map(fn {path, item} -> path_operations(path, item, spec) end)
    |> dedupe_ids()
  end

  defp path_operations(path, item, spec) when is_map(item) do
    path_level_params = Map.get(item, "parameters", [])

    for method <- @methods, op = item[method], is_map(op) do
      %Operation{
        id: op["operationId"] || derive_id(method, path),
        method: method,
        path: path,
        segments: parse_segments(path),
        summary: op["summary"] || op["description"],
        tags: op["tags"] || [],
        parameters: path_level_params ++ Map.get(op, "parameters", []),
        request_body: extract_body(op["requestBody"]),
        security: op["security"] || spec["security"]
      }
    end
  end

  defp path_operations(_path, _item, _spec), do: []

  defp derive_id(method, path) do
    suffix =
      path
      |> parse_segments()
      |> Enum.map_join("_", fn
        {:param, name} -> "by_" <> Macro.underscore(name)
        seg -> seg |> String.replace(~r/[^a-zA-Z0-9]+/, "_") |> String.trim("_")
      end)

    "#{method}_#{suffix}"
  end

  defp parse_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      "{" <> rest -> {:param, String.trim_trailing(rest, "}")}
      seg -> seg
    end)
  end

  defp extract_body(nil), do: nil

  defp extract_body(%{"content" => content} = body) do
    {content_type, media} =
      Enum.find(content, List.first(content), fn {ct, _} -> ct =~ "json" end) ||
        {nil, %{}}

    %{
      "required" => Map.get(body, "required", false),
      "content_type" => content_type,
      "schema" => media["schema"]
    }
  end

  defp extract_body(_), do: nil

  defp dedupe_ids(ops) do
    {ops, _seen} =
      Enum.map_reduce(ops, %{}, fn op, seen ->
        case seen do
          %{^op => _} -> raise "unreachable"
          _ -> :ok
        end

        count = Map.get(seen, op.id, 0)
        id = if count == 0, do: op.id, else: "#{op.id}_#{count + 1}"
        {%{op | id: id}, Map.put(seen, op.id, count + 1)}
      end)

    ops
  end
end
```

Note: delete the `case seen do ... raise` block above if the reviewer flags it — it is dead scaffolding; `Enum.map_reduce` with the count map is the whole mechanism.

**Step 4: Run to verify pass. Step 5: Commit** — `"feat: operation extraction with id normalization"`

---

### Task 6: Artifact assembly (`Ingest.ingest/1`)

**Files:**
- Create: `lib/oapi_codemode/artifact.ex`
- Create: `lib/oapi_codemode/ingest.ex`
- Test: `test/oapi_codemode/ingest_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemode.IngestTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.{Ingest, Artifact, Fixtures}

  test "produces an artifact with sandbox spec, operations, tags, and title" do
    assert {:ok, %Artifact{} = art} = Ingest.ingest(Fixtures.clean_3_1())
    assert art.title == "Petstore"
    assert art.tags == ["pets"]
    assert length(art.operations) == 4
    # sandbox payload is dereferenced and JSON-serializable
    assert {:ok, _} = Jason.encode(art.spec)
    refute inspect(art.spec) =~ "$ref\" =>"
    # default server captured
    assert art.default_base_url == "https://petstore.example.com/v1"
  end

  test "handles specs without servers" do
    assert {:ok, %Artifact{default_base_url: nil}} = Ingest.ingest(Fixtures.dirty_3_0())
  end

  test "propagates parse errors" do
    assert {:error, {:invalid_spec, _}} = Ingest.ingest(~s({"nope": true}))
  end

  test "extracts security schemes" do
    {:ok, art} = Ingest.ingest(Fixtures.dirty_3_0())
    assert art.security_schemes["keyAuth"]["type"] == "apiKey"
  end
end
```

**Step 2: Run to verify failure.**

**Step 3: Implement.** `lib/oapi_codemode/artifact.ex`:

```elixir
defmodule OapiCodemode.Artifact do
  @moduledoc "The ingestion output: sandbox spec payload plus the proxy's operation index."

  @enforce_keys [:spec, :operations]
  defstruct [
    :spec,
    :operations,
    :title,
    :default_base_url,
    tags: [],
    security_schemes: %{}
  ]

  @type t :: %__MODULE__{}
end
```

`lib/oapi_codemode/ingest.ex`:

```elixir
defmodule OapiCodemode.Ingest do
  @moduledoc """
  Pure pipeline: raw spec source -> `OapiCodemode.Artifact`.

  Pure by design so that a build-time mix task and runtime registration are
  both thin callers of the same function.
  """

  alias OapiCodemode.{Artifact, Ingest}

  @spec ingest(String.t()) :: {:ok, Artifact.t()} | {:error, term()}
  def ingest(raw) when is_binary(raw) do
    with {:ok, parsed} <- Ingest.Parser.parse(raw) do
      deref = Ingest.Deref.dereference(parsed)
      operations = Ingest.Normalize.operations(deref)

      {:ok,
       %Artifact{
         spec: sandbox_payload(deref),
         operations: operations,
         title: get_in(deref, ["info", "title"]),
         default_base_url: default_server(deref),
         tags: operations |> Enum.flat_map(& &1.tags) |> Enum.uniq() |> Enum.sort(),
         security_schemes: get_in(deref, ["components", "securitySchemes"]) || %{}
       }}
    end
  end

  defp sandbox_payload(deref) do
    %{
      "info" => Map.take(deref["info"] || %{}, ["title", "description", "version"]),
      "paths" => deref["paths"]
    }
  end

  defp default_server(%{"servers" => [%{"url" => url} | _]}), do: url
  defp default_server(_), do: nil
end
```

**Step 4: Run to verify pass. Step 5: Commit** — `"feat: ingest pipeline producing artifacts"`

---

### Task 7: Registry

**Files:**
- Create: `lib/oapi_codemode/registry.ex`
- Create: `lib/oapi_codemode/api_config.ex`
- Test: `test/oapi_codemode/registry_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemode.RegistryTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.{Registry, Ingest, ApiConfig, Fixtures}

  setup do
    reg = start_supervised!({Registry, name: nil})
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())
    %{reg: reg, art: art}
  end

  test "registers and looks up an API", %{reg: reg, art: art} do
    assert :ok = Registry.register(reg, "petstore", art, %ApiConfig{})
    assert {:ok, entry} = Registry.lookup(reg, "petstore")
    assert entry.artifact.title == "Petstore"
    # base_url falls back to the spec's server when config omits it
    assert entry.config.base_url == "https://petstore.example.com/v1"
  end

  test "config base_url override wins", %{reg: reg, art: art} do
    config = %ApiConfig{base_url: "https://staging.example.com"}
    :ok = Registry.register(reg, "petstore", art, config)
    {:ok, entry} = Registry.lookup(reg, "petstore")
    assert entry.config.base_url == "https://staging.example.com"
  end

  test "rejects registration with no resolvable base_url", %{reg: reg} do
    {:ok, art} = Ingest.ingest(Fixtures.dirty_3_0())
    assert {:error, :no_base_url} = Registry.register(reg, "dirty", art, %ApiConfig{})
  end

  test "lists registered APIs", %{reg: reg, art: art} do
    :ok = Registry.register(reg, "petstore", art, %ApiConfig{})
    assert [{"petstore", _entry}] = Registry.list(reg)
  end

  test "lookup of unknown API errors", %{reg: reg} do
    assert {:error, :unknown_api} = Registry.lookup(reg, "nope")
  end

  test "re-registration replaces", %{reg: reg, art: art} do
    :ok = Registry.register(reg, "petstore", art, %ApiConfig{})
    :ok = Registry.register(reg, "petstore", art, %ApiConfig{base_url: "https://two.example.com"})
    {:ok, entry} = Registry.lookup(reg, "petstore")
    assert entry.config.base_url == "https://two.example.com"
  end
end
```

**Step 2: Run to verify failure.**

**Step 3: Implement.** `lib/oapi_codemode/api_config.ex`:

```elixir
defmodule OapiCodemode.ApiConfig do
  @moduledoc "Per-API registration config. Everything the spec cannot know."

  defstruct base_url: nil,
            # name of the securityScheme to use; nil = first one in the spec
            security_scheme: nil,
            # values injected as sandbox globals for this API (e.g. account ids)
            context: %{},
            validate: :strict,
            # max upstream response body bytes surfaced to the sandbox
            max_response_bytes: 200_000

  @type t :: %__MODULE__{}
end
```

`lib/oapi_codemode/registry.ex`:

```elixir
defmodule OapiCodemode.Registry do
  @moduledoc """
  Holds ingested artifacts and per-API config in ETS. No persistence:
  hosts re-register at boot from wherever they keep specs.
  """

  use GenServer
  alias OapiCodemode.{Artifact, ApiConfig}

  defmodule Entry do
    @enforce_keys [:artifact, :config]
    defstruct [:artifact, :config]
  end

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec register(GenServer.server(), String.t(), Artifact.t(), ApiConfig.t()) ::
          :ok | {:error, term()}
  def register(server, api_name, %Artifact{} = artifact, %ApiConfig{} = config) do
    GenServer.call(server, {:register, api_name, artifact, config})
  end

  @spec lookup(GenServer.server(), String.t()) :: {:ok, %Entry{}} | {:error, :unknown_api}
  def lookup(server, api_name) do
    table = GenServer.call(server, :table)

    case :ets.lookup(table, api_name) do
      [{^api_name, entry}] -> {:ok, entry}
      [] -> {:error, :unknown_api}
    end
  end

  @spec list(GenServer.server()) :: [{String.t(), %Entry{}}]
  def list(server) do
    server |> GenServer.call(:table) |> :ets.tab2list() |> Enum.sort()
  end

  @impl true
  def init(_opts) do
    {:ok, %{table: :ets.new(:oapi_codemode_registry, [:set, :protected, read_concurrency: true])}}
  end

  @impl true
  def handle_call({:register, name, artifact, config}, _from, state) do
    case resolve_base_url(artifact, config) do
      nil ->
        {:reply, {:error, :no_base_url}, state}

      base_url ->
        entry = %Entry{artifact: artifact, config: %{config | base_url: base_url}}
        :ets.insert(state.table, {name, entry})
        {:reply, :ok, state}
    end
  end

  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  defp resolve_base_url(artifact, config),
    do: config.base_url || artifact.default_base_url
end
```

**Step 4: Run to verify pass. Step 5: Commit** — `"feat: ETS-backed registry with per-API config"`

---

### Task 8: Proxy.Matcher — operation matching with near-miss suggestions

**Files:**
- Create: `lib/oapi_codemode/proxy/matcher.ex`
- Test: `test/oapi_codemode/proxy/matcher_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemode.Proxy.MatcherTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Proxy.Matcher
  alias OapiCodemode.{Ingest, Fixtures}

  setup do
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())
    %{ops: art.operations}
  end

  test "matches a literal path", %{ops: ops} do
    assert {:ok, op, %{}} = Matcher.match(ops, "get", "/pets")
    assert op.id == "listPets"
  end

  test "binds path params", %{ops: ops} do
    assert {:ok, op, %{"petId" => "42"}} = Matcher.match(ops, "get", "/pets/42")
    assert op.id == "getPet"
  end

  test "method mismatch is no match", %{ops: ops} do
    assert {:error, {:no_match, _}} = Matcher.match(ops, "put", "/pets/42")
  end

  test "ignores a leading base-path prefix mismatch by exact segments only", %{ops: ops} do
    assert {:error, {:no_match, _}} = Matcher.match(ops, "get", "/v1/pets")
  end

  test "no match returns nearest operations, same-method ranked first", %{ops: ops} do
    assert {:error, {:no_match, suggestions}} = Matcher.match(ops, "delete", "/pet/42")
    assert is_list(suggestions) and length(suggestions) <= 5
    assert hd(suggestions) == "DELETE /pets/{petId}"
  end

  test "trailing slashes and query strings are tolerated", %{ops: ops} do
    assert {:ok, %{id: "listPets"}, _} = Matcher.match(ops, "get", "/pets/")
    assert {:ok, %{id: "listPets"}, _} = Matcher.match(ops, "get", "/pets?limit=5")
  end
end
```

**Step 2: Run to verify failure.**

**Step 3: Implement `lib/oapi_codemode/proxy/matcher.ex`**

```elixir
defmodule OapiCodemode.Proxy.Matcher do
  @moduledoc """
  Matches an intercepted (method, path) against the operation index.
  On failure, suggests the nearest operations so the model can self-correct
  without another search round-trip.
  """

  alias OapiCodemode.Operation

  @max_suggestions 5

  @spec match([Operation.t()], String.t(), String.t()) ::
          {:ok, Operation.t(), %{String.t() => String.t()}}
          | {:error, {:no_match, [String.t()]}}
  def match(operations, method, path) do
    method = String.downcase(method)
    segments = path |> strip_query() |> String.split("/", trim: true)

    operations
    |> Enum.filter(&(&1.method == method))
    |> Enum.find_value(fn op ->
      case bind(op.segments, segments, %{}) do
        {:ok, params} -> {:ok, op, params}
        :error -> nil
      end
    end)
    |> case do
      {:ok, _, _} = hit -> hit
      nil -> {:error, {:no_match, suggestions(operations, method, segments)}}
    end
  end

  defp strip_query(path), do: path |> String.split("?", parts: 2) |> hd()

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:param, name} | t1], [seg | t2], params),
    do: bind(t1, t2, Map.put(params, name, seg))

  defp bind([seg | t1], [seg | t2], params), do: bind(t1, t2, params)
  defp bind(_, _, _), do: :error

  defp suggestions(operations, method, segments) do
    given = Enum.join(segments, "/")

    operations
    |> Enum.map(fn op ->
      template =
        Enum.map_join(op.segments, "/", fn
          {:param, name} -> "{#{name}}"
          seg -> seg
        end)

      method_bonus = if op.method == method, do: 0.25, else: 0.0
      {String.jaro_distance(given, template) + method_bonus, op, template}
    end)
    |> Enum.sort_by(fn {score, _, _} -> -score end)
    |> Enum.take(@max_suggestions)
    |> Enum.map(fn {_score, op, template} ->
      "#{String.upcase(op.method)} /#{template}"
    end)
  end
end
```

**Step 4: Run to verify pass. Step 5: Commit** — `"feat: proxy operation matcher with near-miss suggestions"`

---

### Task 9: Proxy.Validator — spec-grounded request validation

**Files:**
- Create: `lib/oapi_codemode/proxy/validator.ex`
- Test: `test/oapi_codemode/proxy/validator_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemode.Proxy.ValidatorTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Proxy.Validator
  alias OapiCodemode.{Ingest, Fixtures}

  setup do
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())
    ops = Map.new(art.operations, &{&1.id, &1})
    %{ops: ops}
  end

  test "passes a valid request", %{ops: ops} do
    assert :ok =
             Validator.validate(ops["createPet"], %{
               query: %{},
               body: %{"name" => "Rex", "species" => "dog"}
             })
  end

  test "missing required query param", %{ops: ops} do
    assert {:error, msg} = Validator.validate(ops["listPets"], %{query: %{}, body: nil})
    assert msg =~ "limit"
    assert msg =~ "required"
  end

  test "query param type mismatch", %{ops: ops} do
    assert {:error, msg} =
             Validator.validate(ops["listPets"], %{query: %{"limit" => "lots"}, body: nil})

    assert msg =~ "limit"
    assert msg =~ "integer"
  end

  test "enum violation quotes allowed values", %{ops: ops} do
    assert {:error, msg} =
             Validator.validate(ops["listPets"], %{
               query: %{"limit" => 5, "status" => "eaten"},
               body: nil
             })

    assert msg =~ "available"
    assert msg =~ "adopted"
  end

  test "missing required body", %{ops: ops} do
    assert {:error, msg} = Validator.validate(ops["createPet"], %{query: %{}, body: nil})
    assert msg =~ "request body"
  end

  test "missing required body field quotes the schema fragment", %{ops: ops} do
    assert {:error, msg} =
             Validator.validate(ops["createPet"], %{query: %{}, body: %{"name" => "Rex"}})

    assert msg =~ "species"
  end

  test "nested required fields are checked", %{ops: ops} do
    assert {:error, msg} =
             Validator.validate(ops["createPet"], %{
               query: %{},
               body: %{"name" => "Rex", "species" => "dog", "owner" => %{}}
             })

    assert msg =~ "email"
  end

  test "unknown enum inside body", %{ops: ops} do
    assert {:error, msg} =
             Validator.validate(ops["createPet"], %{
               query: %{},
               body: %{"name" => "Rex", "species" => "dragon"}
             })

    assert msg =~ "dog"
  end
end
```

**Step 2: Run to verify failure.**

**Step 3: Implement `lib/oapi_codemode/proxy/validator.ex`**

```elixir
defmodule OapiCodemode.Proxy.Validator do
  @moduledoc """
  Validates an intercepted request against the operation's dereferenced schema.

  Deliberately shallow: types, required, enums — recursively through objects,
  but no oneOf/anyOf/allOf arbitration, no pattern/format checks (v1 scope).
  Error messages quote the violated schema fragment: the spec is the
  documentation the model just read, so errors grounded in it are actionable.
  """

  alias OapiCodemode.Operation

  @spec validate(Operation.t(), %{query: map(), body: term()}) :: :ok | {:error, String.t()}
  def validate(%Operation{} = op, request) do
    with :ok <- validate_query(op, request.query || %{}) do
      validate_body(op, request.body)
    end
  end

  defp validate_query(op, query) do
    op.parameters
    |> Enum.filter(&(&1["in"] == "query"))
    |> Enum.reduce_while(:ok, fn param, :ok ->
      name = param["name"]
      value = query[name]

      cond do
        is_nil(value) and param["required"] ->
          {:halt, {:error, "query parameter #{inspect(name)} is required. Schema: #{frag(param)}"}}

        is_nil(value) ->
          {:cont, :ok}

        true ->
          case check(value, param["schema"], "query parameter #{inspect(name)}") do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp validate_body(%{request_body: nil}, _body), do: :ok

  defp validate_body(%{request_body: %{"required" => true, "schema" => schema}}, nil),
    do: {:error, "request body is required. Schema: #{frag(schema)}"}

  defp validate_body(_op, nil), do: :ok

  defp validate_body(%{request_body: %{"schema" => schema}}, body),
    do: check(body, schema, "request body")

  defp check(_value, nil, _where), do: :ok

  defp check(value, %{"enum" => enum} = schema, where) do
    if value in enum do
      check(value, Map.delete(schema, "enum"), where)
    else
      {:error, "#{where}: #{inspect(value)} is not one of #{inspect(enum)}. Schema: #{frag(schema)}"}
    end
  end

  defp check(value, %{"type" => "object"} = schema, where) when is_map(value) do
    required = schema["required"] || []
    properties = schema["properties"] || %{}

    missing = Enum.filter(required, &(not Map.has_key?(value, &1)))

    if missing != [] do
      {:error, "#{where}: missing required field(s) #{inspect(missing)}. Schema: #{frag(schema)}"}
    else
      Enum.reduce_while(value, :ok, fn {key, val}, :ok ->
        case check(val, properties[key], "#{where}.#{key}") do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp check(value, %{"type" => type} = schema, where) do
    if type_ok?(value, type) do
      :ok
    else
      {:error, "#{where}: expected #{type}, got #{inspect(value)}. Schema: #{frag(schema)}"}
    end
  end

  defp check(_value, _schema, _where), do: :ok

  defp type_ok?(v, "string"), do: is_binary(v)
  defp type_ok?(v, "integer"), do: is_integer(v) or (is_binary(v) and match?({_, ""}, Integer.parse(v)))
  defp type_ok?(v, "number"), do: is_number(v) or (is_binary(v) and match?({_, ""}, Float.parse(v)))
  defp type_ok?(v, "boolean"), do: is_boolean(v) or v in ["true", "false"]
  defp type_ok?(v, "array"), do: is_list(v)
  defp type_ok?(v, "object"), do: is_map(v)
  defp type_ok?(_v, _), do: true

  # Quote a compact schema fragment (capped so errors stay readable).
  defp frag(schema) do
    schema
    |> Map.take(["type", "required", "enum", "properties", "in", "name", "schema"])
    |> Jason.encode!()
    |> String.slice(0, 400)
  end
end
```

**Step 4: Run to verify pass. Step 5: Commit** — `"feat: spec-grounded request validator"`

---

### Task 10: Credentials — resolver behaviour and attachment

**Files:**
- Create: `lib/oapi_codemode/credentials.ex`
- Test: `test/oapi_codemode/credentials_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemode.CredentialsTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Credentials

  @bearer_scheme %{"type" => "http", "scheme" => "bearer"}
  @basic_scheme %{"type" => "http", "scheme" => "basic"}
  @header_key %{"type" => "apiKey", "in" => "header", "name" => "X-Api-Key"}
  @query_key %{"type" => "apiKey", "in" => "query", "name" => "api_key"}

  test "bearer credential becomes Authorization header" do
    assert {:ok, %{headers: [{"authorization", "Bearer tok123"}], query: %{}}} =
             Credentials.attach(@bearer_scheme, {:bearer, "tok123"})
  end

  test "basic credential is base64 encoded" do
    assert {:ok, %{headers: [{"authorization", "Basic " <> b64}], query: %{}}} =
             Credentials.attach(@basic_scheme, {:basic, "user", "pass"})

    assert Base.decode64!(b64) == "user:pass"
  end

  test "apiKey header uses the scheme's header name" do
    assert {:ok, %{headers: [{"X-Api-Key", "k"}], query: %{}}} =
             Credentials.attach(@header_key, {:api_key, "k"})
  end

  test "apiKey query uses the scheme's param name" do
    assert {:ok, %{headers: [], query: %{"api_key" => "k"}}} =
             Credentials.attach(@query_key, {:api_key, "k"})
  end

  test ":none attaches nothing" do
    assert {:ok, %{headers: [], query: %{}}} = Credentials.attach(nil, :none)
  end

  test "credential/scheme mismatch is an error naming both" do
    assert {:error, msg} = Credentials.attach(@bearer_scheme, {:api_key, "k"})
    assert msg =~ "api_key"
    assert msg =~ "bearer"
  end

  test "oauth2 scheme accepts a bearer token (OAuth access tokens are bearer at the wire)" do
    scheme = %{"type" => "oauth2", "flows" => %{}}

    assert {:ok, %{headers: [{"authorization", "Bearer at-42"}]}} =
             Credentials.attach(scheme, {:bearer, "at-42"})
  end
end
```

**Step 2: Run to verify failure.**

**Step 3: Implement `lib/oapi_codemode/credentials.ex`**

```elixir
defmodule OapiCodemode.Credentials do
  @moduledoc """
  Host-implemented credential resolution, library-implemented attachment.

  The host resolves *what* to attach (per request — so token refresh is the
  host's problem and stale tokens self-heal on the next call). The spec's
  securityScheme dictates *how* it is attached. Credential values never
  enter the sandbox or the transcript.
  """

  @type credential ::
          {:bearer, String.t()}
          | {:basic, String.t(), String.t()}
          | {:api_key, String.t()}
          | :none

  @doc """
  Resolve a credential for one request. `context` is the opaque identity map
  the host passed into the execute handler (tenant, user, org).
  """
  @callback resolve(api_name :: String.t(), scheme :: map() | nil, context :: map()) ::
              {:ok, credential()} | {:error, term()}

  @spec attach(map() | nil, credential()) ::
          {:ok, %{headers: [{String.t(), String.t()}], query: map()}} | {:error, String.t()}
  def attach(_scheme, :none), do: {:ok, %{headers: [], query: %{}}}

  def attach(%{"type" => "http", "scheme" => "bearer"}, {:bearer, token}),
    do: {:ok, %{headers: [{"authorization", "Bearer " <> token}], query: %{}}}

  # OAuth2 access tokens are bearer tokens at the wire.
  def attach(%{"type" => "oauth2"}, {:bearer, token}),
    do: {:ok, %{headers: [{"authorization", "Bearer " <> token}], query: %{}}}

  def attach(%{"type" => "openIdConnect"}, {:bearer, token}),
    do: {:ok, %{headers: [{"authorization", "Bearer " <> token}], query: %{}}}

  def attach(%{"type" => "http", "scheme" => "basic"}, {:basic, user, pass}),
    do:
      {:ok,
       %{headers: [{"authorization", "Basic " <> Base.encode64(user <> ":" <> pass)}], query: %{}}}

  def attach(%{"type" => "apiKey", "in" => "header", "name" => name}, {:api_key, value}),
    do: {:ok, %{headers: [{name, value}], query: %{}}}

  def attach(%{"type" => "apiKey", "in" => "query", "name" => name}, {:api_key, value}),
    do: {:ok, %{headers: [], query: %{name => value}}}

  def attach(scheme, credential) do
    {:error,
     "credential shape #{credential |> elem(0) |> to_string()} does not fit security scheme " <>
       inspect(Map.take(scheme || %{}, ["type", "scheme", "in", "name"]))}
  end
end
```

Note: `attach(scheme, :none)` must stay the first clause; `elem(0)` on `:none` would raise.

**Step 4: Run to verify pass. Step 5: Commit** — `"feat: credential resolver behaviour and scheme attachment"`

---

### Task 11: Query serialization (style/explode)

**Files:**
- Create: `lib/oapi_codemode/proxy/query.ex`
- Test: `test/oapi_codemode/proxy/query_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemode.Proxy.QueryTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Proxy.Query

  test "scalars serialize plainly" do
    assert Query.encode([{"limit", 5, %{}}]) == "limit=5"
  end

  test "form + explode=true (default) repeats array keys" do
    assert Query.encode([{"tag", ["a", "b"], %{}}]) == "tag=a&tag=b"
  end

  test "form + explode=false comma-joins arrays" do
    param = %{"style" => "form", "explode" => false}
    assert Query.encode([{"tag", ["a", "b"], param}]) == "tag=a%2Cb"
  end

  test "deepObject styles nested maps" do
    param = %{"style" => "deepObject", "explode" => true}

    assert Query.encode([{"filter", %{"status" => "open", "kind" => "x"}, param}]) ==
             "filter%5Bkind%5D=x&filter%5Bstatus%5D=open"
  end

  test "values are URI-encoded" do
    assert Query.encode([{"q", "a b&c", %{}}]) == "q=a+b%26c"
  end

  test "empty list of params is empty string" do
    assert Query.encode([]) == ""
  end
end
```

**Step 2: Run to verify failure.**

**Step 3: Implement `lib/oapi_codemode/proxy/query.ex`**

```elixir
defmodule OapiCodemode.Proxy.Query do
  @moduledoc """
  Serializes query parameters honoring the spec's style/explode declarations
  (the ele lesson: default serializers silently mismatch backend expectations).
  Supported: form (explode true/false), deepObject. Anything else falls back
  to form+explode.
  """

  @spec encode([{String.t(), term(), map()}]) :: String.t()
  def encode(params) do
    params
    |> Enum.flat_map(&pairs/1)
    |> Enum.sort()
    |> URI.encode_query()
  end

  defp pairs({name, value, param_spec}) when is_list(value) do
    if param_spec["explode"] == false do
      [{name, Enum.map_join(value, ",", &to_string/1)}]
    else
      Enum.map(value, &{name, to_string(&1)})
    end
  end

  defp pairs({name, value, %{"style" => "deepObject"}}) when is_map(value) do
    Enum.map(value, fn {k, v} -> {"#{name}[#{k}]", to_string(v)} end)
  end

  defp pairs({name, value, _param_spec}), do: [{name, to_string(value)}]
end
```

**Step 4: Run to verify pass. Step 5: Commit** — `"feat: style/explode-aware query serialization"`

---

### Task 12: Proxy pipeline

**Files:**
- Create: `lib/oapi_codemode/proxy.ex`
- Test: `test/oapi_codemode/proxy_test.exs`

**Step 1: Write the failing test.** Uses `Req.Test` to stub the upstream.

```elixir
defmodule OapiCodemode.ProxyTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.{Proxy, Ingest, ApiConfig, Fixtures}
  alias OapiCodemode.Registry.Entry

  defmodule StaticResolver do
    @behaviour OapiCodemode.Credentials
    @impl true
    def resolve("petstore", _scheme, %{token: token}), do: {:ok, {:bearer, token}}
    def resolve(_, _, _), do: {:error, :no_credential}
  end

  setup do
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())

    entry = %Entry{
      artifact: art,
      config: %ApiConfig{base_url: "https://petstore.example.com/v1"}
    }

    ctx = %{
      resolver: StaticResolver,
      context: %{token: "tok-1"},
      policy: :all,
      req_options: [plug: {Req.Test, OapiCodemodeStub}]
    }

    %{entry: entry, ctx: ctx}
  end

  test "happy path: GET with auth and query", %{entry: entry, ctx: ctx} do
    Req.Test.stub(OapiCodemodeStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok-1"]
      assert conn.request_path == "/v1/pets"
      assert conn.query_string =~ "limit=5"
      Req.Test.json(conn, %{"pets" => []})
    end)

    assert {:ok, resp} =
             Proxy.request(entry, "petstore", %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 5}}, ctx)

    assert resp.status == 200
    assert resp.body == %{"pets" => []}
  end

  test "path params substitute into the URL", %{entry: entry, ctx: ctx} do
    Req.Test.stub(OapiCodemodeStub, fn conn ->
      assert conn.request_path == "/v1/pets/42"
      Req.Test.json(conn, %{"id" => "42"})
    end)

    assert {:ok, %{status: 200}} =
             Proxy.request(entry, "petstore", %{"method" => "GET", "path" => "/pets/42"}, ctx)
  end

  test "unknown path rejects with suggestions before any HTTP", %{entry: entry, ctx: ctx} do
    assert {:error, %{phase: :match, message: msg}} =
             Proxy.request(entry, "petstore", %{"method" => "GET", "path" => "/petz"}, ctx)

    assert msg =~ "GET /pets"
  end

  test "validation failure rejects before any HTTP", %{entry: entry, ctx: ctx} do
    assert {:error, %{phase: :validate, message: msg}} =
             Proxy.request(entry, "petstore", %{"method" => "GET", "path" => "/pets"}, ctx)

    assert msg =~ "limit"
  end

  test "read_only policy rejects non-GET", %{entry: entry, ctx: ctx} do
    ctx = %{ctx | policy: :read_only}

    assert {:error, %{phase: :policy, message: msg}} =
             Proxy.request(
               entry,
               "petstore",
               %{"method" => "POST", "path" => "/pets", "body" => %{"name" => "R", "species" => "dog"}},
               ctx
             )

    assert msg =~ "read-only"
  end

  test "credential failure is distinct from upstream 401", %{entry: entry, ctx: ctx} do
    ctx = %{ctx | context: %{}}

    assert {:error, %{phase: :credentials}} =
             Proxy.request(entry, "petstore", %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 1}}, ctx)
  end

  test "upstream errors pass through as responses", %{entry: entry, ctx: ctx} do
    Req.Test.stub(OapiCodemodeStub, fn conn ->
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "slow down"})
    end)

    assert {:ok, %{status: 429, body: %{"error" => _}}} =
             Proxy.request(entry, "petstore", %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 1}}, ctx)
  end

  test "JSON body is posted; response headers are whitelisted", %{entry: entry, ctx: ctx} do
    Req.Test.stub(OapiCodemodeStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw)["species"] == "dog"

      conn
      |> Plug.Conn.put_resp_header("x-secret-internal", "hide-me")
      |> Plug.Conn.put_resp_header("x-request-id", "req-9")
      |> Req.Test.json(%{"ok" => true})
    end)

    {:ok, resp} =
      Proxy.request(
        entry,
        "petstore",
        %{"method" => "POST", "path" => "/pets", "body" => %{"name" => "R", "species" => "dog"}},
        ctx
      )

    assert {"x-request-id", "req-9"} in resp.headers
    refute Enum.any?(resp.headers, fn {k, _} -> k == "x-secret-internal" end)
  end

  test "emits telemetry", %{entry: entry, ctx: ctx} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:oapi_codemode, :request, :stop]])

    Req.Test.stub(OapiCodemodeStub, fn conn -> Req.Test.json(conn, %{}) end)
    {:ok, _} = Proxy.request(entry, "petstore", %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 1}}, ctx)

    assert_receive {[:oapi_codemode, :request, :stop], ^ref, %{duration: _},
                    %{api: "petstore", operation: "listPets", status: 200}}
  end
end
```

**Step 2: Run to verify failure.**

**Step 3: Implement `lib/oapi_codemode/proxy.ex`**

```elixir
defmodule OapiCodemode.Proxy do
  @moduledoc """
  The validating, credential-injecting request pipeline:
  match -> validate -> policy -> credentials -> execute -> normalize.

  Requests come from the sandbox as JSON-shaped maps (string keys). Errors
  return `%{phase: atom, message: String.t()}` — phase-tagged so tool-layer
  error messages can say what failed without leaking internals.
  """

  alias OapiCodemode.{ApiConfig, Credentials}
  alias OapiCodemode.Proxy.{Matcher, Query, Validator}
  alias OapiCodemode.Registry.Entry

  @response_header_whitelist ~w(content-type x-request-id retry-after)
  @response_header_prefixes ~w(x-ratelimit-)

  @type request_opts :: %{required(String.t()) => term()}
  @type ctx :: %{
          resolver: module(),
          context: map(),
          policy: :read_only | :all,
          req_options: keyword()
        }

  @spec request(%Entry{}, String.t(), request_opts(), ctx()) ::
          {:ok, %{status: integer(), headers: list(), body: term()}}
          | {:error, %{phase: atom(), message: String.t()}}
  def request(%Entry{} = entry, api_name, opts, ctx) do
    method = opts |> Map.get("method", "GET") |> to_string()
    path = Map.get(opts, "path", "")
    query = Map.get(opts, "query") || %{}
    body = Map.get(opts, "body")

    meta = %{api: api_name, operation: nil, method: String.downcase(method)}
    start = System.monotonic_time()
    :telemetry.execute([:oapi_codemode, :request, :start], %{}, meta)

    result =
      with {:ok, op, path_params} <- match(entry, method, path),
           :ok <- policy(ctx.policy, op.method),
           :ok <- validate(entry.config, op, query, body),
           {:ok, auth} <- credentials(entry, api_name, op, ctx),
           {:ok, resp} <- execute(entry.config, op, path_params, query, body, auth, opts, ctx) do
        {:ok, resp, op}
      end

    case result do
      {:ok, resp, op} ->
        emit_stop(start, %{meta | operation: op.id}, resp.status)
        {:ok, resp}

      {:error, %{phase: _} = err} ->
        :telemetry.execute([:oapi_codemode, :request, :error], %{}, Map.put(meta, :error, err.phase))
        {:error, err}
    end
  end

  defp emit_stop(start, meta, status) do
    duration = System.monotonic_time() - start
    :telemetry.execute([:oapi_codemode, :request, :stop], %{duration: duration}, Map.put(meta, :status, status))
  end

  defp match(entry, method, path) do
    case Matcher.match(entry.artifact.operations, method, path) do
      {:ok, op, params} ->
        {:ok, op, params}

      {:error, {:no_match, suggestions}} ->
        {:error,
         %{
           phase: :match,
           message:
             "no operation matches #{String.upcase(method)} #{path}. Nearest: " <>
               Enum.join(suggestions, ", ")
         }}
    end
  end

  defp policy(:all, _method), do: :ok
  defp policy(:read_only, "get"), do: :ok
  defp policy(:read_only, "head"), do: :ok

  defp policy(:read_only, method),
    do:
      {:error,
       %{
         phase: :policy,
         message:
           "#{String.upcase(method)} requests are not allowed by this read-only tool. " <>
             "Use the mutations variant of the execute tool."
       }}

  defp validate(%ApiConfig{validate: :off}, _op, _query, _body), do: :ok

  defp validate(%ApiConfig{validate: mode}, op, query, body) do
    case Validator.validate(op, %{query: query, body: body}) do
      :ok ->
        :ok

      {:error, message} when mode == :warn ->
        require Logger
        Logger.warning("oapi_codemode validation (warn mode): #{message}")
        :ok

      {:error, message} ->
        {:error, %{phase: :validate, message: message}}
    end
  end

  defp credentials(entry, api_name, op, ctx) do
    scheme = selected_scheme(entry, op)

    with {:ok, credential} <- ctx.resolver.resolve(api_name, scheme, ctx.context),
         {:ok, auth} <- Credentials.attach(scheme, credential) do
      {:ok, auth}
    else
      {:error, message} when is_binary(message) ->
        {:error, %{phase: :credentials, message: message}}

      {:error, reason} ->
        {:error, %{phase: :credentials, message: "credential resolution failed: #{inspect(reason)}"}}
    end
  end

  defp selected_scheme(entry, op) do
    schemes = entry.artifact.security_schemes

    name =
      entry.config.security_scheme ||
        case op.security do
          [req | _] when is_map(req) and map_size(req) > 0 -> req |> Map.keys() |> hd()
          _ -> nil
        end

    if name, do: schemes[name], else: nil
  end

  defp execute(config, op, path_params, query, body, auth, opts, ctx) do
    url = build_url(config.base_url, op, path_params)

    query_string =
      op.parameters
      |> Enum.filter(&(&1["in"] == "query"))
      |> Enum.flat_map(fn p ->
        case Map.fetch(query, p["name"]) do
          {:ok, v} -> [{p["name"], v, p}]
          :error -> []
        end
      end)
      |> Kernel.++(extra_query(query, op))
      |> Kernel.++(Enum.map(auth.query, fn {k, v} -> {k, v, %{}} end))
      |> Query.encode()

    full_url = if query_string == "", do: url, else: url <> "?" <> query_string

    {req_body, content_type} = encode_body(body, opts)

    headers =
      auth.headers ++ if content_type, do: [{"content-type", content_type}], else: []

    req =
      Req.new(
        [
          method: String.to_existing_atom(op.method),
          url: full_url,
          headers: headers,
          body: req_body,
          retry: false,
          max_retries: 0
        ] ++ ctx.req_options
      )

    case Req.request(req) do
      {:ok, resp} ->
        {:ok,
         %{
           status: resp.status,
           headers: whitelist_headers(resp.headers),
           body: cap_body(resp.body, config.max_response_bytes)
         }}

      {:error, err} ->
        {:error, %{phase: :transport, message: "request failed: #{Exception.message(err)}"}}
    end
  end

  defp build_url(base_url, op, path_params) do
    path =
      Enum.map_join(op.segments, "/", fn
        {:param, name} -> path_params |> Map.fetch!(name) |> to_string() |> URI.encode_www_form()
        seg -> seg
      end)

    String.trim_trailing(base_url, "/") <> "/" <> path
  end

  # Query keys the spec doesn't declare still pass through (validate mode
  # already had its say); serialize them form/explode-default.
  defp extra_query(query, op) do
    declared = op.parameters |> Enum.filter(&(&1["in"] == "query")) |> MapSet.new(& &1["name"])

    query
    |> Enum.reject(fn {k, _} -> MapSet.member?(declared, k) end)
    |> Enum.map(fn {k, v} -> {k, v, %{}} end)
  end

  defp encode_body(nil, _opts), do: {nil, nil}

  defp encode_body(body, %{"rawBody" => true} = opts),
    do: {body, opts["contentType"] || "application/octet-stream"}

  defp encode_body(body, opts),
    do: {Jason.encode!(body), opts["contentType"] || "application/json"}

  defp whitelist_headers(headers) do
    headers
    |> Enum.flat_map(fn {k, vs} -> Enum.map(List.wrap(vs), &{String.downcase(k), &1}) end)
    |> Enum.filter(fn {k, _} ->
      k in @response_header_whitelist or Enum.any?(@response_header_prefixes, &String.starts_with?(k, &1))
    end)
  end

  defp cap_body(body, max_bytes) when is_binary(body) do
    if byte_size(body) > max_bytes do
      String.slice(body, 0, max_bytes) <> "\n[truncated: response exceeded #{max_bytes} bytes]"
    else
      body
    end
  end

  # Req already decoded JSON; cap after re-encoding only if enormous.
  defp cap_body(body, max_bytes) do
    encoded = Jason.encode!(body)

    if byte_size(encoded) > max_bytes do
      String.slice(encoded, 0, max_bytes) <> "\n[truncated: response exceeded #{max_bytes} bytes]"
    else
      body
    end
  end
end
```

Add `{:telemetry_test, "~> 0.1", only: :test}`? No — `:telemetry_test` ships inside `telemetry` ≥ 1.1; no new dep. If `:telemetry_test` is unavailable, attach a manual handler in the test instead.

**Step 4: Run to verify pass.** Expect iteration here — Req.Test wiring and header normalization across Req versions are the likely friction points. Fix implementation, not test intent.

**Step 5: Commit** — `"feat: proxy pipeline (match, validate, policy, credentials, execute, telemetry)"`

---

### Task 13: Executor behaviour + Mock executor

**Files:**
- Create: `lib/oapi_codemode/executor.ex`
- Create: `lib/oapi_codemode/executor/mock.ex`
- Test: `test/oapi_codemode/executor/mock_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemode.Executor.MockTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Executor.Mock

  test "returns the canned value and records the run" do
    Mock.set_response(fn code, env ->
      send(self(), {:ran, code, env})
      {:ok, %{value: %{"found" => 2}, logs: ["hi"]}}
    end)

    assert {:ok, %{value: %{"found" => 2}, logs: ["hi"]}} =
             Mock.run("async () => 1", %{globals: %{"specs" => %{}}, callbacks: %{}}, [])

    assert_received {:ran, "async () => 1", %{globals: %{"specs" => %{}}}}
  end

  test "can drive the request callback to simulate execute-tool code" do
    Mock.set_response(fn _code, env ->
      result = env.callbacks.request.("petstore", %{"method" => "GET", "path" => "/pets"})
      {:ok, %{value: result, logs: []}}
    end)

    callback = fn "petstore", %{"path" => "/pets"} -> %{"status" => 200} end

    assert {:ok, %{value: %{"status" => 200}}} =
             Mock.run("code", %{globals: %{}, callbacks: %{request: callback}}, [])
  end
end
```

**Step 2: Run to verify failure.**

**Step 3: Implement.** `lib/oapi_codemode/executor.ex`:

```elixir
defmodule OapiCodemode.Executor do
  @moduledoc """
  The sandbox contract — the entire interface a TS execution environment
  must satisfy. Deliberately minimal: run code with globals and callbacks,
  return the value and console output.

  Requirements for real implementations:
    * No network access inside the sandbox.
    * `globals` are injected as JSON data before the code runs.
    * `callbacks.request` may be invoked CONCURRENTLY (Promise.all).
    * The boundary is JSON-native: values crossing it survive
      JSON encode/decode unchanged.
    * On timeout, return `{:error, {:timeout, ms}}`.
  """

  @type env :: %{globals: map(), callbacks: %{optional(:request) => fun()}}
  @type result :: %{value: term(), logs: [String.t()]}

  @callback run(code :: String.t(), env(), opts :: keyword()) ::
              {:ok, result()} | {:error, term()}
end
```

`lib/oapi_codemode/executor/mock.ex`:

```elixir
defmodule OapiCodemode.Executor.Mock do
  @moduledoc """
  Test executor: the "sandbox" is an Elixir function you set per test.
  Exercises the plumbing (globals in, callbacks out, results back) without
  a JS runtime.
  """

  @behaviour OapiCodemode.Executor

  @key {__MODULE__, :response}

  def set_response(fun) when is_function(fun, 2), do: Process.put(@key, fun)

  @impl true
  def run(code, env, _opts) do
    case Process.get(@key) do
      nil -> {:error, :no_mock_response_set}
      fun -> fun.(code, env)
    end
  end
end
```

**Step 4: Run to verify pass. Step 5: Commit** — `"feat: executor behaviour and mock executor"`

---

### Task 14: Tool descriptions

**Files:**
- Create: `lib/oapi_codemode/tools/descriptions.ex`
- Test: `test/oapi_codemode/tools/descriptions_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemode.Tools.DescriptionsTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Tools.Descriptions
  alias OapiCodemode.{Registry, Ingest, ApiConfig, Fixtures}

  setup do
    reg = start_supervised!({Registry, name: nil})
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())
    :ok = Registry.register(reg, "petstore", art, %ApiConfig{context: %{"storeId" => "s1"}})
    %{reg: reg}
  end

  test "search description lists APIs, tags, spec shape types, and examples", %{reg: reg} do
    desc = Descriptions.search(Registry.list(reg))
    assert desc =~ "petstore"
    assert desc =~ "Petstore"
    # tag vocabulary
    assert desc =~ "pets"
    # spec-shape TS declarations (CF-style)
    assert desc =~ "interface OperationInfo"
    assert desc =~ "specs.petstore.paths"
    # worked example
    assert desc =~ "Object.entries"
  end

  test "execute description documents request options, response shape, and context globals", %{reg: reg} do
    desc = Descriptions.execute(Registry.list(reg))
    assert desc =~ "apis.petstore.request"
    assert desc =~ "contentType"
    assert desc =~ "rawBody"
    assert desc =~ "storeId"
    assert desc =~ "status"
  end

  test "tag vocabularies are truncated past the limit", %{reg: reg} do
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())
    many_tags = %{art | tags: Enum.map(1..100, &"tag#{&1}")}
    reg2 = start_supervised!({Registry, name: nil}, id: :reg2)
    :ok = Registry.register(reg2, "big", many_tags, %ApiConfig{base_url: "https://x.example.com"})

    desc = Descriptions.search(Registry.list(reg2))
    assert desc =~ "tag1"
    refute desc =~ "tag99"
    assert desc =~ "100 total"
  end
end
```

**Step 2: Run to verify failure.**

**Step 3: Implement `lib/oapi_codemode/tools/descriptions.ex`.** Assemble from registry entries. Keep the TS declarations near-verbatim from CF's server (they are proven against real LLM traffic):

```elixir
defmodule OapiCodemode.Tools.Descriptions do
  @moduledoc "Assembles search/execute tool descriptions from registry state. The description IS the documentation."

  @max_tags 40

  def search(entries) do
    """
    Search the OpenAPI specs of the registered APIs by running JavaScript
    against them. All $refs are pre-resolved inline (circular refs appear as
    {"$circular": "Name"}). Submit an async arrow function; whatever it
    returns is your result. Only what you return enters your context.

    Registered APIs:
    #{Enum.map_join(entries, "\n", &api_line/1)}

    Types:

    interface OperationInfo {
      summary?: string;
      description?: string;
      tags?: string[];
      parameters?: Array<{ name: string; in: string; required?: boolean; schema?: unknown; description?: string }>;
      requestBody?: { required?: boolean; content?: Record<string, { schema?: unknown }> };
      responses?: Record<string, { description?: string; content?: Record<string, { schema?: unknown }> }>;
    }

    interface PathItem {
      get?: OperationInfo; post?: OperationInfo; put?: OperationInfo;
      patch?: OperationInfo; delete?: OperationInfo;
    }

    declare const specs: Record<string, { info: {title: string, description?: string}, paths: Record<string, PathItem> }>;

    Examples:

    // Find operations by keyword across all APIs
    async () => {
      const results = [];
      for (const [apiName, spec] of Object.entries(specs)) {
        for (const [path, methods] of Object.entries(spec.paths)) {
          for (const [method, op] of Object.entries(methods)) {
            const text = `${op.summary ?? ""} ${op.description ?? ""} ${(op.tags ?? []).join(" ")}`.toLowerCase();
            if (text.includes("pet")) results.push({ api: apiName, method: method.toUpperCase(), path, summary: op.summary });
          }
        }
      }
      return results;
    }

    // Get one endpoint's request body schema (refs already resolved)
    async () => specs.petstore.paths["/pets"].post?.requestBody
    """
  end

  def execute(entries) do
    """
    Execute JavaScript that calls the registered APIs. First use the search
    tool to find the right operations, then call apis.<name>.request().
    Requests are validated against the spec and credentialed server-side;
    you never handle credentials.

    interface RequestOptions {
      method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
      path: string;                        // e.g. "/pets/42" — path only, no host
      query?: Record<string, unknown>;
      body?: unknown;
      contentType?: string;                // default application/json when body present
      rawBody?: boolean;                   // send body as-is, no JSON.stringify
    }

    interface Response { status: number; headers: Record<string, string>; body: unknown; }

    declare const apis: Record<string, { request(opts: RequestOptions): Promise<Response> }>;

    Available: #{Enum.map_join(entries, ", ", fn {name, _} -> "apis.#{name}" end)}
    #{context_globals(entries)}

    Your code must be an async arrow function that returns the result.
    Concurrent requests via Promise.all are fine.

    Example:
    async () => {
      const r = await apis.petstore.request({ method: "GET", path: "/pets", query: { limit: 10 } });
      return r.body;
    }
    """
  end

  defp api_line({name, entry}) do
    title = entry.artifact.title || name
    "- specs.#{name} — #{title}. Tags: #{tags(entry.artifact.tags)}"
  end

  defp tags(tags) when length(tags) > @max_tags do
    shown = Enum.take(tags, @max_tags)
    Enum.join(shown, ", ") <> "... (#{length(tags)} total)"
  end

  defp tags(tags), do: Enum.join(tags, ", ")

  defp context_globals(entries) do
    lines =
      for {name, entry} <- entries, map_size(entry.config.context) > 0 do
        "Context globals for #{name}: #{Jason.encode!(entry.config.context)}"
      end

    Enum.join(lines, "\n")
  end
end
```

**Step 4: Run to verify pass** (adjust assertions only if they contradict the actual proven-good text — the CF-derived structure is the spec here).

**Step 5: Commit** — `"feat: registry-driven tool descriptions"`

---

### Task 15: Tools — search and execute handlers

**Files:**
- Create: `lib/oapi_codemode/tools.ex`
- Create: `lib/oapi_codemode/tools/result.ex`
- Test: `test/oapi_codemode/tools_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemode.ToolsTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.{Tools, Registry, Ingest, ApiConfig, Fixtures}
  alias OapiCodemode.Executor.Mock

  defmodule NoneResolver do
    @behaviour OapiCodemode.Credentials
    @impl true
    def resolve(_, _, _), do: {:ok, :none}
  end

  setup do
    reg = start_supervised!({Registry, name: nil})
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())
    :ok = Registry.register(reg, "petstore", art, %ApiConfig{})

    opts = [
      registry: reg,
      executor: Mock,
      resolver: NoneResolver,
      policy: :read_only,
      max_result_tokens: 6000
    ]

    %{reg: reg, opts: opts}
  end

  test "definitions expose two tools with schemas", %{opts: opts} do
    defs = Tools.definitions(opts)
    assert [%{name: "search_apis"}, %{name: "execute_api_code"}] = Enum.sort_by(defs, & &1.name, :desc) |> Enum.reverse() |> Enum.sort_by(& &1.name)
    search = Enum.find(defs, &(&1.name == "search_apis"))
    assert search.input_schema["required"] == ["code"]
    assert is_function(search.handler, 2)
  end

  test "search runs code against specs global and JSON-encodes the result", %{opts: opts} do
    Mock.set_response(fn code, env ->
      assert code =~ "spec"
      assert %{"petstore" => %{"paths" => _}} = env.globals["specs"]
      {:ok, %{value: [%{"path" => "/pets"}], logs: []}}
    end)

    search = Tools.definitions(opts) |> Enum.find(&(&1.name == "search_apis"))
    assert {:ok, result} = search.handler.(%{"code" => "async () => spec"}, %{})
    assert result =~ ~s([{"path":"/pets"}])
  end

  test "search sandbox gets no callbacks", %{opts: opts} do
    Mock.set_response(fn _code, env ->
      assert env.callbacks == %{}
      {:ok, %{value: nil, logs: []}}
    end)

    search = Tools.definitions(opts) |> Enum.find(&(&1.name == "search_apis"))
    assert {:ok, _} = search.handler.(%{"code" => "async () => null"}, %{})
  end

  test "oversized results are truncated with an instructive trailer", %{opts: opts} do
    big = List.duplicate(%{"x" => String.duplicate("a", 100)}, 2000)
    Mock.set_response(fn _c, _e -> {:ok, %{value: big, logs: []}} end)

    search = Tools.definitions(opts) |> Enum.find(&(&1.name == "search_apis"))
    {:ok, result} = search.handler.(%{"code" => "async () => big"}, %{})
    assert String.length(result) < 30_000
    assert result =~ "Use more specific queries"
  end

  test "execute wires request callback through the proxy", %{opts: opts} do
    Mock.set_response(fn _code, env ->
      # simulate sandbox code calling apis.petstore.request(...)
      result = env.callbacks.request.("petstore", %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 1}})
      {:ok, %{value: result, logs: []}}
    end)

    execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))

    {:ok, result} =
      execute.handler.(%{"code" => "async () => ..."}, %{req_options: [plug: {Req.Test, ToolStub}]})

    Req.Test.stub(ToolStub, fn conn -> Req.Test.json(conn, %{"pets" => []}) end)
    # callback errors surface as data, not crashes:
    assert result =~ "calls" or result =~ "error"
  end

  test "execute records call metadata even when code returns a summary", %{opts: opts} do
    Req.Test.stub(ToolStub2, fn conn -> Req.Test.json(conn, %{"pets" => []}) end)

    Mock.set_response(fn _code, env ->
      env.callbacks.request.("petstore", %{"method" => "GET", "path" => "/pets", "query" => %{"limit" => 1}})
      {:ok, %{value: "done", logs: ["log line"]}}
    end)

    execute = Tools.definitions(opts) |> Enum.find(&(&1.name == "execute_api_code"))
    {:ok, result} = execute.handler.(%{"code" => "..."}, %{req_options: [plug: {Req.Test, ToolStub2}]})

    decoded = Jason.decode!(result)
    assert decoded["result"] == "done"
    assert decoded["logs"] == ["log line"]
    assert [%{"operation" => "listPets", "status" => 200}] = decoded["calls"]
  end

  test "sandbox errors come back as phase-tagged tool errors", %{opts: opts} do
    Mock.set_response(fn _c, _e -> {:error, "ReferenceError: nope is not defined"} end)
    search = Tools.definitions(opts) |> Enum.find(&(&1.name == "search_apis"))
    assert {:error, msg} = search.handler.(%{"code" => "async () => nope"}, %{})
    assert msg =~ "sandbox"
    assert msg =~ "ReferenceError"
  end
end
```

**Step 2: Run to verify failure.**

**Step 3: Implement.** `lib/oapi_codemode/tools/result.ex`:

```elixir
defmodule OapiCodemode.Tools.Result do
  @moduledoc "JSON-encodes tool results with a token-measured cap and instructive trailer."

  # ~4 chars per token is close enough for a budget cap.
  @chars_per_token 4

  def encode(value, max_tokens) do
    json = Jason.encode!(value)
    max_chars = max_tokens * @chars_per_token

    if String.length(json) <= max_chars do
      {:ok, json}
    else
      approx = div(String.length(json), @chars_per_token)

      {:ok,
       String.slice(json, 0, max_chars) <>
         "\n--- TRUNCATED ---\n" <>
         "Result was ~#{approx} tokens (limit: #{max_tokens}). " <>
         "Use more specific queries to reduce result size."}
    end
  end
end
```

`lib/oapi_codemode/tools.ex`:

```elixir
defmodule OapiCodemode.Tools do
  @moduledoc """
  Emits the two codemode tools as data plus handlers. Transport-agnostic:
  hosts wrap these into their own tool layers (gentility's CloudLoop.Tool,
  ele's UserMCP.Tool, or a gen_mcp server).

  `definitions/1` opts:
    * `:registry` (required) — the Registry server
    * `:executor` (required) — module implementing OapiCodemode.Executor
    * `:resolver` (required) — module implementing OapiCodemode.Credentials
    * `:policy` — :read_only (default) or :all
    * `:max_result_tokens` — default 6000
    * `:timeout` — sandbox timeout ms, default 30_000

  Handler contract: `handler.(args, host_ctx) -> {:ok, json_string} | {:error, message}`.
  `host_ctx` may carry `:context` (opaque identity for the credential
  resolver) and `:req_options` (extra Req options, e.g. Req.Test plugs).
  """

  alias OapiCodemode.{Proxy, Registry}
  alias OapiCodemode.Tools.{Descriptions, Result}

  @code_schema %{
    "type" => "object",
    "properties" => %{
      "code" => %{"type" => "string", "description" => "JavaScript async arrow function"}
    },
    "required" => ["code"]
  }

  def definitions(opts) do
    entries = Registry.list(Keyword.fetch!(opts, :registry))

    [
      %{
        name: "search_apis",
        description: Descriptions.search(entries),
        input_schema: @code_schema,
        handler: fn args, host_ctx -> search(args, host_ctx, opts) end
      },
      %{
        name: "execute_api_code",
        description: Descriptions.execute(entries),
        input_schema: @code_schema,
        handler: fn args, host_ctx -> execute(args, host_ctx, opts) end
      }
    ]
  end

  defp search(%{"code" => code}, _host_ctx, opts) do
    entries = Registry.list(Keyword.fetch!(opts, :registry))
    globals = %{"specs" => Map.new(entries, fn {name, e} -> {name, e.artifact.spec} end)}

    run(opts, code, %{globals: globals, callbacks: %{}}, fn %{value: value} ->
      Result.encode(value, max_tokens(opts))
    end)
  end

  defp execute(%{"code" => code}, host_ctx, opts) do
    registry = Keyword.fetch!(opts, :registry)
    entries = Registry.list(registry)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    ctx = %{
      resolver: Keyword.fetch!(opts, :resolver),
      context: Map.get(host_ctx, :context, %{}),
      policy: Keyword.get(opts, :policy, :read_only),
      req_options: Map.get(host_ctx, :req_options, [])
    }

    request_callback = fn api_name, req_opts ->
      started = System.monotonic_time(:millisecond)

      {payload, status} =
        with {:ok, entry} <- Registry.lookup(registry, api_name),
             {:ok, resp} <- Proxy.request(entry, api_name, req_opts, ctx) do
          {%{"status" => resp.status, "headers" => Map.new(resp.headers), "body" => resp.body},
           resp.status}
        else
          {:error, :unknown_api} ->
            known = Enum.map_join(entries, ", ", fn {n, _} -> n end)
            {%{"error" => "unknown API #{inspect(api_name)}. Registered: #{known}"}, :error}

          {:error, %{phase: phase, message: message}} ->
            {%{"error" => "[#{phase}] #{message}"}, :error}
        end

      Agent.update(calls, fn acc ->
        [
          %{
            "api" => api_name,
            "operation" => req_opts["path"],
            "status" => status_label(status),
            "duration_ms" => System.monotonic_time(:millisecond) - started
          }
          | acc
        ]
      end)

      payload
    end

    globals =
      %{"apiNames" => Enum.map(entries, fn {name, _} -> name end)}
      |> Map.merge(context_globals(entries))

    result =
      run(opts, code, %{globals: globals, callbacks: %{request: request_callback}}, fn out ->
        call_log = calls |> Agent.get(&Enum.reverse/1) |> annotate_operations(registry)

        Result.encode(
          %{"result" => out.value, "logs" => out.logs, "calls" => call_log},
          max_tokens(opts)
        )
      end)

    Agent.stop(calls)
    result
  end

  defp run(opts, code, env, on_ok) do
    executor = Keyword.fetch!(opts, :executor)
    timeout = Keyword.get(opts, :timeout, 30_000)

    case executor.run(code, env, timeout: timeout) do
      {:ok, out} -> on_ok.(out)
      {:error, {:timeout, ms}} -> {:error, "sandbox timed out after #{ms} ms"}
      {:error, reason} -> {:error, "sandbox error: #{sanitize(reason)}"}
    end
  end

  # Error hygiene (the ele formatError lesson): first line only, no file
  # paths or data-URL stack frames. Full detail belongs in host logs.
  defp sanitize(reason) do
    reason
    |> to_string()
    |> String.split("\n")
    |> hd()
    |> String.slice(0, 500)
  rescue
    _ -> inspect(reason) |> String.slice(0, 500)
  end

  defp status_label(:error), do: "error"
  defp status_label(code), do: code

  defp annotate_operations(call_log, registry) do
    Enum.map(call_log, fn call ->
      with {:ok, entry} <- Registry.lookup(registry, call["api"]),
           {:ok, op, _} <-
             OapiCodemode.Proxy.Matcher.match(entry.artifact.operations, "get", call["operation"]) do
        Map.put(call, "operation", op.id)
      else
        _ -> call
      end
    end)
  end

  defp context_globals(entries) do
    contexts =
      for {name, entry} <- entries, map_size(entry.config.context) > 0, into: %{} do
        {name, entry.config.context}
      end

    if map_size(contexts) > 0, do: %{"context" => contexts}, else: %{}
  end

  defp max_tokens(opts), do: Keyword.get(opts, :max_result_tokens, 6000)
end
```

Note on `annotate_operations`: it re-matches with method "get" which is wrong for non-GET calls. Simplify during implementation: record the operation id inside `request_callback` at proxy-match time instead — change `Proxy.request/4` to return `{:ok, resp, op_id}`? No: keep `Proxy.request/4` stable and have the callback store `req_opts["method"] <> " " <> req_opts["path"]` as `"operation"`, dropping `annotate_operations/2` entirely. The test asserting `"operation" => "listPets"` should then assert `"GET /pets"`. Take whichever cut is cleaner when you get here — but do not let the metadata lie about the method.

**Step 4: Run to verify pass.** The execute tests exercise real Proxy + Req.Test through the Mock executor; expect wiring iteration.

**Step 5: Commit** — `"feat: search and execute tool handlers with capped results and call metadata"`

---

### Task 16: Top-level facade + README

**Files:**
- Modify: `lib/oapi_codemode.ex`
- Create: `README.md` (replace generated)
- Test: `test/oapi_codemode_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule OapiCodemodeTest do
  use ExUnit.Case, async: true

  test "ingest_and_register convenience" do
    reg = start_supervised!({OapiCodemode.Registry, name: nil})

    assert :ok =
             OapiCodemode.ingest_and_register(reg, "petstore", OapiCodemode.Fixtures.clean_3_1(),
               base_url: "https://petstore.example.com/v1"
             )

    assert {:ok, _} = OapiCodemode.Registry.lookup(reg, "petstore")
  end

  test "tools/1 delegates to Tools.definitions" do
    reg = start_supervised!({OapiCodemode.Registry, name: nil})

    defs =
      OapiCodemode.tools(
        registry: reg,
        executor: OapiCodemode.Executor.Mock,
        resolver: OapiCodemodeTest.NoopResolver
      )

    assert length(defs) == 2
  end

  defmodule NoopResolver do
    @behaviour OapiCodemode.Credentials
    @impl true
    def resolve(_, _, _), do: {:ok, :none}
  end
end
```

**Step 2: Run to verify failure. Step 3: Implement `lib/oapi_codemode.ex`:**

```elixir
defmodule OapiCodemode do
  @moduledoc """
  OpenAPI search-and-execute for LLM agents, Cloudflare-codemode style.

  Drop in an OpenAPI spec; get two tools: `search_apis` (LLM-written JS
  filters the spec as data in a sandbox) and `execute_api_code` (LLM-written
  JS calls `apis.<name>.request()`, intercepted, validated against the spec,
  credentialed, and executed in Elixir). Credentials never enter the sandbox.

  See docs/plans/2026-08-16-openapi-search-execute-design.md for the design.
  """

  alias OapiCodemode.{ApiConfig, Ingest, Registry, Tools}

  @doc "Ingest a raw spec and register it in one call."
  def ingest_and_register(registry, name, raw_spec, config_opts \\ []) do
    with {:ok, artifact} <- Ingest.ingest(raw_spec) do
      Registry.register(registry, name, artifact, struct!(ApiConfig, config_opts))
    end
  end

  @doc "Emit the search/execute tool definitions. See `OapiCodemode.Tools.definitions/1`."
  defdelegate tools(opts), to: Tools, as: :definitions
end
```

**Step 4: Write README.md** — short: what it is, the two tools, a quickstart (ingest_and_register + tools + wiring a handler into a host loop), executor status (Mock now, Deno next), link to the design doc.

**Step 5: Run full suite: `mix test`. Step 6: Commit** — `"feat: public facade and README"`

---

### Task 17: Deno executor — bootstrap + protocol (echo round-trip)

Resurrects ele's Exile-bridge design (ele-core commit `a2a52478f`) with two deliberate changes: **data-URL import instead of temp files** (kills the stale-temp-file wart) and **concurrent callback dispatch** (kills the synchronous-dispatch wart). Uses a raw Port (binary mode, manual newline framing) — no Exile dependency.

All Deno tests: `@moduletag :deno`, skipped unless deno is installed. Add to `test/test_helper.exs`:

```elixir
ExUnit.start(exclude: (if System.find_executable("deno"), do: [], else: [:deno]))
```

**Files:**
- Create: `priv/deno/bootstrap.ts`
- Create: `lib/oapi_codemode/executor/deno.ex`
- Test: `test/oapi_codemode/executor/deno_test.exs`

**Step 1: Write the failing test (first slice: run code, globals, logs, JSON values)**

```elixir
defmodule OapiCodemode.Executor.DenoTest do
  use ExUnit.Case
  @moduletag :deno
  alias OapiCodemode.Executor.Deno

  test "evaluates code and returns the value" do
    assert {:ok, %{value: 3, logs: []}} =
             Deno.run("async () => 1 + 2", %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end

  test "globals are injected as data" do
    globals = %{"specs" => %{"a" => %{"paths" => %{"/x" => %{}}}}}

    assert {:ok, %{value: ["/x"]}} =
             Deno.run("async () => Object.keys(specs.a.paths)", %{globals: globals, callbacks: %{}},
               timeout: 10_000
             )
  end

  test "console output is captured as logs" do
    assert {:ok, %{value: nil, logs: ["hello", "world"]}} =
             Deno.run(
               "async () => { console.log('hello'); console.log('world'); return null; }",
               %{globals: %{}, callbacks: %{}},
               timeout: 10_000
             )
  end

  test "runtime errors return {:error, first_line}" do
    assert {:error, msg} =
             Deno.run("async () => nope.nope", %{globals: %{}, callbacks: %{}}, timeout: 10_000)

    assert msg =~ "nope"
    refute msg =~ "data:application"
  end

  test "syntax errors are errors, not hangs" do
    assert {:error, _} =
             Deno.run("async () => {{{", %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end
end
```

**Step 2: Run to verify failure** (with deno installed: `mix test test/oapi_codemode/executor/deno_test.exs`).

**Step 3: Implement `priv/deno/bootstrap.ts`**

```typescript
// Line-delimited JSON protocol over stdin/stdout.
// In:  {"type":"start","code":"...","globals":{...}}
//      {"type":"callback_result","id":"...","ok":...} | {"type":"callback_result","id":"...","error":"..."}
// Out: {"type":"callback","id":"...","name":"request","args":[...]}
//      {"type":"done","ok":{"value":...,"logs":[...]}} | {"type":"done","error":"..."}

type Pending = { resolve: (v: unknown) => void; reject: (e: Error) => void };

const pending = new Map<string, Pending>();
const logs: string[] = [];
let nextId = 0;

const encoder = new TextEncoder();
function send(msg: unknown) {
  Deno.stdout.writeSync(encoder.encode(JSON.stringify(msg) + "\n"));
}

function rpc(name: string, args: unknown[]): Promise<unknown> {
  const id = String(nextId++);
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    send({ type: "callback", id, name, args });
  });
}

// Console capture: logs go back to Elixir, never to stdout directly.
console.log = (...args: unknown[]) => {
  logs.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "));
};
console.error = console.log;
console.warn = console.log;

function installGlobals(globals: Record<string, unknown>, apiNames: string[]) {
  for (const [k, v] of Object.entries(globals)) {
    (globalThis as Record<string, unknown>)[k] = v;
  }
  const apis: Record<string, unknown> = {};
  for (const name of apiNames) {
    apis[name] = { request: (opts: unknown) => rpc("request", [name, opts]) };
  }
  (globalThis as Record<string, unknown>)["apis"] = apis;
}

async function runCode(code: string): Promise<unknown> {
  const moduleSource = `export default ${code}`;
  const url = "data:application/typescript;base64," +
    btoa(String.fromCharCode(...new TextEncoder().encode(moduleSource)));
  const mod = await import(url);
  if (typeof mod.default !== "function") {
    throw new Error("code must be an async arrow function");
  }
  return await mod.default();
}

function cleanError(e: unknown): string {
  const msg = e instanceof Error ? e.message : String(e);
  // First line only; no data-URL stack frames or paths reach the agent.
  return msg.split("\n")[0].slice(0, 500);
}

const lines = Deno.stdin.readable
  .pipeThrough(new TextDecoderStream())
  .pipeThrough(new TextLineStream());

import { TextLineStream } from "jsr:@std/streams/text-line-stream";

let started = false;
for await (const line of lines) {
  if (line.trim() === "") continue;
  const msg = JSON.parse(line);

  if (msg.type === "start" && !started) {
    started = true;
    installGlobals(msg.globals ?? {}, msg.apiNames ?? []);
    // Run without awaiting the message loop: callbacks resolve as
    // callback_result lines arrive, so Promise.all works.
    runCode(msg.code)
      .then((value) => {
        send({ type: "done", ok: { value: value === undefined ? null : value, logs } });
        Deno.exit(0);
      })
      .catch((e) => {
        send({ type: "done", error: cleanError(e), logs });
        Deno.exit(0);
      });
  } else if (msg.type === "callback_result") {
    const p = pending.get(msg.id);
    if (p) {
      pending.delete(msg.id);
      if ("error" in msg) p.reject(new Error(msg.error));
      else p.resolve(msg.ok);
    }
  }
}
```

Note: move the `import` to the top of the file (imports hoist, but keep it tidy). If `jsr:@std/streams` fetch-at-runtime is unacceptable (offline prod), vendor a 15-line manual line-splitter instead — decide at implementation time and prefer the vendored splitter for zero network.

**Step 3b: Implement `lib/oapi_codemode/executor/deno.ex`**

```elixir
defmodule OapiCodemode.Executor.Deno do
  @moduledoc """
  Subprocess Deno executor. Resurrects ele's Exile-bridge design
  (ele-core a2a52478f) over a raw Port with three properties the original
  lacked: no temp files (data-URL import), concurrent callback dispatch,
  and guaranteed child reaping (we record the OS pid at spawn and kill
  exactly that pid on timeout — never a pattern).

  Sandboxing: deno runs with --no-prompt and NO permission flags, so the
  child has no network, no file, no env access. Callbacks are its only
  door out.
  """

  @behaviour OapiCodemode.Executor

  @bootstrap Path.join(:code.priv_dir(:oapi_codemode), "deno/bootstrap.ts")

  @impl true
  def run(code, env, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    deno = System.find_executable("deno") || raise "deno not found on PATH"

    port =
      Port.open({:spawn_executable, deno}, [
        :binary,
        :exit_status,
        :hide,
        args: ["run", "--no-prompt", "--quiet", @bootstrap]
      ])

    os_pid = port |> Port.info(:os_pid) |> elem(1)

    start_msg =
      Jason.encode!(%{
        type: "start",
        code: code,
        globals: env.globals,
        apiNames: Map.get(env.globals, "apiNames", [])
      })

    Port.command(port, start_msg <> "\n")

    try do
      loop(port, env.callbacks, "", timeout)
    after
      close_port(port, os_pid)
    end
  end

  defp loop(port, callbacks, buffer, timeout) do
    receive do
      {^port, {:data, data}} ->
        {lines, rest} = split_lines(buffer <> data)

        case handle_lines(lines, port, callbacks) do
          {:done, result} -> result
          :continue -> loop(port, callbacks, rest, timeout)
        end

      {^port, {:exit_status, status}} ->
        {:error, "sandbox process exited with status #{status} before returning"}

      {:callback_reply, id, reply} ->
        Port.command(port, Jason.encode!(reply_msg(id, reply)) <> "\n")
        loop(port, callbacks, buffer, timeout)
    after
      timeout -> {:error, {:timeout, timeout}}
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {lines, [rest]} = Enum.split(parts, -1)
    {Enum.reject(lines, &(&1 == "")), rest}
  end

  defp handle_lines([], _port, _callbacks), do: :continue

  defp handle_lines([line | rest], port, callbacks) do
    case Jason.decode(line) do
      {:ok, %{"type" => "done", "ok" => %{"value" => value, "logs" => logs}}} ->
        {:done, {:ok, %{value: value, logs: logs}}}

      {:ok, %{"type" => "done", "error" => error}} ->
        {:done, {:error, error}}

      {:ok, %{"type" => "callback", "id" => id, "name" => name, "args" => args}} ->
        dispatch_callback(id, name, args, callbacks)
        handle_lines(rest, port, callbacks)

      _other ->
        handle_lines(rest, port, callbacks)
    end
  end

  # Callbacks run in their own tasks so the sandbox can have several in
  # flight (Promise.all). Replies are funneled back through the port loop's
  # mailbox to keep Port.command on the owning process.
  defp dispatch_callback(id, name, args, callbacks) do
    parent = self()

    Task.start(fn ->
      reply =
        try do
          case {name, args} do
            {"request", [api_name, req_opts]} when is_map_key(callbacks, :request) ->
              {:ok, callbacks.request.(api_name, req_opts)}

            _ ->
              {:error, "unknown callback #{name}"}
          end
        rescue
          e -> {:error, Exception.message(e) |> String.split("\n") |> hd()}
        end

      send(parent, {:callback_reply, id, reply})
    end)
  end

  defp reply_msg(id, {:ok, value}), do: %{type: "callback_result", id: id, ok: value}
  defp reply_msg(id, {:error, message}), do: %{type: "callback_result", id: id, error: message}

  defp close_port(port, os_pid) do
    if Port.info(port), do: Port.close(port)
    # Kill exactly the pid we spawned (recorded above) — never a pattern.
    System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
  catch
    _, _ -> :ok
  end
end
```

**Step 4: Run to verify the first-slice tests pass** — `mix test test/oapi_codemode/executor/deno_test.exs`. Iterate on the bootstrap (line-splitter choice, `Deno.exit` timing vs. stdout flush) until green.

**Step 5: Commit** — `"feat: subprocess Deno executor (protocol + bootstrap)"`

---

### Task 18: Deno executor — callbacks, concurrency, timeout

**Files:**
- Modify: `test/oapi_codemode/executor/deno_test.exs` (add cases)
- Modify: `priv/deno/bootstrap.ts`, `lib/oapi_codemode/executor/deno.ex` as needed

**Step 1: Add failing tests**

```elixir
  test "request callback round-trips" do
    callback = fn "petstore", %{"path" => "/pets"} -> %{"status" => 200, "body" => %{"n" => 1}} end

    code = ~s|async () => { const r = await apis.petstore.request({ path: "/pets" }); return r.body.n; }|

    assert {:ok, %{value: 1}} =
             Deno.run(
               code,
               %{globals: %{"apiNames" => ["petstore"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )
  end

  test "concurrent callbacks via Promise.all" do
    test_pid = self()

    callback = fn "a", %{"path" => path} ->
      send(test_pid, {:called, path})
      Process.sleep(300)
      %{"path" => path}
    end

    code = ~s|async () => {
      const [x, y] = await Promise.all([
        apis.a.request({ path: "/one" }),
        apis.a.request({ path: "/two" })
      ]);
      return [x.path, y.path];
    }|

    started = System.monotonic_time(:millisecond)

    assert {:ok, %{value: ["/one", "/two"]}} =
             Deno.run(code, %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )

    elapsed = System.monotonic_time(:millisecond) - started
    # Concurrent, not serial: two 300ms callbacks well under 600ms total.
    assert elapsed < 550
    assert_received {:called, "/one"}
    assert_received {:called, "/two"}
  end

  test "callback errors become JS exceptions the code can catch" do
    callback = fn _, _ -> raise "credential resolution failed" end

    code = ~s|async () => { try { await apis.a.request({ path: "/x" }); return "no"; } catch (e) { return e.message; } }|

    assert {:ok, %{value: msg}} =
             Deno.run(code, %{globals: %{"apiNames" => ["a"]}, callbacks: %{request: callback}},
               timeout: 10_000
             )

    assert msg =~ "credential resolution failed"
  end

  test "timeout kills the subprocess and returns a named limit" do
    assert {:error, {:timeout, 500}} =
             Deno.run("async () => { while (true) {} }", %{globals: %{}, callbacks: %{}},
               timeout: 500
             )
  end

  test "no network access inside the sandbox" do
    code = ~s|async () => { try { await fetch("https://example.com"); return "fetched"; } catch (e) { return "blocked"; } }|

    assert {:ok, %{value: "blocked"}} =
             Deno.run(code, %{globals: %{}, callbacks: %{}}, timeout: 10_000)
  end
```

**Step 2: Run to verify the new cases fail (or pass — the Task 17 implementation already aims at them; verify each genuinely exercises its path).** The timeout test MUST show the deno process is gone afterward — add an assertion:

```elixir
    # the recorded child is dead (kill targeted the exact pid, not a pattern)
    {out, _} = System.cmd("ps", ["-p", Integer.to_string(os_pid)], stderr_to_stdout: true)
    refute out =~ "deno"
```

To assert this, have `Deno.run` include the os_pid in the timeout error: `{:error, {:timeout, ms}}` stays the contract; expose the pid via a test-only opt (`report_pid: self()` sends `{:deno_pid, pid}`) rather than changing the return shape.

**Step 3: Implement until green. Step 4: Full suite `mix test`. Step 5: Commit** — `"feat: deno executor callbacks, concurrency, timeout kill"`

---

### Task 19: End-to-end integration test + wrap-up

**Files:**
- Create: `test/integration/end_to_end_test.exs`
- Modify: `README.md` (executor status)

**Step 1: Write the integration test** — the full stack with the real Deno executor and a stubbed upstream:

```elixir
defmodule OapiCodemode.EndToEndTest do
  use ExUnit.Case
  @moduletag :deno

  alias OapiCodemode.{Registry, Fixtures}

  defmodule Resolver do
    @behaviour OapiCodemode.Credentials
    @impl true
    def resolve("petstore", _scheme, _ctx), do: {:ok, {:bearer, "e2e-token"}}
  end

  test "search finds an operation; execute calls it through the proxy" do
    reg = start_supervised!({Registry, name: nil})
    :ok = OapiCodemode.ingest_and_register(reg, "petstore", Fixtures.clean_3_1())

    opts = [registry: reg, executor: OapiCodemode.Executor.Deno, resolver: Resolver, policy: :read_only]
    [search, execute] = OapiCodemode.tools(opts) |> Enum.sort_by(& &1.name, :desc)

    # 1. Search: find GET operations tagged "pets"
    {:ok, found} =
      search.handler.(
        %{
          "code" => """
          async () => {
            const hits = [];
            for (const [path, methods] of Object.entries(specs.petstore.paths)) {
              if (methods.get?.tags?.includes("pets")) hits.push({ path, summary: methods.get.summary });
            }
            return hits;
          }
          """
        },
        %{}
      )

    assert found =~ "/pets"
    assert found =~ "List all pets"

    # 2. Execute: call the operation; upstream stubbed, auth asserted
    Req.Test.stub(E2EStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer e2e-token"]
      Req.Test.json(conn, %{"pets" => [%{"name" => "Rex"}]})
    end)

    {:ok, result} =
      execute.handler.(
        %{
          "code" => """
          async () => {
            const r = await apis.petstore.request({ method: "GET", path: "/pets", query: { limit: 10 } });
            return r.body.pets.map(p => p.name);
          }
          """
        },
        %{req_options: [plug: {Req.Test, E2EStub}]}
      )

    decoded = Jason.decode!(result)
    assert decoded["result"] == ["Rex"]
    assert [%{"status" => 200}] = decoded["calls"]
  end
end
```

Req.Test note: the stub runs in the Deno callback's Task process — Req.Test stubs are process-scoped by default. Use `Req.Test.set_req_test_from_context/1` alternatives: simplest is `Req.Test.stub(E2EStub, fun)` + passing ownership with `Req.Test.allow(E2EStub, self(), task_pid)` — but the task pid is internal. Pragmatic v1: make this test `async: false` and use global stubbing via `Req.Test.stub/2` in non-async mode (it falls back to a global registry when the caller isn't the owner — verify against the installed req version; if ownership bites, plumb an explicit `req_options` through instead: `plug: fn conn -> ... end` closures carry no ownership).

**Step 2: Run: `mix test` (full suite, with deno on PATH). Expected: all green.**

**Step 3: Update README status; run `mix format`; final review pass.**

**Step 4: Commit** — `"test: end-to-end search + execute through real Deno sandbox"`

---

## Deferred (explicitly out of this plan)

Host glue modules (gentility `CloudLoop.Tool` wrapper, ele `UserMCP.Tool` wrapper) — written in the host repos against `OapiCodemode.tools/1`. Vendored Stripe-scale fixture + performance pass. `execute_mutations` tool variant (it is `policy: :all` + a second `Tools.definitions/1` call — trivial, add when a host wires it). Mix task for build-time ingestion. MCP server transport. Typed-TS describe layer.

## Task summary

| # | Task | Proves |
|---|------|--------|
| 1–2 | Scaffold + fixtures | build runs |
| 3–6 | Parser, Deref, Normalize, Ingest | spec → artifact, pure |
| 7 | Registry | multi-API config resolution |
| 8–11 | Matcher, Validator, Credentials, Query | each proxy stage in isolation |
| 12 | Proxy pipeline | stages composed, telemetry, Req.Test |
| 13 | Executor behaviour + Mock | sandbox contract testable without JS |
| 14–15 | Descriptions + tool handlers | the two LLM tools end to end (mocked sandbox) |
| 16 | Facade + README | public API |
| 17–18 | Deno executor | real sandbox: protocol, concurrency, timeout, no-network |
| 19 | Integration | LLM-shaped JS through the whole stack |
