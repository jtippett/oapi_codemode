defmodule OapiCodemode.Proxy do
  @moduledoc """
  The validating, credential-injecting request pipeline:
  match -> validate -> policy -> credentials -> execute -> normalize.

  Requests come from the sandbox as JSON-shaped maps (string keys). Errors
  return `%{phase: atom, message: String.t()}` — phase-tagged so tool-layer
  error messages can say what failed without leaking internals.
  """

  alias OapiCodemode.{ApiConfig, Credentials}
  alias OapiCodemode.Proxy.{Matcher, Query, Validator}
  alias OapiCodemode.Registry.Entry

  @response_header_whitelist ~w(content-type x-request-id retry-after)
  @response_header_prefixes ~w(x-ratelimit-)

  @type request_opts :: %{required(String.t()) => term()}
  @type ctx :: %{
          resolver: module(),
          context: map(),
          policy: :read_only | :all,
          req_options: keyword()
        }

  @spec request(%Entry{}, String.t(), request_opts(), ctx()) ::
          {:ok, %{status: integer(), headers: list(), body: term()}}
          | {:error, %{phase: atom(), message: String.t()}}
  def request(%Entry{} = entry, api_name, opts, ctx) do
    method = opts |> Map.get("method", "GET") |> to_string()
    path = Map.get(opts, "path", "")
    query = Map.get(opts, "query") || %{}
    body = Map.get(opts, "body")

    meta = %{api: api_name, operation: nil, method: String.downcase(method)}
    start = System.monotonic_time()
    :telemetry.execute([:oapi_codemode, :request, :start], %{}, meta)

    result =
      with {:ok, op, path_params} <- match(entry, method, path),
           :ok <- policy(ctx.policy, op.method),
           :ok <- validate(entry.config, op, query, body),
           {:ok, auth} <- credentials(entry, api_name, op, ctx),
           {:ok, resp} <- execute(entry.config, op, path_params, query, body, auth, opts, ctx) do
        {:ok, resp, op}
      end

    case result do
      {:ok, resp, op} ->
        emit_stop(start, %{meta | operation: op.id}, resp.status)
        {:ok, resp}

      {:error, %{phase: _} = err} ->
        :telemetry.execute(
          [:oapi_codemode, :request, :error],
          %{},
          Map.put(meta, :error, err.phase)
        )

        {:error, err}
    end
  end

  defp emit_stop(start, meta, status) do
    duration = System.monotonic_time() - start

    :telemetry.execute(
      [:oapi_codemode, :request, :stop],
      %{duration: duration},
      Map.put(meta, :status, status)
    )
  end

  defp match(entry, method, path) do
    case Matcher.match(entry.artifact.operations, method, path) do
      {:ok, op, params} ->
        {:ok, op, params}

      {:error, {:no_match, suggestions}} ->
        {:error,
         %{
           phase: :match,
           message:
             "no operation matches #{String.upcase(method)} #{path}. Nearest: " <>
               Enum.join(suggestions, ", ")
         }}
    end
  end

  defp policy(:all, _method), do: :ok
  defp policy(:read_only, "get"), do: :ok
  defp policy(:read_only, "head"), do: :ok

  defp policy(:read_only, method),
    do:
      {:error,
       %{
         phase: :policy,
         message:
           "#{String.upcase(method)} requests are not allowed by this read-only tool. " <>
             "Use the mutations variant of the execute tool."
       }}

  defp validate(%ApiConfig{validate: :off}, _op, _query, _body), do: :ok

  defp validate(%ApiConfig{validate: mode}, op, query, body) do
    case Validator.validate(op, %{query: query, body: body}) do
      :ok ->
        :ok

      {:error, message} when mode == :warn ->
        require Logger
        Logger.warning("oapi_codemode validation (warn mode): #{message}")
        :ok

      {:error, message} ->
        {:error, %{phase: :validate, message: message}}
    end
  end

  defp credentials(entry, api_name, op, ctx) do
    scheme = selected_scheme(entry, op)

    with {:ok, credential} <- ctx.resolver.resolve(api_name, scheme, ctx.context),
         {:ok, auth} <- Credentials.attach(scheme, credential) do
      {:ok, auth}
    else
      {:error, message} when is_binary(message) ->
        {:error, %{phase: :credentials, message: message}}

      {:error, reason} ->
        {:error,
         %{phase: :credentials, message: "credential resolution failed: #{inspect(reason)}"}}
    end
  end

  defp selected_scheme(entry, op) do
    schemes = entry.artifact.security_schemes

    name =
      entry.config.security_scheme ||
        case op.security do
          [req | _] when is_map(req) and map_size(req) > 0 -> req |> Map.keys() |> hd()
          _ -> nil
        end

    if name, do: schemes[name], else: nil
  end

  defp execute(config, op, path_params, query, body, auth, opts, ctx) do
    url = build_url(config.base_url, op, path_params)

    query_string =
      op.parameters
      |> Enum.filter(&(&1["in"] == "query"))
      |> Enum.flat_map(fn p ->
        case Map.fetch(query, p["name"]) do
          {:ok, v} -> [{p["name"], v, p}]
          :error -> []
        end
      end)
      |> Kernel.++(extra_query(query, op))
      |> Kernel.++(Enum.map(auth.query, fn {k, v} -> {k, v, %{}} end))
      |> Query.encode()

    full_url = if query_string == "", do: url, else: url <> "?" <> query_string

    {req_body, content_type} = encode_body(body, opts)

    headers =
      auth.headers ++ if content_type, do: [{"content-type", content_type}], else: []

    req =
      Req.new(
        [
          method: http_method(op.method),
          url: full_url,
          headers: headers,
          body: req_body,
          retry: false,
          max_retries: 0
        ] ++ ctx.req_options
      )

    case Req.request(req) do
      {:ok, resp} ->
        {:ok,
         %{
           status: resp.status,
           headers: whitelist_headers(resp.headers),
           body: cap_body(resp.body, config.max_response_bytes)
         }}

      {:error, err} ->
        {:error, %{phase: :transport, message: "request failed: #{Exception.message(err)}"}}
    end
  end

  @http_methods %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete,
    "head" => :head,
    "options" => :options
  }

  defp http_method(method), do: Map.fetch!(@http_methods, method)

  defp build_url(base_url, op, path_params) do
    path =
      Enum.map_join(op.segments, "/", fn
        {:param, name} -> path_params |> Map.fetch!(name) |> to_string() |> URI.encode_www_form()
        seg -> seg
      end)

    String.trim_trailing(base_url, "/") <> "/" <> path
  end

  # Query keys the spec doesn't declare still pass through (validate mode
  # already had its say); serialize them form/explode-default.
  defp extra_query(query, op) do
    declared = op.parameters |> Enum.filter(&(&1["in"] == "query")) |> MapSet.new(& &1["name"])

    query
    |> Enum.reject(fn {k, _} -> MapSet.member?(declared, k) end)
    |> Enum.map(fn {k, v} -> {k, v, %{}} end)
  end

  defp encode_body(nil, _opts), do: {nil, nil}

  defp encode_body(body, %{"rawBody" => true} = opts),
    do: {body, opts["contentType"] || "application/octet-stream"}

  defp encode_body(body, opts),
    do: {Jason.encode!(body), opts["contentType"] || "application/json"}

  defp whitelist_headers(headers) do
    headers
    |> Enum.flat_map(fn {k, vs} -> Enum.map(List.wrap(vs), &{String.downcase(k), &1}) end)
    |> Enum.filter(fn {k, _} ->
      k in @response_header_whitelist or
        Enum.any?(@response_header_prefixes, &String.starts_with?(k, &1))
    end)
  end

  defp cap_body(body, max_bytes) when is_binary(body) do
    if byte_size(body) > max_bytes do
      String.slice(body, 0, max_bytes) <> "\n[truncated: response exceeded #{max_bytes} bytes]"
    else
      body
    end
  end

  # Req already decoded JSON; cap after re-encoding only if enormous.
  defp cap_body(body, max_bytes) do
    encoded = Jason.encode!(body)

    if byte_size(encoded) > max_bytes do
      String.slice(encoded, 0, max_bytes) <> "\n[truncated: response exceeded #{max_bytes} bytes]"
    else
      body
    end
  end
end
