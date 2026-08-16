defmodule OapiCodemode.Ingest.Deref do
  @moduledoc """
  Resolves all same-document $refs inline so sandbox code never chases references.

  Circular refs become `%{"$circular" => name}`; external or dangling refs
  become `%{"$unresolved" => ref}`. Sandbox code can detect both markers.

  A ref's expansion is memoized by pointer, but only cached when it completed
  without producing a `$circular` marker anywhere inside it — a cycle-hitting
  expansion is stack-dependent (its shape depends on which refs are currently
  being expanded above it) and must be recomputed for every call site.
  """

  @spec dereference(map()) :: map()
  def dereference(spec) when is_map(spec) do
    {result, _cache, _circular?} = walk(spec, spec, MapSet.new(), %{})
    result
  end

  defp walk(%{"$ref" => ref}, root, stack, cache) when is_binary(ref) do
    cond do
      MapSet.member?(stack, ref) ->
        {%{"$circular" => ref_name(ref)}, cache, true}

      not String.starts_with?(ref, "#/") ->
        {%{"$unresolved" => ref}, cache, false}

      Map.has_key?(cache, ref) ->
        # Only ever populated with clean (non-circular) expansions, so it's
        # safe to reuse verbatim without re-walking the subtree.
        {Map.fetch!(cache, ref), cache, false}

      true ->
        case resolve_pointer(root, ref) do
          {:ok, target} ->
            {result, cache, circular?} = walk(target, root, MapSet.put(stack, ref), cache)
            cache = if circular?, do: cache, else: Map.put(cache, ref, result)
            {result, cache, circular?}

          :error ->
            {%{"$unresolved" => ref}, cache, false}
        end
    end
  end

  defp walk(map, root, stack, cache) when is_map(map) do
    {pairs, cache, circular?} =
      Enum.reduce(map, {[], cache, false}, fn {k, v}, {acc, cache, circular?} ->
        {result, cache, circular_here?} = walk(v, root, stack, cache)
        {[{k, result} | acc], cache, circular? or circular_here?}
      end)

    {Map.new(pairs), cache, circular?}
  end

  defp walk(list, root, stack, cache) when is_list(list) do
    {items, cache, circular?} =
      Enum.reduce(list, {[], cache, false}, fn item, {acc, cache, circular?} ->
        {result, cache, circular_here?} = walk(item, root, stack, cache)
        {[result | acc], cache, circular? or circular_here?}
      end)

    {Enum.reverse(items), cache, circular?}
  end

  defp walk(other, _root, _stack, cache), do: {other, cache, false}

  defp resolve_pointer(root, "#/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce_while({:ok, root}, fn key, {:ok, acc} ->
      case acc do
        %{^key => value} -> {:cont, {:ok, value}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp ref_name(ref), do: ref |> String.split("/") |> List.last()
end
