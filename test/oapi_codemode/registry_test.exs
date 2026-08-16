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

  # T-I3: the API name becomes a JS identifier in the sandbox
  # (`apis.<name>.request`, `specs.<name>`, `context.<name>`). A name that
  # isn't a valid identifier produces syntax the LLM cannot address at all,
  # so reject it at registration rather than shipping a broken global.
  describe "api name validation" do
    test "a JS-identifier name is accepted", %{reg: reg, art: art} do
      assert :ok = Registry.register(reg, "petstore", art, %ApiConfig{})
      assert :ok = Registry.register(reg, "_private", art, %ApiConfig{})
      assert :ok = Registry.register(reg, "x_api_v2", art, %ApiConfig{})
    end

    test "a hyphenated name is rejected", %{reg: reg, art: art} do
      assert {:error, {:invalid_api_name, "my-api"}} =
               Registry.register(reg, "my-api", art, %ApiConfig{})

      assert {:error, :unknown_api} = Registry.lookup(reg, "my-api")
    end

    test "a name starting with a digit is rejected", %{reg: reg, art: art} do
      assert {:error, {:invalid_api_name, "2fast"}} =
               Registry.register(reg, "2fast", art, %ApiConfig{})
    end

    test "a name containing a space is rejected", %{reg: reg, art: art} do
      assert {:error, {:invalid_api_name, "my api"}} =
               Registry.register(reg, "my api", art, %ApiConfig{})
    end

    test "an empty or non-binary name is rejected", %{reg: reg, art: art} do
      assert {:error, {:invalid_api_name, ""}} = Registry.register(reg, "", art, %ApiConfig{})

      assert {:error, {:invalid_api_name, :petstore}} =
               Registry.register(reg, :petstore, art, %ApiConfig{})
    end
  end

  test "re-registration replaces", %{reg: reg, art: art} do
    :ok = Registry.register(reg, "petstore", art, %ApiConfig{})
    :ok = Registry.register(reg, "petstore", art, %ApiConfig{base_url: "https://two.example.com"})
    {:ok, entry} = Registry.lookup(reg, "petstore")
    assert entry.config.base_url == "https://two.example.com"
  end
end
