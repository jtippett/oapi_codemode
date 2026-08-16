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

  test "register/4 registers a pre-ingested artifact without re-parsing" do
    {:ok, registry} = OapiCodemode.Registry.start_link(name: nil)
    {:ok, artifact} = OapiCodemode.ingest(OapiCodemode.Fixtures.petstore_json())

    assert :ok =
             OapiCodemode.register(registry, "petstore", artifact,
               base_url: "https://api.example.com"
             )

    assert {:ok, _entry} = OapiCodemode.Registry.lookup(registry, "petstore")
  end

  test "register/4 rejects unknown config options" do
    {:ok, registry} = OapiCodemode.Registry.start_link(name: nil)
    {:ok, artifact} = OapiCodemode.ingest(OapiCodemode.Fixtures.petstore_json())

    assert {:error, {:invalid_config_option, :base_urll}} =
             OapiCodemode.register(registry, "petstore", artifact, base_urll: "x")
  end

  # A typo'd config key (e.g. `bas_url` instead of `base_url`) used to raise
  # a KeyError out of struct!/2 straight into the caller — a host wiring up
  # config from user input gets a crash instead of a value it can act on.
  test "ingest_and_register returns an error tuple for an unknown config option" do
    reg = start_supervised!({OapiCodemode.Registry, name: nil})

    assert {:error, {:invalid_config_option, :bas_url}} =
             OapiCodemode.ingest_and_register(reg, "petstore", OapiCodemode.Fixtures.clean_3_1(),
               bas_url: "https://petstore.example.com/v1"
             )

    assert {:error, :unknown_api} = OapiCodemode.Registry.lookup(reg, "petstore")
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
    def resolve(_, _, _, _), do: {:ok, :none}
  end
end
