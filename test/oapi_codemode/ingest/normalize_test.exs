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
