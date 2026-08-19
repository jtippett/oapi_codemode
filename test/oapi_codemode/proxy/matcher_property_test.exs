defmodule OapiCodemode.Proxy.MatcherPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import StreamData

  alias OapiCodemode.Proxy.Matcher
  alias OapiCodemode.Operation

  @methods ~w(get post put patch delete head options)

  property "matching requires exact segment counts and preserves literal positions" do
    check all(
            method <- method_generator(),
            {segments, concrete_segments} <- matching_segments_generator(),
            extra_segment <- literal_segment_generator()
          ) do
      candidate = op("candidate", method, segments)
      request_method = String.upcase(method)

      assert {:ok, ^candidate, _params} =
               Matcher.match([candidate], request_method, render_path(concrete_segments))

      longer_path = render_path(concrete_segments ++ [extra_segment])

      assert {:error, {:no_match, _suggestions}} =
               Matcher.match([candidate], request_method, longer_path)
    end
  end

  property "a fully static route beats a same-shaped template in either input order" do
    check all(
            method <- method_generator(),
            concrete_segments <-
              list_of(literal_segment_generator(), min_length: 1, max_length: 7),
            param_index <- integer(0..(length(concrete_segments) - 1))
          ) do
      static = op("static", method, concrete_segments)

      templated_segments =
        List.replace_at(concrete_segments, param_index, {:param, "value"})

      templated = op("templated", method, templated_segments)
      path = render_path(concrete_segments)

      assert {:ok, %{id: "static"}, %{}} = Matcher.match([templated, static], method, path)
      assert {:ok, %{id: "static"}, %{}} = Matcher.match([static, templated], method, path)
    end
  end

  property "among matching templates, fewer parameter segments wins" do
    check all(
            method <- method_generator(),
            concrete_segments <-
              list_of(literal_segment_generator(), min_length: 2, max_length: 7),
            [first_index, second_index] <-
              uniq_list_of(integer(0..(length(concrete_segments) - 1)), length: 2)
          ) do
      fewer_params =
        concrete_segments
        |> List.replace_at(first_index, {:param, "first"})
        |> then(&op("fewer_params", method, &1))

      more_params =
        concrete_segments
        |> List.replace_at(first_index, {:param, "first"})
        |> List.replace_at(second_index, {:param, "second"})
        |> then(&op("more_params", method, &1))

      path = render_path(concrete_segments)

      assert {:ok, %{id: "fewer_params"}, _params} =
               Matcher.match([more_params, fewer_params], method, path)

      assert {:ok, %{id: "fewer_params"}, _params} =
               Matcher.match([fewer_params, more_params], method, path)
    end
  end

  property "a unique best-specificity match is invariant under generated permutations" do
    check all(
            {operations, method, path, expected_id} <- unique_best_match_generator(),
            permutation <- shuffle(operations)
          ) do
      assert {:ok, %{id: ^expected_id}, _params} = Matcher.match(operations, method, path)
      assert {:ok, %{id: ^expected_id}, _params} = Matcher.match(permutation, method, path)
    end
  end

  property "an impossible match returns a bounded list of displayable suggestions" do
    check all(
            method <- method_generator(),
            concrete_segments <-
              list_of(literal_segment_generator(), min_length: 1, max_length: 6),
            candidate_methods <- list_of(method_generator(), min_length: 1, max_length: 10),
            extra_segments <-
              list_of(literal_segment_generator(), length: length(candidate_methods))
          ) do
      candidates =
        candidate_methods
        |> Enum.zip(extra_segments)
        |> Enum.with_index()
        |> Enum.map(fn {{candidate_method, extra_segment}, index} ->
          op("candidate_#{index}", candidate_method, concrete_segments ++ [extra_segment])
        end)

      assert {:error, {:no_match, suggestions}} =
               Matcher.match(candidates, method, render_path(concrete_segments))

      assert is_list(suggestions)
      assert length(suggestions) <= 5
      assert Enum.all?(suggestions, &suggestion?/1)
    end
  end

  defp matching_segments_generator do
    gen all(
          segments <- list_of(route_segment_generator(), max_length: 7),
          substitutions <- list_of(literal_segment_generator(), length: length(segments))
        ) do
      concrete_segments =
        segments
        |> Enum.zip(substitutions)
        |> Enum.map(fn
          {{:param, _name}, substitution} -> substitution
          {literal, _substitution} -> literal
        end)

      {segments, concrete_segments}
    end
  end

  defp unique_best_match_generator do
    gen all(
          method <- method_generator(),
          concrete_segments <- list_of(literal_segment_generator(), min_length: 2, max_length: 7),
          competing_count <- integer(1..8),
          earlier_param_indices <-
            list_of(integer(0..(length(concrete_segments) - 2)), length: competing_count)
        ) do
      last_index = length(concrete_segments) - 1

      winner =
        concrete_segments
        |> List.replace_at(last_index, {:param, "winner"})
        |> then(&op("longest_literal_prefix", method, &1))

      competitors =
        earlier_param_indices
        |> Enum.with_index(1)
        |> Enum.map(fn {param_index, index} ->
          segments = List.replace_at(concrete_segments, param_index, {:param, "value_#{index}"})
          op("template_#{index}", method, segments)
        end)

      {[winner | competitors], String.upcase(method), render_path(concrete_segments), winner.id}
    end
  end

  defp route_segment_generator do
    one_of([
      literal_segment_generator(),
      map(identifier_generator(), &{:param, &1})
    ])
  end

  defp literal_segment_generator, do: string(:alphanumeric, min_length: 1, max_length: 12)
  defp identifier_generator, do: string(:alphanumeric, min_length: 1, max_length: 12)
  defp method_generator, do: member_of(@methods)

  defp render_path([]), do: "/"
  defp render_path(segments), do: "/" <> Enum.join(segments, "/")

  defp suggestion?(suggestion) when is_binary(suggestion) do
    case String.split(suggestion, " ", parts: 2) do
      [method, "/" <> template] ->
        method == String.upcase(method) and template != "" and
          not String.contains?(template, " ")

      _ ->
        false
    end
  end

  defp suggestion?(_suggestion), do: false

  defp op(id, method, segments) do
    %Operation{id: id, method: method, path: "/x", segments: segments}
  end
end
