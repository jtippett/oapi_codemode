defmodule OapiCodemode.IngestTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.{Ingest, Artifact, Fixtures}

  test "produces an artifact with sandbox spec, operations, tags, and title" do
    assert {:ok, %Artifact{} = art} = Ingest.ingest(Fixtures.clean_3_1())
    assert art.title == "Petstore"
    assert art.tags == ["pets"]
    assert length(art.operations) == 4
    # sandbox payload is dereferenced and JSON-serializable
    assert {:ok, _} = Jason.encode(art.spec)
    refute inspect(art.spec) =~ "$ref\" =>"
    # default server captured
    assert art.default_base_url == "https://petstore.example.com/v1"
  end

  test "handles specs without servers" do
    assert {:ok, %Artifact{default_base_url: nil}} = Ingest.ingest(Fixtures.dirty_3_0())
  end

  test "propagates parse errors" do
    assert {:error, {:invalid_spec, _}} = Ingest.ingest(~s({"nope": true}))
  end

  test "extracts security schemes" do
    {:ok, art} = Ingest.ingest(Fixtures.dirty_3_0())
    assert art.security_schemes["keyAuth"]["type"] == "apiKey"
  end

  test "tolerates a non-map info field (list) instead of raising" do
    assert {:ok, %Artifact{}} =
             Ingest.ingest(~s({"openapi":"3.1.0","paths":{},"info":[]}))
  end

  test "tolerates a non-map info field (string) instead of raising" do
    assert {:ok, %Artifact{}} =
             Ingest.ingest(~s({"openapi":"3.1.0","paths":{},"info":"oops"}))
  end

  # Reviewer-reported: tenant-uploaded specs with plausible-but-malformed
  # shapes must never raise. Policy is lenient-ignore (see FEEDBACK.md
  # entry for this fix): the garbage field is dropped, ingest still
  # succeeds.
  test "tolerates a path item with non-list parameters instead of raising" do
    raw =
      Jason.encode!(%{
        "openapi" => "3.1.0",
        "paths" => %{
          "/things" => %{
            "parameters" => "nope",
            "get" => %{"responses" => %{}}
          }
        }
      })

    assert {:ok, %Artifact{operations: [op]}} = Ingest.ingest(raw)
    assert op.parameters == []
  end

  test "tolerates an operation with non-list tags instead of raising" do
    raw =
      Jason.encode!(%{
        "openapi" => "3.1.0",
        "paths" => %{
          "/things" => %{
            "get" => %{"responses" => %{}, "tags" => "nope"}
          }
        }
      })

    assert {:ok, %Artifact{operations: [op], tags: tags}} = Ingest.ingest(raw)
    assert op.tags == []
    assert tags == []
  end

  # Reviewer-reported (2nd pass, FEEDBACK.md 2026-08-16): the first fix
  # covered malformed `parameters`/`tags`/`content` shapes in `Normalize`
  # but missed three more live crash sites, all in `Ingest`/`Normalize`.
  # Lenient-ignore policy: the malformed field is dropped, ingest succeeds.
  describe "second-pass crash sites (components/media/parameter-elements)" do
    test "tolerates a non-map components field (string) instead of raising" do
      raw = ~s({"openapi":"3.1.0","paths":{},"components":"nope"})

      assert {:ok, %Artifact{security_schemes: schemes}} = Ingest.ingest(raw)
      assert schemes == %{}
    end

    test "tolerates a non-map components field (list) instead of raising" do
      raw = ~s({"openapi":"3.1.0","paths":{},"components":[]})

      assert {:ok, %Artifact{security_schemes: schemes}} = Ingest.ingest(raw)
      assert schemes == %{}
    end

    test "tolerates a non-map securitySchemes field instead of raising" do
      raw = ~s({"openapi":"3.1.0","paths":{},"components":{"securitySchemes":"nope"}})

      assert {:ok, %Artifact{security_schemes: schemes}} = Ingest.ingest(raw)
      assert schemes == %{}
    end

    test "tolerates a non-map media object under requestBody.content instead of raising" do
      raw =
        Jason.encode!(%{
          "openapi" => "3.1.0",
          "paths" => %{
            "/things" => %{
              "post" => %{
                "responses" => %{},
                "requestBody" => %{"content" => %{"application/json" => "nope"}}
              }
            }
          }
        })

      assert {:ok, %Artifact{operations: [op]}} = Ingest.ingest(raw)
      assert op.request_body["schema"] == nil
      assert op.request_body["content_type"] == "application/json"
    end

    test "tolerates a list of non-map parameter elements instead of raising" do
      raw =
        Jason.encode!(%{
          "openapi" => "3.1.0",
          "paths" => %{
            "/things" => %{
              "get" => %{"responses" => %{}, "parameters" => ["nope"]}
            }
          }
        })

      assert {:ok, %Artifact{operations: [op]}} = Ingest.ingest(raw)
      assert op.parameters == []
    end

    test "drops only the malformed elements of a mixed parameter list" do
      raw =
        Jason.encode!(%{
          "openapi" => "3.1.0",
          "paths" => %{
            "/things" => %{
              "get" => %{
                "responses" => %{},
                "parameters" => ["nope", %{"name" => "id", "in" => "query"}]
              }
            }
          }
        })

      assert {:ok, %Artifact{operations: [op]}} = Ingest.ingest(raw)
      assert [%{"name" => "id", "in" => "query"}] = op.parameters
    end
  end

  describe "rescue backstop" do
    test "downgrades an unguarded raise to {:error, {:malformed_spec, _}} instead of crashing" do
      # `operationId` colliding across two operations, where the shared id
      # is a non-string JSON value (a map): `dedupe_ids/1` interpolates the
      # second occurrence's id into a string (`"#{op.id}_2"`), and `Map`
      # has no `String.Chars` implementation, so this raises
      # `Protocol.UndefinedError`. Not a site covered by any of the
      # targeted lenient-ignore guards above (operationId shape isn't
      # validated anywhere) — exactly the kind of "next unaudited crash
      # site" the backstop exists for.
      raw =
        Jason.encode!(%{
          "openapi" => "3.1.0",
          "paths" => %{
            "/a" => %{"get" => %{"operationId" => %{"weird" => "id"}, "responses" => %{}}},
            "/b" => %{"get" => %{"operationId" => %{"weird" => "id"}, "responses" => %{}}}
          }
        })

      assert {:error, {:malformed_spec, message}} = Ingest.ingest(raw)
      assert is_binary(message)
      assert message =~ "String.Chars"
    end

    test "truncates an oversized exception message rather than embedding the whole spec" do
      huge = String.duplicate("a", 10_000)

      raw =
        Jason.encode!(%{
          "openapi" => "3.1.0",
          "paths" => %{
            "/a" => %{"get" => %{"operationId" => %{"weird" => huge}, "responses" => %{}}},
            "/b" => %{"get" => %{"operationId" => %{"weird" => huge}, "responses" => %{}}}
          }
        })

      assert {:error, {:malformed_spec, message}} = Ingest.ingest(raw)
      assert String.length(message) < 1_000
      assert String.ends_with?(message, "... (truncated)")
    end

    test "does not swallow errors already returned as tuples (parse errors still propagate)" do
      assert {:error, {:invalid_spec, _}} = Ingest.ingest(~s({"nope": true}))
    end
  end
end
