defmodule OapiCodemode.Proxy.Query do
  @moduledoc """
  Serializes query parameters honoring the spec's style/explode declarations
  (the ele lesson: default serializers silently mismatch backend expectations).
  Supported: form (explode true/false), deepObject. Anything else falls back
  to form+explode.
  """

  @spec encode([{String.t(), term(), map()}]) :: String.t()
  def encode(params) do
    params
    |> Enum.flat_map(&pairs/1)
    |> Enum.sort()
    |> URI.encode_query()
  end

  defp pairs({name, value, param_spec}) when is_list(value) do
    if param_spec["explode"] == false do
      [{name, Enum.map_join(value, ",", &to_string/1)}]
    else
      Enum.map(value, &{name, to_string(&1)})
    end
  end

  defp pairs({name, value, %{"style" => "deepObject"}}) when is_map(value) do
    Enum.map(value, fn {k, v} -> {"#{name}[#{k}]", to_string(v)} end)
  end

  defp pairs({name, value, _param_spec}), do: [{name, to_string(value)}]
end
