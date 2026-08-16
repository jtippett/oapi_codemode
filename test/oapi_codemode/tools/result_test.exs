defmodule OapiCodemode.Tools.ResultTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Tools.Result

  test "a small result encodes to plain JSON" do
    assert {:ok, json} = Result.encode(%{"a" => 1}, 100)
    assert json == ~s({"a":1})
  end

  # T-C1: the budget is a BYTE budget. String.length/String.slice counted
  # graphemes, so a CJK result blew ~3x past the cap it claimed to enforce.
  test "a CJK result respects the byte budget" do
    value = String.duplicate("漢字", 5_000)
    assert {:ok, out} = Result.encode(value, 10)

    [prefix, _trailer] = String.split(out, "\n--- TRUNCATED ---\n", parts: 2)
    # 10 tokens * 4 bytes
    assert byte_size(prefix) <= 40
    assert String.valid?(prefix)
  end

  test "a byte cut landing mid-codepoint trims back to a valid boundary" do
    # JSON is `"漢漢..."`: one leading quote byte then 3 bytes per char, so a
    # 44-byte cut lands inside the 15th character and must trim back to 43.
    assert {:ok, out} = Result.encode(String.duplicate("漢", 100), 11)
    [prefix, _] = String.split(out, "\n--- TRUNCATED ---\n", parts: 2)
    assert String.valid?(prefix)
    assert byte_size(prefix) == 43
  end

  test "the trailer says the output above is no longer valid JSON" do
    assert {:ok, out} = Result.encode(List.duplicate("x", 5_000), 10)
    assert out =~ "output above is truncated and not valid JSON"
    assert out =~ "limit: 10"
    assert out =~ "Use more specific queries"
  end

  # T-I4: Jason.encode! raised on anything non-encodable (a tuple a callback
  # leaked, a pid, invalid UTF-8 bytes), taking the whole tool handler down.
  test "a non-JSON-encodable value returns an error instead of raising" do
    assert {:error, "result not JSON-encodable"} = Result.encode({:not, "json"}, 100)
  end

  test "invalid UTF-8 bytes return an error instead of raising" do
    assert {:error, "result not JSON-encodable"} = Result.encode(%{"b" => <<0xFF, 0xFE>>}, 100)
  end

  test "explicit key order survives encoding" do
    ordered = %Jason.OrderedObject{values: [{"calls", []}, {"logs", []}, {"result", 1}]}
    assert {:ok, json} = Result.encode(ordered, 100)
    assert json == ~s({"calls":[],"logs":[],"result":1})
  end
end
