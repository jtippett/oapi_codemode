defmodule OapiCodemode.Tools.DescriptionsTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Tools.Descriptions
  alias OapiCodemode.{Registry, Ingest, ApiConfig, Fixtures}

  setup do
    reg = start_supervised!({Registry, name: nil})
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())

    :ok =
      Registry.register(reg, "petstore", art, %ApiConfig{
        sandbox_globals: %{"storeId" => "s1"}
      })

    %{reg: reg, art: art}
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

  test "execute description documents request options, response shape, and context globals", %{
    reg: reg
  } do
    desc = Descriptions.execute(Registry.list(reg))
    assert desc =~ "apis.petstore.request"
    assert desc =~ "contentType"
    assert desc =~ "rawBody"
    assert desc =~ "storeId"
    assert desc =~ "status"
  end

  # The description IS the documentation: a host that allowlists
  # passthrough headers needs the model told the option exists and exactly
  # which names are allowed; a host that doesn't must not have a `headers`
  # option advertised that the proxy would reject on every call.
  test "execute description declares headers only when passthrough is configured", %{
    reg: reg,
    art: art
  } do
    without = Descriptions.execute(Registry.list(reg))
    refute without =~ "headers?:"
    refute without =~ "Per-call headers"

    :ok =
      Registry.register(reg, "billing", art, %ApiConfig{
        passthrough_headers: ["Idempotency-Key"]
      })

    with_headers = Descriptions.execute(Registry.list(reg))
    assert with_headers =~ "headers?: Record<string, string>"

    assert with_headers =~
             "Per-call headers: only these header names are allowed — idempotency-key"
  end

  # Auto idempotency: when configured, the model must be taught that
  # mutations are keyed automatically, that the key is in the call log, and
  # that idempotencyKey is how to reuse a logged key on retry. When no API
  # configures it, none of that text (or the option) may appear.
  test "execute description teaches auto idempotency only when configured", %{
    reg: reg,
    art: art
  } do
    without = Descriptions.execute(Registry.list(reg))
    refute without =~ "idempotencyKey"

    :ok =
      Registry.register(reg, "billing", art, %ApiConfig{
        auto_idempotency_header: "idempotency-key"
      })

    with_idem = Descriptions.execute(Registry.list(reg))
    assert with_idem =~ "idempotencyKey?: string"
    assert with_idem =~ "automatically"
    assert with_idem =~ "call log"
  end

  # I2: with per-instance tool naming (e.g. stripe_api_search/execute
  # trios), the description must name the ACTUAL paired search tool, not a
  # generic "the search tool" — otherwise the model can pair the wrong
  # search with the wrong execute.
  test "execute description defaults to naming the search_apis tool", %{reg: reg} do
    desc = Descriptions.execute(Registry.list(reg))
    assert desc =~ "`search_apis` tool"
  end

  test "execute description interpolates a custom search tool name", %{reg: reg} do
    desc = Descriptions.execute(Registry.list(reg), :read_only, "stripe_api_search")
    assert desc =~ "`stripe_api_search` tool"
    refute desc =~ "`search_apis`"
  end

  # I2: include_search: false means no search tool is emitted from this
  # call. If the host also gave no :search_tool_name, none exists to name —
  # the description must not reference a nonexistent tool.
  test "execute description omits any search-tool reference when search_tool_name is nil", %{
    reg: reg
  } do
    desc = Descriptions.execute(Registry.list(reg), :read_only, nil)
    refute desc =~ "search"
    assert desc =~ "apis.<name>.request()"
  end

  # T-I2: the sandbox really receives `context` and `apiNames` globals, but
  # the description only named them in prose. Declare them like `apis`, and
  # show the real path the LLM must type — not a placeholder.
  test "execute description declares the context and apiNames globals", %{reg: reg} do
    desc = Descriptions.execute(Registry.list(reg))

    assert desc =~ "declare const context: Record<string, Record<string, unknown>>;"
    assert desc =~ "declare const apiNames: string[];"
    assert desc =~ "context.petstore.storeId"
  end

  test "execute description omits the context global when no API declares one", %{art: art} do
    reg = start_supervised!({Registry, name: nil}, id: :no_ctx_reg)
    :ok = Registry.register(reg, "plain", art, %ApiConfig{})

    desc = Descriptions.execute(Registry.list(reg))
    refute desc =~ "declare const context"
    assert desc =~ "declare const apiNames: string[];"
  end

  test "execute description defaults to no mutation-allowed paragraph", %{reg: reg} do
    desc = Descriptions.execute(Registry.list(reg))
    refute desc =~ ~r/mutating requests are allowed/i
  end

  # I2: when a host registers a mutating variant of the execute tool
  # (`policy: :all`), the model must be told explicitly — the read-only
  # default description must not silently start allowing writes.
  test "execute description under policy :all states mutating requests are allowed", %{reg: reg} do
    desc = Descriptions.execute(Registry.list(reg), :all)
    assert desc =~ ~r/mutating requests are allowed/i
  end

  test "tag vocabularies are truncated past the limit", %{} do
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
