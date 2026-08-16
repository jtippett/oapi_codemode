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
end
