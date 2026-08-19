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

  # I3: the per-call hot paths (search's specs handoff, execute's
  # apiNames/context globals) must not pay an ETS copy of every full
  # artifact on each tool call. sandbox_meta is the projected read: the
  # spec pre-encoded to JSON once at registration (a refc binary, shared
  # not copied) plus the model-visible sandbox_globals.
  describe "sandbox_meta" do
    test "returns spec_json and sandbox_globals per API, sorted by name", %{reg: reg, art: art} do
      :ok = Registry.register(reg, "zebra", art, %ApiConfig{})

      :ok =
        Registry.register(reg, "petstore", art, %ApiConfig{
          sandbox_globals: %{"account_id" => "acc_1"}
        })

      assert [{"petstore", pet}, {"zebra", zebra}] = Registry.sandbox_meta(reg)
      assert pet.sandbox_globals == %{"account_id" => "acc_1"}
      assert zebra.sandbox_globals == %{}
      assert Jason.decode!(pet.spec_json) == art.spec
    end

    test "re-registration refreshes the cached spec_json", %{reg: reg, art: art} do
      :ok = Registry.register(reg, "petstore", art, %ApiConfig{})
      changed = %{art | spec: Map.put(art.spec, "info", %{"title" => "Petstore v2"})}
      :ok = Registry.register(reg, "petstore", changed, %ApiConfig{})

      assert [{"petstore", meta}] = Registry.sandbox_meta(reg)
      assert Jason.decode!(meta.spec_json)["info"]["title"] == "Petstore v2"
    end

    test "empty registry yields an empty meta list", %{reg: reg} do
      assert Registry.sandbox_meta(reg) == []
    end

    test "carries the auto_idempotency_header, downcased", %{reg: reg, art: art} do
      :ok =
        Registry.register(reg, "petstore", art, %ApiConfig{
          auto_idempotency_header: "Idempotency-Key"
        })

      assert [{"petstore", meta}] = Registry.sandbox_meta(reg)
      assert meta.auto_idempotency_header == "idempotency-key"
    end
  end

  # A reserved header (authorization, cookie, content-type, ...) as the
  # idempotency header would collide with credential attach or the body
  # encoder — a host config bug, rejected at registration.
  test "register rejects a reserved auto_idempotency_header", %{reg: reg, art: art} do
    assert {:error, {:invalid_idempotency_header, "Authorization"}} =
             Registry.register(reg, "petstore", art, %ApiConfig{
               auto_idempotency_header: "Authorization"
             })

    assert {:error, {:invalid_idempotency_header, ""}} =
             Registry.register(reg, "petstore", art, %ApiConfig{auto_idempotency_header: ""})
  end
end
