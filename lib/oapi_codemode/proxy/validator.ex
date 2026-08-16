defmodule OapiCodemode.Proxy.Validator do
  @moduledoc """
  Validates an intercepted request against the operation's dereferenced schema.

  Deliberately shallow: types, required, enums — recursively through objects,
  but no oneOf/anyOf/allOf arbitration, no pattern/format checks (v1 scope).
  Error messages quote the violated schema fragment: the spec is the
  documentation the model just read, so errors grounded in it are actionable.
  """

  alias OapiCodemode.Operation

  @spec validate(Operation.t(), %{query: map(), body: term()}) :: :ok | {:error, String.t()}
  def validate(%Operation{} = op, request) do
    with :ok <- validate_query(op, request.query || %{}) do
      validate_body(op, request.body)
    end
  end

  defp validate_query(op, query) do
    op.parameters
    |> Enum.filter(&(&1["in"] == "query"))
    |> Enum.reduce_while(:ok, fn param, :ok ->
      name = param["name"]
      value = query[name]

      cond do
        is_nil(value) and param["required"] ->
          {:halt,
           {:error, "query parameter #{inspect(name)} is required. Schema: #{frag(param)}"}}

        is_nil(value) ->
          {:cont, :ok}

        true ->
          case check(value, param["schema"], "query parameter #{inspect(name)}") do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp validate_body(%{request_body: nil}, _body), do: :ok

  defp validate_body(%{request_body: %{"required" => true, "schema" => schema}}, nil),
    do: {:error, "request body is required. Schema: #{frag(schema)}"}

  defp validate_body(_op, nil), do: :ok

  defp validate_body(%{request_body: %{"schema" => schema}}, body),
    do: check(body, schema, "request body")

  defp check(_value, nil, _where), do: :ok

  defp check(value, %{"enum" => enum} = schema, where) do
    if value in enum do
      check(value, Map.delete(schema, "enum"), where)
    else
      {:error,
       "#{where}: #{inspect(value)} is not one of #{inspect(enum)}. Schema: #{frag(schema)}"}
    end
  end

  defp check(value, %{"type" => "object"} = schema, where) when is_map(value) do
    required = schema["required"] || []
    properties = schema["properties"] || %{}

    missing = Enum.filter(required, &(not Map.has_key?(value, &1)))

    if missing != [] do
      {:error, "#{where}: missing required field(s) #{inspect(missing)}. Schema: #{frag(schema)}"}
    else
      Enum.reduce_while(value, :ok, fn {key, val}, :ok ->
        case check(val, properties[key], "#{where}.#{key}") do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp check(value, %{"type" => type} = schema, where) do
    if type_ok?(value, type) do
      :ok
    else
      {:error, "#{where}: expected #{type}, got #{inspect(value)}. Schema: #{frag(schema)}"}
    end
  end

  defp check(_value, _schema, _where), do: :ok

  defp type_ok?(v, "string"), do: is_binary(v)

  defp type_ok?(v, "integer"),
    do: is_integer(v) or (is_binary(v) and match?({_, ""}, Integer.parse(v)))

  defp type_ok?(v, "number"),
    do: is_number(v) or (is_binary(v) and match?({_, ""}, Float.parse(v)))

  defp type_ok?(v, "boolean"), do: is_boolean(v) or v in ["true", "false"]
  defp type_ok?(v, "array"), do: is_list(v)
  defp type_ok?(v, "object"), do: is_map(v)
  defp type_ok?(_v, _), do: true

  # Quote a compact schema fragment (capped so errors stay readable).
  defp frag(schema) do
    schema
    |> Map.take(["type", "required", "enum", "properties", "in", "name", "schema"])
    |> Jason.encode!()
    |> String.slice(0, 400)
  end
end
