defmodule OapiCodemode.Proxy.ValidatorTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Proxy.Validator
  alias OapiCodemode.{Ingest, Fixtures}

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
end
