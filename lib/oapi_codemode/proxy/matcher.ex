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
    |> Enum.find_value(fn op ->
      case bind(op.segments, segments, %{}) do
        {:ok, params} -> {:ok, op, params}
        :error -> nil
      end
    end)
    |> case do
      {:ok, _, _} = hit -> hit
      nil -> {:error, {:no_match, suggestions(operations, method, segments)}}
    end
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
