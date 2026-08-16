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
