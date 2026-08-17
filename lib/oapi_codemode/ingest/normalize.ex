defmodule OapiCodemode.Ingest.Normalize do
  @moduledoc """
  Extracts a flat operation list from a dereferenced spec, deriving stable
  readable ids where operationId is missing (the oaskit `cards_freeze_ALTIJVI`
  lesson: never trust upstream ids to exist or be usable).
  """

  alias OapiCodemode.Operation

  @methods ~w(get post put patch delete head options)

  @doc """
  The HTTP methods this module extracts operations for.

  Exposed so the proxy can derive its own method table from it (M4): a
  method extracted here but unknown to the proxy would blow up at request
  time rather than at ingest.
  """
  @spec methods() :: [String.t()]
  def methods, do: @methods

  @spec operations(map()) :: [Operation.t()]
  def operations(spec) do
    spec
    |> Map.get("paths", %{})
    |> paths_map()
    |> Enum.sort_by(fn {path, _} -> path end)
    |> Enum.flat_map(fn {path, item} -> path_operations(path, item, spec) end)
    |> dedupe_ids()
  end

  # Specs in the wild are dirty (tenant-uploaded, not authored by us):
  # `paths` itself can be the wrong shape (a string, a list, ...). Ingest
  # must be total, so a malformed `paths` is treated as "no paths" rather
  # than raising — same lenient-ignore policy as `info_map` in Ingest.
  defp paths_map(paths) when is_map(paths), do: paths
  defp paths_map(_), do: %{}

  defp path_operations(path, item, spec) when is_map(item) do
    path_level_params = param_list(Map.get(item, "parameters", []))

    for method <- @methods, op = item[method], is_map(op) do
      %Operation{
        id: op["operationId"] || derive_id(method, path),
        method: method,
        path: path,
        segments: parse_segments(path),
        summary: op["summary"] || op["description"],
        tags: list_or_empty(op["tags"]),
        parameters:
          merge_parameters(path_level_params, param_list(Map.get(op, "parameters", []))),
        request_body: extract_body(op["requestBody"]),
        security: op["security"] || spec["security"]
      }
    end
  end

  defp path_operations(_path, _item, _spec), do: []

  # Lenient-ignore policy (see `paths_map/1` above): a `tags` field that
  # isn't a list is dropped rather than raising — same policy applied
  # consistently across the module: malformed fields are ignored, never
  # fatal. This only guards the field's own shape (list vs. not); for
  # `parameters`, whose elements are read individually further down the
  # pipeline (`param_key/1`), see `param_list/1` below.
  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_), do: []

  # `parameters` needs a stronger guard than `list_or_empty/1`: even when
  # the field is a list, individual elements are dereferenced later
  # (`param_key/1` reads `param["name"]`/`param["in"]`), so a list
  # containing a non-map element (e.g. `["nope"]`) would still raise.
  # Lenient-ignore policy applies per-element too: a malformed parameter
  # entry is dropped, its well-formed siblings are kept.
  defp param_list(list), do: list |> list_or_empty() |> Enum.filter(&is_map/1)

  # OpenAPI 3.x semantics: an operation-level parameter with the same
  # (name, in) pair overrides the path-level parameter rather than
  # duplicating it. Path-level params without an override are kept in their
  # original order, followed by all operation-level params (overrides in
  # their operation-level position, plus any operation-only additions).
  defp merge_parameters(path_level_params, op_params) do
    op_keys = MapSet.new(op_params, &param_key/1)

    kept_path_level =
      Enum.reject(path_level_params, fn param -> MapSet.member?(op_keys, param_key(param)) end)

    kept_path_level ++ op_params
  end

  defp param_key(param), do: {param["name"], param["in"]}

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

  # `content` must be a map (media-type -> media object) per the OpenAPI
  # spec; a malformed non-map `content` is treated as no body at all
  # rather than raising (same lenient-ignore policy as the rest of the
  # module). Each media object under `content` must itself be a map (its
  # `schema` is read below) — a malformed non-map media object is treated
  # as a media object with no schema, rather than raising.
  defp extract_body(%{"content" => content} = body) when is_map(content) do
    fallback = Enum.at(content, 0, {nil, %{}})

    {content_type, media} =
      Enum.find(content, fallback, fn {ct, _} -> ct =~ "json" end)

    schema = if is_map(media), do: media["schema"]

    %{
      "required" => Map.get(body, "required", false),
      "content_type" => content_type,
      "schema" => schema
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
