defmodule OapiCodemode.Ingest.Deref do
  @moduledoc """
  Resolves all same-document $refs inline so sandbox code never chases references.

  Circular refs become `%{"$circular" => name}`; external or dangling refs
  become `%{"$unresolved" => ref}`. Sandbox code can detect both markers.
  """

  @spec dereference(map()) :: map()
  def dereference(spec) when is_map(spec), do: walk(spec, spec, MapSet.new())

  defp walk(%{"$ref" => ref}, root, stack) when is_binary(ref) do
    cond do
      MapSet.member?(stack, ref) ->
        %{"$circular" => ref_name(ref)}

      not String.starts_with?(ref, "#/") ->
        %{"$unresolved" => ref}

      true ->
        case resolve_pointer(root, ref) do
          {:ok, target} -> walk(target, root, MapSet.put(stack, ref))
          :error -> %{"$unresolved" => ref}
        end
    end
  end

  defp walk(map, root, stack) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, walk(v, root, stack)} end)

  defp walk(list, root, stack) when is_list(list),
    do: Enum.map(list, &walk(&1, root, stack))

  defp walk(other, _root, _stack), do: other

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
