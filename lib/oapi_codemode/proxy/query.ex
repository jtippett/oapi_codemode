defmodule OapiCodemode.Proxy.Query do
  @moduledoc """
  Serializes query parameters honoring the spec's style/explode declarations
  (the ele lesson: default serializers silently mismatch backend expectations).
  Supported: form (explode true/false), deepObject, spaceDelimited,
  pipeDelimited. Anything else falls back to form+explode.

  `nil`-valued params are dropped entirely (never rendered as `name=`), as
  are empty arrays (dropped regardless of explode).

  Non-scalar leaves that can't be represented (e.g. a nested map/list
  without a style that knows how to flatten it) are reported as
  `{:error, message}` rather than raising deep inside `to_string/1` — that
  used to either crash (Protocol.UndefinedError) or silently corrupt the
  value (`to_string/1` on a list of integers coerces through a charlist).
  """

  @spec encode([{String.t(), term(), map()}]) :: {:ok, String.t()} | {:error, String.t()}
  def encode(params) do
    params
    |> Enum.reduce_while({:ok, []}, fn param, {:ok, acc} ->
      case pairs(param) do
        {:ok, list} -> {:cont, {:ok, acc ++ list}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} ->
        query =
          list
          |> Enum.sort_by(fn {name, _value, _mode} -> name end)
          |> Enum.map_join("&", &render_pair/1)

        {:ok, query}

      {:error, _} = err ->
        err
    end
  end

  defp render_pair({name, value, :raw}), do: URI.encode_www_form(name) <> "=" <> value

  defp render_pair({name, value, :form}),
    do: URI.encode_www_form(name) <> "=" <> URI.encode_www_form(value)

  # nil and empty-array values are dropped entirely — never rendered as
  # "name=" (I7), and an empty array carries no information to serialize
  # in either explode mode (M7).
  defp pairs({_name, nil, _param_spec}), do: {:ok, []}
  defp pairs({_name, [], _param_spec}), do: {:ok, []}

  defp pairs({name, value, param_spec}) when is_list(value) do
    case style(param_spec) do
      "spaceDelimited" -> delimited(name, value, param_spec, " ")
      "pipeDelimited" -> delimited(name, value, param_spec, "|")
      _ -> array_form(name, value, param_spec)
    end
  end

  defp pairs({name, value, %{"style" => "deepObject"}}) when is_map(value) do
    deep_object(name, value)
  end

  defp pairs({name, value, param_spec}) when is_map(value) do
    object_form(name, value, param_spec)
  end

  # By this clause, earlier heads (nil, [], list, map) have already ruled
  # out everything scalar/1 would reject, so it always returns {:ok, _}
  # here — matching on :error too used to trip a "clause will never match"
  # compiler warning.
  defp pairs({name, value, _param_spec}), do: {:ok, [{name, to_string(value), :form}]}

  defp array_form(name, value, param_spec) do
    if explode?(param_spec) do
      map_scalars(value, fn s -> {name, s, :form} end, name)
    else
      case scalars(value, name) do
        {:ok, list} -> {:ok, [{name, Enum.join(list, ","), :form}]}
        {:error, _} = err -> err
      end
    end
  end

  # spaceDelimited/pipeDelimited (M6): explode:false joins scalars with the
  # delimiter, percent-encoded via RFC 3986 unreserved-char rules so a
  # literal space becomes "%20" (not "+" — that's www-form encoding, wrong
  # here). explode:true behaves like plain form (repeated keys).
  defp delimited(name, value, param_spec, sep) do
    if explode?(param_spec) do
      array_form(name, value, Map.put(param_spec, "explode", true))
    else
      case scalars(value, name) do
        {:ok, list} ->
          joined =
            list
            |> Enum.join(sep)
            |> URI.encode(&URI.char_unreserved?/1)

          {:ok, [{name, joined, :raw}]}

        {:error, _} = err ->
          err
      end
    end
  end

  defp deep_object(name, value) do
    Enum.reduce_while(value, {:ok, []}, fn {k, v}, {:ok, acc} ->
      case scalar(v) do
        {:ok, s} -> {:cont, {:ok, acc ++ [{"#{name}[#{k}]", s, :form}]}}
        :error -> {:halt, {:error, invalid("#{name}[#{k}]", v)}}
      end
    end)
  end

  # I3a: form-style (default) explode with an object parameter serializes
  # each property as its own top-level key=value pair — per OpenAPI's
  # form/explode semantics for object parameters, the *property* names
  # become query keys, not the parameter's own name.
  defp object_form(name, value, param_spec) do
    if explode?(param_spec) do
      Enum.reduce_while(value, {:ok, []}, fn {k, v}, {:ok, acc} ->
        case scalar(v) do
          {:ok, s} -> {:cont, {:ok, acc ++ [{to_string(k), s, :form}]}}
          :error -> {:halt, {:error, invalid("#{name}.#{k}", v)}}
        end
      end)
    else
      value
      |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
        case scalar(v) do
          {:ok, s} -> {:cont, {:ok, acc ++ [to_string(k), s]}}
          :error -> {:halt, {:error, invalid("#{name}.#{k}", v)}}
        end
      end)
      |> case do
        {:ok, kvs} -> {:ok, [{name, Enum.join(kvs, ","), :form}]}
        {:error, _} = err -> err
      end
    end
  end

  defp style(param_spec), do: param_spec["style"] || "form"

  defp explode?(param_spec) do
    case Map.get(param_spec, "explode") do
      nil -> style(param_spec) == "form"
      other -> other
    end
  end

  defp scalar(v) when is_list(v) or is_map(v), do: :error
  defp scalar(v), do: {:ok, to_string(v)}

  defp scalars(values, name) do
    Enum.reduce_while(values, {:ok, []}, fn v, {:ok, acc} ->
      case scalar(v) do
        {:ok, s} -> {:cont, {:ok, acc ++ [s]}}
        :error -> {:halt, {:error, invalid(name, v)}}
      end
    end)
  end

  defp map_scalars(values, to_pair, name) do
    Enum.reduce_while(values, {:ok, []}, fn v, {:ok, acc} ->
      case scalar(v) do
        {:ok, s} -> {:cont, {:ok, acc ++ [to_pair.(s)]}}
        :error -> {:halt, {:error, invalid(name, v)}}
      end
    end)
  end

  defp invalid(name, value) do
    "query parameter #{inspect(name)}: nested #{kind(value)} values are not supported"
  end

  defp kind(v) when is_map(v), do: "object"
  defp kind(v) when is_list(v), do: "array"
end
