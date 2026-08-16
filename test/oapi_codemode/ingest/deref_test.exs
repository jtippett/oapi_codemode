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

  test "diamond/shared-schema refs fully inline identically on both branches (memoization correctness)" do
    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/x" => %{
          "get" => %{
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{
                      "type" => "object",
                      "properties" => %{
                        "left" => %{"$ref" => "#/components/schemas/Shared"},
                        "right" => %{"$ref" => "#/components/schemas/Shared"}
                      }
                    }
                  }
                }
              }
            }
          }
        }
      },
      "components" => %{
        "schemas" => %{
          "Shared" => %{
            "type" => "object",
            "properties" => %{
              "leaf" => %{"type" => "string"}
            }
          }
        }
      }
    }

    deref = Deref.dereference(spec)

    schema =
      deref["paths"]["/x"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

    expected = %{"type" => "object", "properties" => %{"leaf" => %{"type" => "string"}}}
    assert schema["properties"]["left"] == expected
    assert schema["properties"]["right"] == expected
  end

  test "deep chain of shared-schema fan-out dereferences quickly (memoization performance guard)" do
    depth = 20

    schemas =
      for level <- 0..depth, into: %{} do
        name = "L#{level}"

        body =
          if level == depth do
            %{"type" => "object", "properties" => %{"leaf" => %{"type" => "string"}}}
          else
            next_ref = %{"$ref" => "#/components/schemas/L#{level + 1}"}

            %{
              "type" => "object",
              "properties" => %{
                "a" => next_ref,
                "b" => next_ref
              }
            }
          end

        {name, body}
      end

    spec = %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/x" => %{
          "get" => %{
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"$ref" => "#/components/schemas/L0"}
                  }
                }
              }
            }
          }
        }
      },
      "components" => %{"schemas" => schemas}
    }

    {elapsed_us, deref} = :timer.tc(fn -> Deref.dereference(spec) end)

    schema =
      deref["paths"]["/x"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

    # two levels in: still a fully inlined object, not a $ref
    assert schema["properties"]["a"]["properties"]["b"]["type"] == "object"

    assert elapsed_us < 500_000
  end
end
