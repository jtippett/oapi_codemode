defmodule OapiCodemode.Ingest.DerefTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Ingest.{Parser, Deref}
  alias OapiCodemode.Fixtures

  test "inlines local refs" do
    {:ok, spec} = Parser.parse(Fixtures.clean_3_1())
    deref = Deref.dereference(spec)

    schema =
      deref["paths"]["/pets"]["post"]["requestBody"]["content"]["application/json"]["schema"]

    assert schema["type"] == "object"
    assert "name" in schema["required"]
    refute Map.has_key?(schema, "$ref")
  end

  test "breaks circular refs with a marker" do
    {:ok, spec} = Parser.parse(Fixtures.dirty_3_0())
    deref = Deref.dereference(spec)

    node =
      deref["paths"]["/nodes"]["post"]["requestBody"]["content"]["application/json"]["schema"]

    assert node["type"] == "object"
    assert node["properties"]["parent"] == %{"$circular" => "Node"}
  end

  test "leaves unresolvable refs marked" do
    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{"/x" => %{"get" => %{"responses" => %{}}}},
      "junk" => %{"$ref" => "#/components/schemas/Missing"},
      "external" => %{"$ref" => "other.yaml#/Foo"}
    }

    deref = Deref.dereference(spec)
    assert deref["junk"] == %{"$unresolved" => "#/components/schemas/Missing"}
    assert deref["external"] == %{"$unresolved" => "other.yaml#/Foo"}
  end
end
