defmodule OapiCodemode.Tools.DescriptionsTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Tools.Descriptions
  alias OapiCodemode.{Registry, Ingest, ApiConfig, Fixtures}

  setup do
    reg = start_supervised!({Registry, name: nil})
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())
    :ok = Registry.register(reg, "petstore", art, %ApiConfig{context: %{"storeId" => "s1"}})
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
