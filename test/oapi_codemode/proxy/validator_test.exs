defmodule OapiCodemode.Proxy.ValidatorTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Proxy.Validator
  alias OapiCodemode.{Ingest, Fixtures, Operation}

  setup do
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())
    ops = Map.new(art.operations, &{&1.id, &1})
    %{ops: ops}
  end

  test "passes a valid request", %{ops: ops} do
    assert :ok =
             Validator.validate(ops["createPet"], %{
               query: %{},
               body: %{"name" => "Rex", "species" => "dog"}
             })
  end

  test "missing required query param", %{ops: ops} do
    assert {:error, msg} = Validator.validate(ops["listPets"], %{query: %{}, body: nil})
    assert msg =~ "limit"
    assert msg =~ "required"
  end

  test "query param type mismatch", %{ops: ops} do
    assert {:error, msg} =
             Validator.validate(ops["listPets"], %{query: %{"limit" => "lots"}, body: nil})

    assert msg =~ "limit"
    assert msg =~ "integer"
  end

  test "enum violation quotes allowed values", %{ops: ops} do
    assert {:error, msg} =
             Validator.validate(ops["listPets"], %{
               query: %{"limit" => 5, "status" => "eaten"},
               body: nil
             })

    assert msg =~ "available"
    assert msg =~ "adopted"
  end

  test "missing required body", %{ops: ops} do
    assert {:error, msg} = Validator.validate(ops["createPet"], %{query: %{}, body: nil})
    assert msg =~ "request body"
  end

  test "missing required body field quotes the schema fragment", %{ops: ops} do
    assert {:error, msg} =
             Validator.validate(ops["createPet"], %{query: %{}, body: %{"name" => "Rex"}})

    assert msg =~ "species"
  end

  test "nested required fields are checked", %{ops: ops} do
    assert {:error, msg} =
             Validator.validate(ops["createPet"], %{
               query: %{},
               body: %{"name" => "Rex", "species" => "dog", "owner" => %{}}
             })

    assert msg =~ "email"
  end

  test "unknown enum inside body", %{ops: ops} do
    assert {:error, msg} =
             Validator.validate(ops["createPet"], %{
               query: %{},
               body: %{"name" => "Rex", "species" => "dragon"}
             })

    assert msg =~ "dog"
  end

  # I1: enum ran before type coercion, so a strict `in` check failed a
  # string value the type check would otherwise accept leniently.
  describe "enum check happens after type coercion (I1)" do
    defp op_with_query_param(schema) do
      %Operation{
        id: "op",
        method: "get",
        path: "/x",
        segments: ["x"],
        parameters: [
          %{"name" => "priority", "in" => "query", "required" => false, "schema" => schema}
        ]
      }
    end

    test "numeric string passes an integer enum" do
      op = op_with_query_param(%{"type" => "integer", "enum" => [10, 20, 50]})
      assert :ok = Validator.validate(op, %{query: %{"priority" => "10"}, body: nil})
    end

    test "boolean string passes a boolean enum" do
      op = op_with_query_param(%{"type" => "boolean", "enum" => [true, false]})
      assert :ok = Validator.validate(op, %{query: %{"priority" => "true"}, body: nil})
    end

    test "a string value not in a string enum still fails" do
      op = op_with_query_param(%{"type" => "string", "enum" => ["low", "high"]})
      assert {:error, msg} = Validator.validate(op, %{query: %{"priority" => "eaten"}, body: nil})
      assert msg =~ "eaten"
    end
  end

  # I2: a declared-required body with a nil schema used to crash frag/1
  # (BadMapError on Map.take(nil, ...)) instead of returning a clean error.
  test "required body with a nil schema fails cleanly instead of crashing" do
    op = %Operation{
      id: "op",
      method: "post",
      path: "/x",
      segments: ["x"],
      request_body: %{"required" => true, "schema" => nil}
    }

    assert {:error, msg} = Validator.validate(op, %{query: %{}, body: nil})
    assert msg =~ "request body"
  end

  # I5: path parameters (types/enums), bound from the matcher, are now
  # validated. Header/cookie params remain intentionally unvalidated (v1
  # scope — see moduledoc).
  describe "path parameters are validated (I5)" do
    defp op_with_path_param(schema, extra \\ %{}) do
      %Operation{
        id: "op",
        method: "get",
        path: "/pets/{petId}",
        segments: ["pets", {:param, "petId"}],
        parameters: [
          Map.merge(
            %{"name" => "petId", "in" => "path", "required" => true, "schema" => schema},
            extra
          )
        ]
      }
    end

    test "path param type mismatch is an error" do
      op = op_with_path_param(%{"type" => "integer"})

      assert {:error, msg} =
               Validator.validate(op, %{query: %{}, body: nil, path_params: %{"petId" => "abc"}})

      assert msg =~ "petId"
      assert msg =~ "integer"
    end

    test "path param enum violation is an error" do
      op = op_with_path_param(%{"type" => "string", "enum" => ["a", "b"]})

      assert {:error, msg} =
               Validator.validate(op, %{query: %{}, body: nil, path_params: %{"petId" => "z"}})

      assert msg =~ "petId"
    end

    test "a valid path param passes" do
      op = op_with_path_param(%{"type" => "integer"})

      assert :ok =
               Validator.validate(op, %{query: %{}, body: nil, path_params: %{"petId" => "42"}})
    end

    test "path_params defaults to %{} when omitted" do
      op = op_with_path_param(%{"type" => "integer"})
      assert :ok = Validator.validate(op, %{query: %{}, body: nil})
    end
  end

  # M1: array elements are recursively checked against schema["items"],
  # with the offending index named in the error path.
  test "invalid array element names its index" do
    op = %Operation{
      id: "op",
      method: "post",
      path: "/x",
      segments: ["x"],
      request_body: %{
        "required" => true,
        "schema" => %{
          "type" => "object",
          "required" => ["tags"],
          "properties" => %{
            "tags" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "required" => ["name"],
                "properties" => %{"name" => %{"type" => "string"}}
              }
            }
          }
        }
      }
    }

    assert {:error, msg} =
             Validator.validate(op, %{
               query: %{},
               body: %{"tags" => [%{"name" => "ok"}, %{}]}
             })

    assert msg =~ "tags[1]"
    assert msg =~ "name"
  end
end
