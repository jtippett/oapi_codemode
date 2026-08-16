defmodule OapiCodemode.Proxy.Matcher do
  @moduledoc """
  Matches an intercepted (method, path) against the operation index.
  On failure, suggests the nearest operations so the model can self-correct
  without another search round-trip.
  """

  alias OapiCodemode.Operation

  @max_suggestions 5

  @spec match([Operation.t()], String.t(), String.t()) ::
          {:ok, Operation.t(), %{String.t() => String.t()}}
          | {:error, {:no_match, [String.t()]}}
  def match(operations, method, path) do
    method = String.downcase(method)
    segments = path |> strip_query() |> String.split("/", trim: true)

    operations
    |> Enum.filter(&(&1.method == method))
    |> Enum.flat_map(fn op ->
      case bind(op.segments, segments, %{}) do
        {:ok, params} -> [{op, params}]
        :error -> []
      end
    end)
    |> Enum.sort_by(fn {op, _params} -> specificity(op) end)
    |> case do
      [{op, params} | _] -> {:ok, op, params}
      [] -> {:error, {:no_match, suggestions(operations, method, segments)}}
    end
  end

  # Ranks candidates so first-match no longer depends on caller list order:
  # fewer {:param, _} segments wins (a literal beats a template of the same
  # shape); tie-break on the position of the first param — later wins,
  # i.e. the route with the longer literal prefix.
  defp specificity(op) do
    param_count = Enum.count(op.segments, &match?({:param, _}, &1))

    first_param_index =
      Enum.find_index(op.segments, &match?({:param, _}, &1)) || length(op.segments)

    {param_count, -first_param_index}
  end

  defp strip_query(path), do: path |> String.split("?", parts: 2) |> hd()

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:param, name} | t1], [seg | t2], params),
    do: bind(t1, t2, Map.put(params, name, seg))

  defp bind([seg | t1], [seg | t2], params), do: bind(t1, t2, params)
  defp bind(_, _, _), do: :error

  defp suggestions(operations, method, segments) do
    given = Enum.join(segments, "/")

    operations
    |> Enum.map(fn op ->
      template =
        Enum.map_join(op.segments, "/", fn
          {:param, name} -> "{#{name}}"
          seg -> seg
        end)

      method_bonus = if op.method == method, do: 0.25, else: 0.0
      {String.jaro_distance(given, template) + method_bonus, op, template}
    end)
    |> Enum.sort_by(fn {score, _, _} -> -score end)
    |> Enum.take(@max_suggestions)
    |> Enum.map(fn {_score, op, template} ->
      "#{String.upcase(op.method)} /#{template}"
    end)
  end
end
