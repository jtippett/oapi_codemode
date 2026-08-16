defmodule OapiCodemode.Fixtures do
  @fixtures Path.expand("../fixtures/specs", __DIR__)

  def raw(name), do: File.read!(Path.join(@fixtures, name))
  def clean_3_1, do: raw("clean_3_1.json")
  def dirty_3_0, do: raw("dirty_3_0.yaml")
  def x_api, do: raw("x_api.json")
end
