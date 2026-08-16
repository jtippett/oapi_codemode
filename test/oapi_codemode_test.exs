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
