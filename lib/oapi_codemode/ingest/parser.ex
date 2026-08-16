defmodule OapiCodemode.Ingest.Parser do
  @moduledoc "Parses raw YAML/JSON into a map and checks it is an OpenAPI 3.x document."

  @spec parse(String.t()) :: {:ok, map()} | {:error, term()}
  def parse(raw) when is_binary(raw) do
    with {:ok, doc} <- decode(raw) do
      validate(doc)
    end
  end

  defp decode(raw) do
    trimmed = String.trim_leading(raw)

    if String.starts_with?(trimmed, ["{", "["]) do
      case Jason.decode(raw) do
        {:ok, doc} -> {:ok, doc}
        {:error, err} -> {:error, {:parse_error, Exception.message(err)}}
      end
    else
      case YamlElixir.read_from_string(raw) do
        {:ok, doc} -> {:ok, stringify_keys(doc)}
        {:error, err} -> {:error, {:parse_error, inspect(err)}}
      end
    end
  end

  # YAML permits unquoted scalar map keys (e.g. `200:`), which the YAML
  # library decodes as non-string terms (integers, atoms, booleans). Force
  # every map key to a string so downstream code can treat JSON- and
  # YAML-sourced specs identically.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp validate(%{"openapi" => "3" <> _, "paths" => paths} = doc) when is_map(paths),
    do: {:ok, doc}

  defp validate(%{"swagger" => _}),
    do: {:error, {:invalid_spec, "OpenAPI 2 (swagger) is not supported; convert to 3.x"}}

  defp validate(doc) when is_map(doc),
    do: {:error, {:invalid_spec, "missing openapi 3.x version or paths"}}

  defp validate(_),
    do: {:error, {:invalid_spec, "document is not a map"}}
end
