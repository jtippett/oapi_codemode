defmodule OapiCodemode.Ingest.ParserTest do
  use ExUnit.Case, async: true
  alias OapiCodemode.Ingest.Parser
  alias OapiCodemode.Fixtures

  test "parses JSON specs" do
    assert {:ok, %{"openapi" => "3.1.0"}} = Parser.parse(Fixtures.clean_3_1())
  end

  test "parses YAML specs" do
    assert {:ok, %{"openapi" => "3.0.3"}} = Parser.parse(Fixtures.dirty_3_0())
  end

  test "rejects non-spec JSON" do
    assert {:error, {:invalid_spec, _}} = Parser.parse(~s({"hello": "world"}))
  end

  test "rejects OpenAPI 2 (swagger)" do
    assert {:error, {:invalid_spec, msg}} = Parser.parse(~s({"swagger": "2.0", "paths": {}}))
    assert msg =~ "3.x"
  end

  test "rejects unparseable input" do
    assert {:error, {:parse_error, _}} = Parser.parse("{{{{not anything")
  end
end
