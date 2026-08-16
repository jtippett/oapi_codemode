defmodule OapiCodemode.Ingest.Normalize do
  @moduledoc """
  Extracts a flat operation list from a dereferenced spec, deriving stable
  readable ids where operationId is missing (the oaskit `cards_freeze_ALTIJVI`
  lesson: never trust upstream ids to exist or be usable).
  """

  alias OapiCodemode.Operation

  @methods ~w(get post put patch delete head options)

  @spec operations(map()) :: [Operation.t()]
  def operations(spec) do
    spec
    |> Map.get("paths", %{})
    |> Enum.sort_by(fn {path, _} -> path end)
    |> Enum.flat_map(fn {path, item} -> path_operations(path, item, spec) end)
    |> dedupe_ids()
  end

  defp path_operations(path, item, spec) when is_map(item) do
    path_level_params = Map.get(item, "parameters", [])

    for method <- @methods, op = item[method], is_map(op) do
      %Operation{
        id: op["operationId"] || derive_id(method, path),
        method: method,
        path: path,
        segments: parse_segments(path),
        summary: op["summary"] || op["description"],
        tags: op["tags"] || [],
        parameters: path_level_params ++ Map.get(op, "parameters", []),
        request_body: extract_body(op["requestBody"]),
        security: op["security"] || spec["security"]
      }
    end
  end

  defp path_operations(_path, _item, _spec), do: []

  defp derive_id(method, path) do
    suffix =
      path
      |> parse_segments()
      |> Enum.map_join("_", fn
        {:param, name} -> "by_" <> Macro.underscore(name)
        seg -> seg |> String.replace(~r/[^a-zA-Z0-9]+/, "_") |> String.trim("_")
      end)

    "#{method}_#{suffix}"
  end

  defp parse_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      "{" <> rest -> {:param, String.trim_trailing(rest, "}")}
      seg -> seg
    end)
  end

  defp extract_body(nil), do: nil

  defp extract_body(%{"content" => content} = body) do
    fallback = Enum.at(content, 0, {nil, %{}})

    {content_type, media} =
      Enum.find(content, fallback, fn {ct, _} -> ct =~ "json" end)

    %{
      "required" => Map.get(body, "required", false),
      "content_type" => content_type,
      "schema" => media["schema"]
    }
  end

  defp extract_body(_), do: nil

  defp dedupe_ids(ops) do
    {ops, _seen} =
      Enum.map_reduce(ops, %{}, fn op, seen ->
        count = Map.get(seen, op.id, 0)
        id = if count == 0, do: op.id, else: "#{op.id}_#{count + 1}"
        {%{op | id: id}, Map.put(seen, op.id, count + 1)}
      end)

    ops
  end
end
