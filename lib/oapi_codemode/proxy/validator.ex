defmodule OapiCodemode.Proxy.Validator do
  @moduledoc """
  Validates an intercepted request against the operation's dereferenced schema.

  Deliberately shallow: types, required, enums — recursively through objects
  and arrays, but no oneOf/anyOf/allOf arbitration, no pattern/format checks
  (v1 scope). Error messages quote the violated schema fragment: the spec is
  the documentation the model just read, so errors grounded in it are
  actionable.

  Coverage (v1 decision): query, body, and path parameters are validated.
  Header and cookie parameters are NOT validated — only path bindings come
  from a source (the matcher) the library controls closely enough to check
  cheaply; headers/cookies are left to the upstream API to reject.

  Also deliberate: unknown/undeclared query parameters and `additionalProperties`
  on objects are never rejected. Validation here is a guardrail that catches
  the model's mistakes against the spec it just read — not a firewall. Anything
  not covered by the schema passes through unchanged.
  """

  alias OapiCodemode.Operation

  @spec validate(
          Operation.t(),
          %{optional(:query) => map(), optional(:body) => term(), optional(:path_params) => map()}
        ) :: :ok | {:error, String.t()}
  def validate(%Operation{} = op, request \\ %{}) do
    path_params = Map.get(request, :path_params) || %{}
    query = Map.get(request, :query) || %{}
    body = Map.get(request, :body)

    with :ok <- validate_path(op, path_params),
         :ok <- validate_query(op, query) do
      validate_body(op, body)
    end
  end

  defp validate_path(op, path_params) do
    op.parameters
    |> Enum.filter(&(&1["in"] == "path"))
    |> Enum.reduce_while(:ok, fn param, :ok ->
      name = param["name"]
      value = path_params[name]

      if is_nil(value) do
        {:cont, :ok}
      else
        case check(value, param["schema"], "path parameter #{inspect(name)}") do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    end)
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
    # I1: coerce first (same leniency as type_ok?/2), then check membership,
    # so a lenient type match ("10" for an integer schema) isn't punished by
    # a stricter, pre-coercion enum check.
    coerced = coerce(value, schema["type"])

    if coerced in enum do
      check(coerced, Map.delete(schema, "enum"), where)
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

  # M1: recurse into array elements against schema["items"], naming the
  # offending index in the error path (e.g. "body.tags[1]").
  defp check(value, %{"type" => "array"} = schema, where) when is_list(value) do
    items_schema = schema["items"]

    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {el, idx}, :ok ->
      case check(el, items_schema, "#{where}[#{idx}]") do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
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

  # Same leniency as type_ok?/2: a string value that parses cleanly as the
  # schema's declared type coerces to that type before enum comparison.
  # Anything that doesn't cleanly parse is left as-is (and will fail the
  # enum/type check on its own merits).
  defp coerce(value, "integer") when is_binary(value) do
    case Integer.parse(value) do
      {i, ""} -> i
      _ -> value
    end
  end

  defp coerce(value, "number") when is_binary(value) do
    case Float.parse(value) do
      {f, ""} -> f
      _ -> value
    end
  end

  defp coerce("true", "boolean"), do: true
  defp coerce("false", "boolean"), do: false
  defp coerce(value, _type), do: value

  # Quote a compact schema fragment (capped so errors stay readable).
  defp frag(schema) when is_map(schema) do
    schema
    |> Map.take(["type", "required", "enum", "properties", "in", "name", "schema"])
    |> Jason.encode!()
    |> String.slice(0, 400)
  end

  # I2: a declared-required body (or param) can legally have `"schema" =>
  # nil` in a loosely-authored spec — don't crash on Map.take(nil, _).
  defp frag(_schema), do: "(no schema)"
end
