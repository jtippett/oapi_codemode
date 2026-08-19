defmodule OapiCodemode.Proxy do
  @moduledoc """
  The validating, credential-injecting request pipeline:
  match -> policy -> validate -> credentials -> execute -> normalize.

  Requests come from the sandbox as JSON-shaped maps (string keys). Errors
  return `%{phase: atom, message: String.t()}` — phase-tagged so tool-layer
  error messages can say what failed without leaking internals.

  Error messages crossing back to the sandbox are fixed strings wherever the
  underlying detail could embed a credential (transport failures, resolver
  reasons). The detail goes to `Logger` instead.
  """

  require Logger

  alias OapiCodemode.{ApiConfig, Credentials}
  alias OapiCodemode.Ingest.Normalize
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
          {:ok, %{status: integer(), headers: %{String.t() => String.t()}, body: term()}}
          | {:error, %{phase: atom(), message: String.t()}}
  def request(%Entry{} = entry, api_name, opts, ctx) do
    method = opts |> Map.get("method", "GET") |> to_string()
    path = Map.get(opts, "path", "")
    query = Map.get(opts, "query") || %{}
    body = Map.get(opts, "body")

    meta = %{api: api_name, operation: nil, method: String.downcase(method)}
    start = System.monotonic_time()
    :telemetry.execute([:oapi_codemode, :request, :start], %{}, meta)

    # M2: the matched operation is threaded out of the pipeline separately so
    # the *error* event can name it too — a failing operation is exactly the
    # one an operator needs to see on a dashboard.
    case match(entry, method, path) do
      {:error, err} ->
        emit_error(start, meta, err)
        {:error, err}

      {:ok, op, path_params} ->
        meta = %{meta | operation: op.id}

        case after_match(entry, api_name, op, path_params, query, body, opts, ctx) do
          {:ok, resp} ->
            emit(start, [:oapi_codemode, :request, :stop], Map.put(meta, :status, resp.status))
            {:ok, resp}

          {:error, err} ->
            emit_error(start, meta, err)
            {:error, err}
        end
    end
  end

  defp after_match(entry, api_name, op, path_params, query, body, opts, ctx) do
    with :ok <- policy(ctx.policy, op.method),
         {:ok, extra_headers} <- passthrough_headers(entry.config, opts),
         :ok <- validate(entry.config, op, query, body, path_params),
         {:ok, auth} <- credentials(entry, api_name, op, ctx),
         :ok <- reserved_query(query, auth),
         :ok <- reserved_auth_headers(extra_headers, auth) do
      execute(entry.config, op, path_params, query, body, auth, extra_headers, opts, ctx)
    end
  end

  # ele: allowlisted per-call header passthrough (idempotency keys). Names
  # match case-insensitively and forward downcased. Anything not allowlisted
  # is an explicit policy error, never a silent drop — a dropped header is
  # an invisible failure (the model believes its idempotency key arrived).
  # Headers the library or the credential layer owns are reserved even when
  # a host allowlists them (C2 sibling).
  @reserved_headers ~w(authorization proxy-authorization cookie content-type
                       content-length host transfer-encoding connection)

  defp passthrough_headers(config, opts) do
    case Map.get(opts, "headers") do
      nil ->
        {:ok, []}

      headers when is_map(headers) ->
        take_allowed(headers, config.passthrough_headers)

      _other ->
        {:error, %{phase: :policy, message: "headers must be an object of string values"}}
    end
  end

  defp take_allowed(headers, allowlist) do
    allowed = Enum.map(allowlist, &String.downcase/1)

    headers
    |> Enum.reduce_while({:ok, []}, fn {name, value}, {:ok, acc} ->
      lower = name |> to_string() |> String.downcase()

      cond do
        lower in @reserved_headers ->
          {:halt, policy_error("header #{inspect(lower)} is reserved and cannot be set")}

        lower not in allowed ->
          {:halt, policy_error(not_allowed_message(lower, allowed))}

        not is_binary(value) ->
          {:halt, policy_error("header #{inspect(lower)} value must be a string")}

        List.keymember?(acc, lower, 0) ->
          {:halt, policy_error("duplicate header #{inspect(lower)} (names are case-insensitive)")}

        true ->
          {:cont, {:ok, [{lower, value} | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp policy_error(message), do: {:error, %{phase: :policy, message: message}}

  defp not_allowed_message(name, []),
    do: "header #{inspect(name)} cannot be sent: this API allows no header passthrough"

  defp not_allowed_message(name, allowed),
    do:
      "header #{inspect(name)} is not in this API's passthrough allowlist " <>
        "(allowed: #{Enum.join(allowed, ", ")})"

  # C2 sibling for headers: a scheme-specific auth header (e.g. an apiKey
  # header) is reserved even if the host allowlisted its name.
  defp reserved_auth_headers([], _auth), do: :ok

  defp reserved_auth_headers(extra, auth) do
    auth_names = Enum.map(auth.headers, fn {name, _} -> String.downcase(name) end)

    case Enum.find(extra, fn {name, _} -> name in auth_names end) do
      nil ->
        :ok

      {name, _} ->
        {:error,
         %{phase: :policy, message: "header #{inspect(name)} is reserved for authentication"}}
    end
  end

  defp emit_error(start, meta, err),
    do: emit(start, [:oapi_codemode, :request, :error], Map.put(meta, :error, err.phase))

  defp emit(start, event, meta),
    do: :telemetry.execute(event, %{duration: System.monotonic_time() - start}, meta)

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

  defp validate(%ApiConfig{validate: :off}, _op, _query, _body, _path_params), do: :ok

  defp validate(%ApiConfig{validate: mode}, op, query, body, path_params) do
    case Validator.validate(op, %{query: query, body: body, path_params: path_params}) do
      :ok ->
        :ok

      {:error, message} when mode == :warn ->
        Logger.warning("oapi_codemode validation (warn mode): #{message}")
        :ok

      {:error, message} ->
        {:error, %{phase: :validate, message: message}}
    end
  end

  defp credentials(entry, api_name, op, ctx) do
    scheme = selected_scheme(entry, op)

    request = %{
      method: op.method,
      base_url: entry.config.base_url,
      host: URI.parse(entry.config.base_url).host,
      path: op.path
    }

    with {:ok, credential} <- ctx.resolver.resolve(api_name, scheme, request, ctx.context),
         {:ok, auth} <- Credentials.attach(scheme, credential) do
      {:ok, auth}
    else
      {:error, message} when is_binary(message) ->
        {:error, %{phase: :credentials, message: message}}

      # C1(b): a host resolver's failure reason is free-form and routinely
      # embeds the token it failed on ({:expired, "tok-..."}). Log it, return
      # a fixed string.
      {:error, reason} ->
        Logger.error(
          "oapi_codemode credential resolution failed for #{inspect(api_name)}: #{inspect(reason)}"
        )

        {:error, %{phase: :credentials, message: "credential resolution failed"}}
    end
  end

  # C2: auth query params are injected after the LLM's. A colliding key from
  # the sandbox would either overwrite the credential or (with a permissive
  # upstream) echo it back in an error. Reject before the request is built.
  defp reserved_query(query, auth) do
    case Enum.find(Map.keys(auth.query), &Map.has_key?(query, &1)) do
      nil ->
        :ok

      name ->
        {:error,
         %{phase: :policy, message: "query parameter #{name} is reserved for authentication"}}
    end
  end

  defp selected_scheme(entry, op) do
    case entry.config.security_scheme do
      scheme when is_map(scheme) ->
        scheme

      name_or_nil ->
        schemes = entry.artifact.security_schemes

        name =
          name_or_nil ||
            case op.security do
              [req | _] when is_map(req) and map_size(req) > 0 -> req |> Map.keys() |> hd()
              _ -> nil
            end

        if name, do: schemes[name], else: nil
    end
  end

  defp execute(config, op, path_params, query, body, auth, extra_headers, opts, ctx) do
    with {:ok, query_string} <- build_query_string(op, query, auth),
         {:ok, req_body, content_type} <- encode_body(body, opts) do
      url = build_url(config.base_url, op, path_params)
      full_url = if query_string == "", do: url, else: url <> "?" <> query_string

      headers =
        auth.headers ++
          if(content_type, do: [{"content-type", content_type}], else: []) ++ extra_headers

      req =
        Req.new(
          [
            method: http_method(op.method),
            url: full_url,
            headers: headers,
            body: req_body,
            retry: false,
            max_retries: 0,
            # I5: a 3xx comes back as data. Following it would re-send the
            # Authorization header to a host the *upstream* chose. A host
            # that wants redirects can pass `redirect: true` in req_options,
            # which is appended after this default and wins.
            redirect: false
          ] ++ merge_req_options(config.req_options, ctx.req_options)
        )

      case Req.request(req) do
        {:ok, resp} ->
          {:ok,
           %{
             status: resp.status,
             headers: whitelist_headers(resp.headers, config),
             body: cap_body(resp.body, config.max_response_bytes)
           }}

        # C1(a): Mint's invalid-header errors quote the offending header
        # VALUE — i.e. the credential — in their message. Nothing but the
        # exception's module name may cross back.
        {:error, err} ->
          Logger.error("oapi_codemode upstream request failed: #{inspect(err)}")

          {:error, %{phase: :transport, message: "upstream request failed (#{error_name(err)})"}}
      end
    end
  end

  # I1: Req entry-merges `:headers` across a single options list (it's split
  # out and folded with Req.Fields.merge/2 per occurrence), but `:params`
  # goes through the generic options bucket, which is built with
  # `Map.new/1` — a keyword list with two `:params` entries collapses to
  # whichever one is LAST, wholesale. Concatenating config.req_options ++
  # ctx.req_options and handing the result straight to Req therefore let a
  # call-time `:params` silently erase a registration-time one. Merge
  # `:params` entry-wise ourselves (call-time wins on key collision) before
  # Req ever sees the combined list; every other key keeps the existing
  # override-by-concatenation-order semantics (call-time wins on conflict).
  defp merge_req_options(config_opts, call_opts) do
    case {Keyword.get(config_opts, :params), Keyword.get(call_opts, :params)} do
      {nil, _} ->
        config_opts ++ call_opts

      {_, nil} ->
        config_opts ++ call_opts

      {config_params, call_params} ->
        merged_params = Keyword.merge(config_params, call_params)

        Keyword.delete(config_opts, :params) ++
          Keyword.delete(call_opts, :params) ++ [params: merged_params]
    end
  end

  defp error_name(%mod{}), do: inspect(mod)
  defp error_name(_), do: "unknown"

  # I3: query params that can't be serialized (e.g. a nested map/list without
  # a style that knows how to flatten it) surface as a :validate-phase error
  # — this is a request-shape problem the caller can fix, not a transport
  # failure.
  defp build_query_string(op, query, auth) do
    pairs =
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

    case Query.encode(pairs) do
      {:ok, qs} -> {:ok, qs}
      {:error, message} -> {:error, %{phase: :validate, message: message}}
    end
  end

  # M4: derived from the ingest side's method list so the two can't drift —
  # a method Normalize starts extracting but the proxy can't send would be a
  # FunctionClauseError at request time.
  @http_methods Map.new(Normalize.methods(), &{&1, String.to_atom(&1)})

  defp http_method(method), do: Map.fetch!(@http_methods, method)

  defp build_url(base_url, op, path_params) do
    path =
      Enum.map_join(op.segments, "/", fn
        # M9: RFC 3986 path-segment percent-encoding, not www-form encoding
        # — a space must become "%20" (not "+", which is meaningless in a
        # path) and any literal "/" in the value must become "%2F" so it
        # can't smuggle an extra path segment (traversal) into the URL.
        {:param, name} ->
          path_params |> Map.fetch!(name) |> to_string() |> URI.encode(&URI.char_unreserved?/1)

        seg ->
          seg
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

  defp encode_body(nil, _opts), do: {:ok, nil, nil}

  defp encode_body(body, %{"rawBody" => true} = opts) when is_binary(body),
    do: {:ok, body, opts["contentType"] || "application/octet-stream"}

  # I2: Req hands a raw body straight to the adapter as iodata. A map here
  # raises ArgumentError deep inside Mint; it's a request-shape mistake the
  # caller can fix, so name it.
  defp encode_body(_body, %{"rawBody" => true}),
    do: {:error, %{phase: :validate, message: "rawBody requires a string body"}}

  defp encode_body(body, opts),
    do: {:ok, Jason.encode!(body), opts["contentType"] || "application/json"}

  # I4: a map, matching the `Record<string, string>` the execute tool
  # declares. Repeated headers (set-cookie-ish) join with ", " per RFC 9110.
  defp whitelist_headers(headers, config) do
    extra = Enum.map(config.response_headers, &String.downcase/1)

    headers
    |> Enum.flat_map(fn {k, vs} -> Enum.map(List.wrap(vs), &{String.downcase(k), &1}) end)
    |> Enum.filter(fn {k, _} ->
      k in @response_header_whitelist or k in extra or
        Enum.any?(@response_header_prefixes, &String.starts_with?(k, &1))
    end)
    |> Enum.reduce(%{}, fn {k, v}, acc -> Map.update(acc, k, v, &(&1 <> ", " <> v)) end)
  end

  # I3: the cap is a BYTE cap (String.slice/3 counts graphemes, which let
  # ~2-4x the budget through for non-ASCII text), and a body that isn't
  # valid UTF-8 never flows onward as raw bytes — Jason.encode! would crash
  # on it once the tool layer wraps the result.
  defp cap_body(body, max_bytes) when is_binary(body) do
    cond do
      not String.valid?(body) ->
        binary_envelope(body, max_bytes)

      byte_size(body) > max_bytes ->
        truncate_bytes(body, max_bytes) <> truncation_marker(max_bytes)

      true ->
        body
    end
  end

  # Req already decoded JSON. If it's over budget, say so structurally —
  # replacing a map with a chopped, unparseable JSON string silently changes
  # the response's type out from under the sandbox.
  defp cap_body(body, max_bytes) do
    encoded = Jason.encode!(body)

    if byte_size(encoded) > max_bytes do
      %{
        "truncated" => true,
        "bytes" => byte_size(encoded),
        "preview" => truncate_bytes(encoded, max_bytes)
      }
    else
      body
    end
  end

  defp binary_envelope(body, max_bytes) do
    truncated? = byte_size(body) > max_bytes
    bytes = if truncated?, do: binary_part(body, 0, max_bytes), else: body

    %{
      "encoding" => "base64",
      "data" => Base.encode64(bytes),
      "note" => "response was not valid UTF-8",
      "truncated" => truncated?,
      "bytes" => byte_size(body)
    }
  end

  defp truncation_marker(max_bytes), do: "\n[truncated: response exceeded #{max_bytes} bytes]"

  # Cut at the byte budget, then walk back (at most 3 bytes) off any
  # half-written codepoint so the result is still a valid string.
  defp truncate_bytes(bin, max_bytes) do
    bin |> binary_part(0, max_bytes) |> trim_to_valid()
  end

  defp trim_to_valid(bin) do
    cond do
      String.valid?(bin) -> bin
      byte_size(bin) == 0 -> ""
      true -> bin |> binary_part(0, byte_size(bin) - 1) |> trim_to_valid()
    end
  end
end
