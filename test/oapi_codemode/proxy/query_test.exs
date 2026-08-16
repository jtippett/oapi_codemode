defmodule OapiCodemode.Proxy.QueryTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Proxy.Query

  test "scalars serialize plainly" do
    assert Query.encode([{"limit", 5, %{}}]) == "limit=5"
  end

  test "form + explode=true (default) repeats array keys" do
    assert Query.encode([{"tag", ["a", "b"], %{}}]) == "tag=a&tag=b"
  end

  test "form + explode=false comma-joins arrays" do
    param = %{"style" => "form", "explode" => false}
    assert Query.encode([{"tag", ["a", "b"], param}]) == "tag=a%2Cb"
  end

  test "deepObject styles nested maps" do
    param = %{"style" => "deepObject", "explode" => true}

    assert Query.encode([{"filter", %{"status" => "open", "kind" => "x"}, param}]) ==
             "filter%5Bkind%5D=x&filter%5Bstatus%5D=open"
  end

  test "values are URI-encoded" do
    assert Query.encode([{"q", "a b&c", %{}}]) == "q=a+b%26c"
  end

  test "empty list of params is empty string" do
    assert Query.encode([]) == ""
  end
end
