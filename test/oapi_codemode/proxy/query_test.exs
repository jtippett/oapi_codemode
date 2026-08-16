defmodule OapiCodemode.Proxy.QueryTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Proxy.Query

  # Contract change (I3): encode/1 now returns {:ok, binary} | {:error, message}
  # instead of a bare binary, so non-scalar leaves can be reported cleanly
  # instead of raising Protocol.UndefinedError deep inside to_string/1.

  test "scalars serialize plainly" do
    assert Query.encode([{"limit", 5, %{}}]) == {:ok, "limit=5"}
  end

  test "form + explode=true (default) repeats array keys" do
    assert Query.encode([{"tag", ["a", "b"], %{}}]) == {:ok, "tag=a&tag=b"}
  end

  test "form + explode=false comma-joins arrays" do
    param = %{"style" => "form", "explode" => false}
    assert Query.encode([{"tag", ["a", "b"], param}]) == {:ok, "tag=a%2Cb"}
  end

  test "deepObject styles nested maps" do
    param = %{"style" => "deepObject", "explode" => true}

    assert Query.encode([{"filter", %{"status" => "open", "kind" => "x"}, param}]) ==
             {:ok, "filter%5Bkind%5D=x&filter%5Bstatus%5D=open"}
  end

  test "values are URI-encoded" do
    assert Query.encode([{"q", "a b&c", %{}}]) == {:ok, "q=a+b%26c"}
  end

  test "empty list of params is empty string" do
    assert Query.encode([]) == {:ok, ""}
  end

  # C2: Enum.sort/1 on flattened pairs was scrambling intra-name order for
  # exploded arrays because it sorted by the whole {name, value} tuple
  # (value included), not just by name. Enum.sort_by/2 by name alone is a
  # stable sort, so same-name pairs keep the caller's element order.
  test "exploded array element order survives sorting (regression)" do
    assert Query.encode([{"bbox", [10, 5, 20, 15], %{}}]) ==
             {:ok, "bbox=10&bbox=5&bbox=20&bbox=15"}
  end

  # I7: nil-valued params must be dropped, not rendered as "name=".
  test "nil-valued params are dropped" do
    assert Query.encode([{"status", nil, %{}}]) == {:ok, ""}
  end

  test "nil-valued param alongside others is just dropped" do
    assert Query.encode([{"status", nil, %{}}, {"limit", 5, %{}}]) == {:ok, "limit=5"}
  end

  # I3a: form-style (default) explode with an object parameter serializes
  # each property as its own top-level key=value pair, per OpenAPI's
  # form/explode object semantics — not nested under the param name.
  test "form+explode object param serializes as top-level pairs" do
    assert Query.encode([{"filter", %{"a" => 1}, %{}}]) == {:ok, "a=1"}
  end

  test "form+explode=false object param comma-joins key,value pairs" do
    param = %{"style" => "form", "explode" => false}
    assert Query.encode([{"filter", %{"a" => 1}, param}]) == {:ok, "filter=a%2C1"}
  end

  # I3b: a nested map inside a deepObject leaf isn't representable — report
  # a clean error instead of crashing inside to_string/1.
  test "nested map inside deepObject value is a clean error" do
    param = %{"style" => "deepObject", "explode" => true}

    assert {:error, msg} = Query.encode([{"filter", %{"a" => %{"b" => 1}}, param}])
    assert msg =~ "filter"
  end

  # I3c: a nested list inside an array element used to silently corrupt via
  # to_string/1's charlist coercion (to_string([1,2]) => <<1,2>>, control
  # bytes, not "1,2"). Must be a clean error instead.
  test "nested list inside array element is a clean error" do
    assert {:error, msg} = Query.encode([{"ids", [[1, 2], 3], %{}}])
    assert msg =~ "ids"
  end

  test "object param without deepObject style and a nested map value is a clean error" do
    assert {:error, msg} = Query.encode([{"filter", %{"a" => %{"b" => 1}}, %{}}])
    assert msg =~ "filter"
  end

  # M6: spaceDelimited / pipeDelimited styles.
  test "spaceDelimited explode=false joins with an encoded space" do
    param = %{"style" => "spaceDelimited", "explode" => false}
    assert Query.encode([{"list", [10, 20], param}]) == {:ok, "list=10%2020"}
  end

  test "pipeDelimited explode=false joins with a pipe" do
    param = %{"style" => "pipeDelimited", "explode" => false}
    assert Query.encode([{"list", [10, 20], param}]) == {:ok, "list=10%7C20"}
  end

  test "spaceDelimited explode=true behaves as form (repeated keys)" do
    param = %{"style" => "spaceDelimited", "explode" => true}
    assert Query.encode([{"list", [10, 20], param}]) == {:ok, "list=10&list=20"}
  end

  test "pipeDelimited explode=true behaves as form (repeated keys)" do
    param = %{"style" => "pipeDelimited", "explode" => true}
    assert Query.encode([{"list", [10, 20], param}]) == {:ok, "list=10&list=20"}
  end

  # M7: empty arrays are dropped entirely, regardless of explode.
  test "empty array is dropped when explode=true" do
    assert Query.encode([{"tag", [], %{"explode" => true}}]) == {:ok, ""}
  end

  test "empty array is dropped when explode=false" do
    assert Query.encode([{"tag", [], %{"explode" => false}}]) == {:ok, ""}
  end
end
