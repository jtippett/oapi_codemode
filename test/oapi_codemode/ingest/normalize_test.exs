defmodule OapiCodemode.Ingest.NormalizeTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Ingest.{Parser, Deref, Normalize}
  alias OapiCodemode.Fixtures

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

  test "operation-level parameter overrides a path-level parameter with the same name+in" do
    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/things/{id}" => %{
          "parameters" => [
            %{"name" => "id", "in" => "path", "schema" => %{"type" => "string"}}
          ],
          "get" => %{
            "parameters" => [
              %{"name" => "id", "in" => "path", "schema" => %{"type" => "integer"}}
            ],
            "responses" => %{}
          }
        }
      }
    }

    ops = Normalize.operations(spec)
    [op] = ops
    id_params = Enum.filter(op.parameters, &(&1["name"] == "id" and &1["in"] == "path"))

    assert length(id_params) == 1
    assert hd(id_params)["schema"]["type"] == "integer"
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

  # Specs in the wild are dirty (tenant-uploaded, not authored by us): a
  # field with the wrong JSON shape must never crash ingest. Policy is
  # lenient-ignore, same as the existing `info_map` handling in Ingest —
  # a malformed value is treated as absent, not as an error.
  describe "malformed spec shapes are ignored, not raised" do
    test "path-level parameters that isn't a list is ignored" do
      spec = %{
        "openapi" => "3.1.0",
        "paths" => %{
          "/things" => %{
            "parameters" => "nope",
            "get" => %{"responses" => %{}}
          }
        }
      }

      assert [op] = Normalize.operations(spec)
      assert op.parameters == []
    end

    test "operation-level parameters that isn't a list is ignored" do
      spec = %{
        "openapi" => "3.1.0",
        "paths" => %{
          "/things" => %{
            "get" => %{"responses" => %{}, "parameters" => "nope"}
          }
        }
      }

      assert [op] = Normalize.operations(spec)
      assert op.parameters == []
    end

    test "operation tags that isn't a list is ignored" do
      spec = %{
        "openapi" => "3.1.0",
        "paths" => %{
          "/things" => %{
            "get" => %{"responses" => %{}, "tags" => "nope"}
          }
        }
      }

      assert [op] = Normalize.operations(spec)
      assert op.tags == []
    end

    test "requestBody.content that isn't a map is ignored (no body)" do
      spec = %{
        "openapi" => "3.1.0",
        "paths" => %{
          "/things" => %{
            "get" => %{"responses" => %{}, "requestBody" => %{"content" => "nope"}}
          }
        }
      }

      assert [op] = Normalize.operations(spec)
      assert op.request_body == nil
    end

    test "top-level paths that isn't a map is ignored (no operations)" do
      assert Normalize.operations(%{"openapi" => "3.1.0", "paths" => "nope"}) == []
    end

    test "top-level paths that is a list is ignored (no operations)" do
      assert Normalize.operations(%{"openapi" => "3.1.0", "paths" => ["nope"]}) == []
    end
  end
end
