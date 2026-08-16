defmodule OapiCodemode.Proxy.MatcherTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Proxy.Matcher
  alias OapiCodemode.{Ingest, Fixtures}

  setup do
    {:ok, art} = Ingest.ingest(Fixtures.clean_3_1())
    %{ops: art.operations}
  end

  test "matches a literal path", %{ops: ops} do
    assert {:ok, op, %{}} = Matcher.match(ops, "get", "/pets")
    assert op.id == "listPets"
  end

  test "binds path params", %{ops: ops} do
    assert {:ok, op, %{"petId" => "42"}} = Matcher.match(ops, "get", "/pets/42")
    assert op.id == "getPet"
  end

  test "method mismatch is no match", %{ops: ops} do
    assert {:error, {:no_match, _}} = Matcher.match(ops, "put", "/pets/42")
  end

  test "ignores a leading base-path prefix mismatch by exact segments only", %{ops: ops} do
    assert {:error, {:no_match, _}} = Matcher.match(ops, "get", "/v1/pets")
  end

  test "no match returns nearest operations, same-method ranked first", %{ops: ops} do
    assert {:error, {:no_match, suggestions}} = Matcher.match(ops, "delete", "/pet/42")
    assert is_list(suggestions) and length(suggestions) <= 5
    assert hd(suggestions) == "DELETE /pets/{petId}"
  end

  test "trailing slashes and query strings are tolerated", %{ops: ops} do
    assert {:ok, %{id: "listPets"}, _} = Matcher.match(ops, "get", "/pets/")
    assert {:ok, %{id: "listPets"}, _} = Matcher.match(ops, "get", "/pets?limit=5")
  end
end
