defmodule OapiCodemode.Ingest.NormalizePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import StreamData

  alias OapiCodemode.Ingest.Normalize

  @methods ~w(get post put patch delete head options)

  property "normalized operation ids are pairwise distinct" do
    check all(spec <- arbitrary_spec_generator()) do
      ids = spec |> Normalize.operations() |> Enum.map(& &1.id)

      assert length(Enum.uniq(ids)) == length(ids)
    end
  end

  property "already-unique explicit operation ids pass through unchanged" do
    check all(
            ids <- uniq_list_of(raw_id_generator(), max_length: 14),
            methods <- list_of(method_generator(), length: length(ids))
          ) do
      entries =
        ids
        |> Enum.zip(methods)
        |> Enum.with_index()
        |> Enum.map(fn {{id, method}, index} ->
          path = indexed_path("unique", index)
          {path, method, id}
        end)

      spec =
        spec_from_entries(entries, fn id ->
          %{"operationId" => id, "responses" => %{}}
        end)

      expected_by_path = Map.new(entries, fn {path, _method, id} -> {path, id} end)
      operations = Normalize.operations(spec)
      output_ids = Enum.map(operations, & &1.id)

      assert MapSet.new(output_ids) == MapSet.new(ids)

      assert Enum.all?(operations, fn operation ->
               operation.id == Map.fetch!(expected_by_path, operation.path)
             end)
    end
  end

  property "repeated ids receive consecutive suffixes in path-sort order" do
    check all(id <- raw_id_generator(), count <- integer(2..15)) do
      paths =
        for index <- 0..(count - 1), into: %{} do
          path = indexed_path("collision", index)
          {path, %{"get" => %{"operationId" => id, "responses" => %{}}}}
        end

      actual_ids =
        %{"paths" => paths}
        |> Normalize.operations()
        |> Enum.map(& &1.id)

      expected_ids = [id | Enum.map(2..count, &"#{id}_#{&1}")]

      assert actual_ids == expected_ids
    end
  end

  property "reusing normalized ids as explicit ids is idempotent" do
    check all(spec <- arbitrary_spec_generator()) do
      normalized_ids = spec |> Normalize.operations() |> Enum.map(& &1.id)

      second_spec =
        normalized_ids
        |> Enum.with_index()
        |> Enum.map(fn {id, index} -> {indexed_path("normalized", index), "get", id} end)
        |> spec_from_entries(fn id -> %{"operationId" => id, "responses" => %{}} end)

      renormalized_ids = second_spec |> Normalize.operations() |> Enum.map(& &1.id)

      assert renormalized_ids == normalized_ids
    end
  end

  defp arbitrary_spec_generator do
    gen all(path_specs <- list_of(path_spec_generator(), max_length: 9)) do
      paths =
        path_specs
        |> Enum.with_index()
        |> Map.new(fn {{suffix_segments, path_item}, index} ->
          base_path = indexed_path("resource", index)

          path =
            case suffix_segments do
              [] -> base_path
              segments -> base_path <> "/" <> Enum.join(segments, "/")
            end

          {path, path_item}
        end)

      %{"openapi" => "3.1.0", "paths" => paths}
    end
  end

  defp path_spec_generator do
    gen all(
          suffix_segments <- list_of(path_segment_generator(), max_length: 3),
          path_item <- path_item_generator()
        ) do
      {suffix_segments, path_item}
    end
  end

  defp path_item_generator do
    @methods
    |> Enum.map(fn method ->
      tuple({constant(method), one_of([constant(:absent), operation_generator()])})
    end)
    |> fixed_list()
    |> map(fn method_slots ->
      for {method, operation} <- method_slots, operation != :absent, into: %{} do
        {method, operation}
      end
    end)
  end

  defp operation_generator do
    frequency([
      {2, constant(%{"responses" => %{}})},
      {1, constant(%{"operationId" => nil, "responses" => %{}})},
      {5,
       map(explicit_id_generator(), fn id ->
         %{"operationId" => id, "responses" => %{}}
       end)}
    ])
  end

  defp explicit_id_generator do
    frequency([
      {3, member_of(~w(explicit_alpha explicit_beta explicit_gamma))},
      {5, map(raw_id_generator(), &"explicit_#{&1}")}
    ])
  end

  defp spec_from_entries(entries, operation_fun) do
    paths =
      Map.new(entries, fn {path, method, id} ->
        {path, %{method => operation_fun.(id)}}
      end)

    %{"openapi" => "3.1.0", "paths" => paths}
  end

  defp indexed_path(prefix, index) do
    "/#{prefix}_#{String.pad_leading(Integer.to_string(index), 3, "0")}"
  end

  defp raw_id_generator, do: string(:alphanumeric, min_length: 1, max_length: 16)
  defp path_segment_generator, do: string(:alphanumeric, min_length: 1, max_length: 10)
  defp method_generator, do: member_of(@methods)
end
