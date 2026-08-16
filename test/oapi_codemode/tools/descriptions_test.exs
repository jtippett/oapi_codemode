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
