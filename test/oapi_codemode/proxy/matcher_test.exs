defmodule OapiCodemode.Proxy.MatcherTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Proxy.Matcher
  alias OapiCodemode.{Ingest, Fixtures, Operation}

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

  # I4: first-match used to depend on caller list order, so a literal route
  # only beat a same-shaped template route by ASCII accident. Candidates
  # must be ranked by specificity: fewer {:param, _} segments wins.
  describe "specificity ranking (I4)" do
    defp op(id, method, segments) do
      %Operation{id: id, method: method, path: "/x", segments: segments}
    end

    test "a literal route beats a param route at the same shape, regardless of list order" do
      literal = op("getMe", "get", ["users", "~me"])
      templated = op("getUser", "get", ["users", {:param, "id"}])

      assert {:ok, %{id: "getMe"}, %{}} = Matcher.match([templated, literal], "get", "/users/~me")
      assert {:ok, %{id: "getMe"}, %{}} = Matcher.match([literal, templated], "get", "/users/~me")
    end

    test "the param route still wins for a value that doesn't match any literal" do
      literal = op("getMe", "get", ["users", "~me"])
      templated = op("getUser", "get", ["users", {:param, "id"}])

      assert {:ok, %{id: "getUser"}, %{"id" => "42"}} =
               Matcher.match([templated, literal], "get", "/users/42")
    end

    test "pets/count (literal) beats pets/{petId} (param), regardless of list order" do
      literal = op("countPets", "get", ["pets", "count"])
      templated = op("getPet", "get", ["pets", {:param, "petId"}])

      assert {:ok, %{id: "countPets"}, %{}} =
               Matcher.match([templated, literal], "get", "/pets/count")

      assert {:ok, %{id: "countPets"}, %{}} =
               Matcher.match([literal, templated], "get", "/pets/count")
    end
  end
end
