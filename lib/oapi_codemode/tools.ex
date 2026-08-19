defmodule OapiCodemode.Tools do
  @moduledoc """
  Emits the two codemode tools as data plus handlers. Transport-agnostic:
  hosts wrap these into their own tool layers (gentility's CloudLoop.Tool,
  ele's UserMCP.Tool, or a gen_mcp server).

  `definitions/1` opts:
    * `:registry` (required) — the Registry server
    * `:executor` (required) — module implementing OapiCodemode.Executor
    * `:resolver` (required) — module implementing OapiCodemode.Credentials
    * `:policy` — :read_only (default) or :all
    * `:max_result_tokens` — default 6000
    * `:max_calls` — max intercepted `request()` calls per execute run,
      default 100; `:infinity` disables. Calls beyond the limit return an
      error payload to the sandbox; only the first refusal is logged, so
      the call log stays bounded even under an executor whose timeout is
      compute-only (ele P1; see `Executor.SafeJS`)
    * `:timeout` — sandbox timeout ms, default 30_000
    * `:executor_opts` — extra keyword opts forwarded verbatim to the
      executor's `run/3` (e.g. `[limits: %{max_memory: 256_000_000}]` for
      `Executor.ZapCode` — spec globals cost well over their JSON size in
      the value-typed VM, so search over multi-MB specs needs more than
      zapcode's 64MB default). `:timeout` above is merged in unless already
      present here.
    * `:search_tool_name` — default "search_apis". Set a distinct name when a
      host emits per-API-instance tools.
    * `:execute_tool_name` — default "execute_api_code". A host that wants a
      separate mutating tool alongside the read-only one calls `definitions/1`
      twice: once with the defaults (search + read-only execute), once with
      `policy: :all`, a distinct `:execute_tool_name` (e.g.
      `"execute_api_mutations"`), and `include_search: false` (search only
      needs to be offered once).
    * `:include_search` — default true. Set false to omit `search_apis` from
      the returned list (for the second call in the two-tool-variant pattern
      above).

  I2: `execute_api_code`/`execute_api_mutations` are two separate tools with
  two separate names precisely so a host's tool-approval layer (e.g. ele's
  auto-approve-reads-but-confirm-writes policy) can gate on the *name* alone
  without inspecting arguments.

  Handler contract: `handler.(args, host_ctx) -> {:ok, json_string} | {:error, message}`.
  `host_ctx` may carry `:context` (opaque identity for the credential
  resolver, never exposed to the sandbox), `:api_allowlist` (a list of
  registered API names this call may see and address — design §5 step 3,
  gentility's `net_allowed_urls` pattern; absent means all, `[]` means
  none; enforced at the request-dispatch boundary, with the sandbox
  globals filtered to match — but note the tool *descriptions* are built at
  `definitions/1` time and are not allowlist-aware, so a host scoping per
  call should emit per-scope definitions if the description must not name
  the full set), `:req_options` (extra Req
  options, e.g. Req.Test plugs), and `:annotate_call` (a
  `payload -> map()` function run host-side on each intercepted call's
  response payload; its result is merged into that call's log entry, base
  keys winning). The annotator exists because the call log deliberately
  carries no response body: it is how a host records a *host-observed*
  classification of a response — e.g. "this 403 was a step-up refusal, not
  an ordinary denial" — somewhere sandbox code cannot forge or suppress.
  Per-API model-visible values belong in `ApiConfig.sandbox_globals`
  instead.

  M6: the descriptions are a snapshot of registry state at the moment
  `definitions/1` is called. A host that registers, re-registers, or
  unregisters an API afterwards must call `definitions/1` again and re-emit
  the tools — otherwise the model is told about an API surface that no
  longer exists (the handlers themselves re-read the registry per call, so
  they stay correct; only the descriptions go stale).
  """

  require Logger

  alias OapiCodemode.{Proxy, Registry}
  alias OapiCodemode.Tools.{Descriptions, Result}

  @code_schema %{
    "type" => "object",
    "properties" => %{
      "code" => %{"type" => "string", "description" => "JavaScript async arrow function"}
    },
    "required" => ["code"]
  }

  @doc """
  Build the `search_apis` and `execute_api_code` tool definitions.

  See the moduledoc for the accepted `opts` and the handler contract.
  """
  @spec definitions(keyword()) :: [
          %{
            name: String.t(),
            description: String.t(),
            input_schema: map(),
            handler: (map(), map() -> {:ok, String.t()} | {:error, String.t()})
          }
        ]
  def definitions(opts) do
    entries = Registry.list(Keyword.fetch!(opts, :registry))
    policy = Keyword.get(opts, :policy, :read_only)
    search_tool_name = Keyword.get(opts, :search_tool_name, "search_apis")
    execute_tool_name = Keyword.get(opts, :execute_tool_name, "execute_api_code")
    include_search = Keyword.get(opts, :include_search, true)

    # M1: a collision would either register two tools under one name (the
    # host's tool layer overwrites one silently) or, in the two-tool-variant
    # pattern, point the execute description at a tool that's actually
    # itself — either way the model is misled about what to call. This is a
    # config mistake, not a runtime condition, so raise.
    if search_tool_name == execute_tool_name do
      raise ArgumentError,
            "search_tool_name and execute_tool_name must differ " <>
              "(both were #{inspect(search_tool_name)})"
    end

    max_calls = max_calls(opts)

    unless max_calls == :infinity or (is_integer(max_calls) and max_calls > 0) do
      raise ArgumentError,
            ":max_calls must be a positive integer or :infinity, got: #{inspect(max_calls)}"
    end

    search_tools =
      if include_search do
        [
          %{
            name: search_tool_name,
            description: Descriptions.search(entries),
            input_schema: @code_schema,
            handler: fn args, host_ctx -> search(args, host_ctx, opts) end
          }
        ]
      else
        []
      end

    # I2: the execute description names the search tool it expects the model
    # to have used first — a nonexistent one must never be named. If this
    # call emits the search tool, it's always named. If it doesn't, only
    # name it when the host explicitly says (via :search_tool_name) that one
    # exists elsewhere; otherwise the description drops the reference.
    description_search_name =
      cond do
        include_search -> search_tool_name
        Keyword.has_key?(opts, :search_tool_name) -> search_tool_name
        true -> nil
      end

    execute_tool = %{
      name: execute_tool_name,
      description: Descriptions.execute(entries, policy, description_search_name),
      input_schema: @code_schema,
      handler: fn args, host_ctx -> execute(args, host_ctx, opts) end
    }

    search_tools ++ [execute_tool]
  end

  defp search(%{"code" => code}, host_ctx, opts) when is_binary(code) do
    metas =
      opts |> Keyword.fetch!(:registry) |> Registry.sandbox_meta() |> allowed(host_ctx)

    globals = %{"__oapi_specs_json" => specs_json(metas)}

    case run_sandbox(opts, wrap_with_specs(code), %{globals: globals, callbacks: %{}}) do
      {:ok, %{value: value}} -> Result.encode(value, max_tokens(opts))
      {:error, reason} -> {:error, elem(normalize_error(reason), 0)}
    end
  end

  # M5: a model that emits the tool call with no arguments (or a typo'd key)
  # gets a message it can act on rather than a FunctionClauseError crossing
  # into the host's tool loop.
  defp search(_args, _host_ctx, _opts), do: {:error, "missing required argument: code"}

  # I3: the specs reach the sandbox as one pre-encoded JSON string (cached
  # per registration) parsed guest-side — measured 3x cheaper than term
  # conversion for a multi-MB spec. Assembled by splicing the cached
  # per-API JSON; nothing is re-encoded here.
  defp specs_json(metas) do
    IO.iodata_to_binary([
      "{",
      Enum.map_intersperse(metas, ",", fn {name, meta} ->
        [Jason.encode!(name), ":", meta.spec_json]
      end),
      "}"
    ])
  end

  # The model's arrow arrives untouched inside the wrapper; `await` passes
  # sync-arrow return values through unchanged. `specs` is a lexical const
  # the nested arrow closes over — no globalThis, which zapcode forbids in
  # its sandbox.
  defp wrap_with_specs(code) do
    """
    async () => {
      const specs = JSON.parse(__oapi_specs_json);
      return await (#{code})();
    }
    """
  end

  # Design §5 step 3: optional per-call API allowlist from host context
  # (gentility's net_allowed_urls pattern). A malformed allowlist is a host
  # bug, not a model mistake — raise, like the M1 name-collision guard.
  defp allowed(metas, host_ctx) do
    case Map.get(host_ctx, :api_allowlist) do
      nil ->
        metas

      names when is_list(names) ->
        unless Enum.all?(names, &is_binary/1) do
          raise ArgumentError,
                ":api_allowlist must be a list of API name strings, got: #{inspect(names)}"
        end

        Enum.filter(metas, fn {name, _} -> name in names end)

      other ->
        raise ArgumentError,
              ":api_allowlist must be a list of API name strings, got: #{inspect(other)}"
    end
  end

  defp execute(%{"code" => code}, host_ctx, opts) when is_binary(code) do
    registry = Keyword.fetch!(opts, :registry)
    metas = registry |> Registry.sandbox_meta() |> allowed(host_ctx)

    # I1: unlinked, so a late Agent crash can't propagate into the host's
    # caller process, and stopped in an `after` so no execute path — raise,
    # error, timeout — can leak it. State is {reserved_count, entries}:
    # slots are reserved before dispatch so concurrent callbacks (Deno runs
    # them in Tasks) cannot race past :max_calls.
    {:ok, calls} = Agent.start(fn -> {0, []} end)

    try do
      do_execute(code, host_ctx, opts, registry, metas, calls)
    after
      safe_stop(calls)
    end
  end

  defp execute(_args, _host_ctx, _opts), do: {:error, "missing required argument: code"}

  defp do_execute(code, host_ctx, opts, registry, metas, calls) do
    ctx = %{
      resolver: Keyword.fetch!(opts, :resolver),
      context: Map.get(host_ctx, :context, %{}),
      policy: Keyword.get(opts, :policy, :read_only),
      req_options: Map.get(host_ctx, :req_options, [])
    }

    annotate = Map.get(host_ctx, :annotate_call, fn _payload -> %{} end)

    max_calls = max_calls(opts)
    meta_by_name = Map.new(metas)

    request_callback = fn
      api_name, req_opts when is_map(req_opts) ->
        # The key is resolved BEFORE the in_flight record below — an
        # in_flight entry must carry its key, or a killed run loses the one
        # thing that makes its retry safe. A malformed supply is an M4-style
        # shape error: no slot, no log entry.
        case idempotency(meta_by_name[api_name], req_opts) do
          {:error, message} ->
            %{"error" => message}

          {:ok, req_opts, idem_key} ->
            started = System.monotonic_time(:millisecond)
            operation = operation_label(req_opts)

            # ele P1: bound the number of calls per run. The first over-limit
            # attempt is recorded so the operator sees it; further attempts get
            # the error payload WITHOUT a log entry — otherwise refusals would
            # re-open the unbounded call-log growth the limit exists to close.
            case reserve_call(calls, max_calls) do
              :drop ->
                limit_error(max_calls)

              verdict ->
                # ele P1 (round 5): the call is logged BEFORE dispatch as
                # "in_flight" and finalized in place after, so a run that dies
                # mid-call — a wall-clock kill, an executor crash — leaves the
                # indeterminate call visible in the envelope instead of
                # silently omitting a mutation that may have landed. A
                # completed run never shows one: every dispatch that returns
                # replaces its own placeholder.
                ref = make_ref()
                record(calls, ref, in_flight_entry(api_name, operation, idem_key))

                {payload, status} =
                  case verdict do
                    :dispatch -> dispatch(registry, metas, api_name, req_opts, ctx)
                    :record_refusal -> {limit_error(max_calls), :error}
                  end

                # Annotation merges under the base keys: a host classifier adds
                # to an entry, it never rewrites what the library recorded.
                entry =
                  Map.merge(
                    annotate.(payload),
                    %{
                      "api" => api_name,
                      "operation" => operation,
                      "status" => status_label(status),
                      "duration_ms" => System.monotonic_time(:millisecond) - started
                    }
                    |> put_key(idem_key)
                  )

                finalize(calls, ref, entry)

                payload
            end
        end

      # M4: `apis.x.request("GET /pets")` — a shape mistake the model can fix.
      _api_name, _req_opts ->
        %{"error" => "request() expects an options object"}
    end

    globals =
      %{"apiNames" => Enum.map(metas, fn {name, _} -> name end)}
      |> Map.merge(context_globals(metas))

    env = %{globals: globals, callbacks: %{request: request_callback}}

    # I1: on a sandbox error/timeout the call metadata must NOT be
    # discarded — mutations may have landed before the crash, and the
    # design requires the tool result to show what the code actually did.
    # So execute never returns the pre-sandbox {:error, _} shape for a
    # sandbox failure; the failure is surfaced as data in the envelope
    # instead (consistent with how proxy [phase]-tagged errors already
    # surface as data, not as a raised tool error). {:error, _} is
    # reserved for failures before the sandbox ever runs (missing code).
    case run_sandbox(opts, code, env) do
      {:ok, out} ->
        Result.encode(
          envelope(safe_get(calls), out.logs, {"result", out.value}),
          max_tokens(opts)
        )

      {:error, reason} ->
        {message, logs} = normalize_error(reason)
        Result.encode(envelope(safe_get(calls), logs, {"error", message}), max_tokens(opts))
    end
  end

  # M1: explicit key order. Truncation chops the TAIL, so the bounded,
  # high-signal metadata (which calls were made, what the code logged) goes
  # first and the unbounded result/error goes last — losing the tail of a
  # huge result is tolerable; losing the record of what the sandbox
  # actually did upstream is not.
  defp envelope(call_log, logs, {key, value}) do
    %Jason.OrderedObject{values: [{"calls", call_log}, {"logs", logs}, {key, value}]}
  end

  defp dispatch(registry, metas, api_name, req_opts, ctx) do
    names = Enum.map(metas, fn {n, _} -> n end)

    with :ok <- permit(registry, names, api_name),
         {:ok, entry} <- Registry.lookup(registry, api_name),
         {:ok, resp} <- Proxy.request(entry, api_name, req_opts, ctx) do
      {%{"status" => resp.status, "headers" => resp.headers, "body" => resp.body}, resp.status}
    else
      {:error, :unknown_api} ->
        {%{"error" => "unknown API #{inspect(api_name)}. Registered: #{name_list(names)}"},
         :error}

      {:error, :not_permitted} ->
        {%{
           "error" =>
             "API #{inspect(api_name)} is not permitted for this call. " <>
               "Permitted: #{name_list(names)}"
         }, :error}

      {:error, %{phase: phase, message: message}} ->
        {%{"error" => "[#{phase}] #{message}"}, :error}
    end
  end

  # Design §5 step 3: the allowlist guarantee is enforced here, at the
  # dispatch boundary — the globals filtering above only keeps the model
  # from being shown APIs it cannot call. Registered-but-disallowed and
  # unknown are distinct errors: the first is a policy the model must live
  # with, the second a typo it can fix.
  defp permit(registry, names, api_name) do
    cond do
      api_name in names -> :ok
      match?({:ok, _}, Registry.lookup(registry, api_name)) -> {:error, :not_permitted}
      true -> {:error, :unknown_api}
    end
  end

  defp name_list([]), do: "(none)"
  defp name_list(names), do: Enum.join(names, ", ")

  defp max_calls(opts), do: Keyword.get(opts, :max_calls, 100)

  defp reserve_call(_agent, :infinity), do: :dispatch

  defp reserve_call(agent, max) do
    Agent.get_and_update(agent, fn {reserved, entries} ->
      cond do
        reserved < max -> {:dispatch, {reserved + 1, entries}}
        reserved == max -> {:record_refusal, {reserved + 1, entries}}
        true -> {:drop, {reserved, entries}}
      end
    end)
  catch
    :exit, _ -> :drop
  end

  defp limit_error(max) do
    %{
      "error" =>
        "call limit reached: this run has used all #{max} API calls it is " <>
          "allowed. Finish with the data you already have."
    }
  end

  # I1: the executor is expected to cancel outstanding callback work when a
  # run times out (the Deno executor kills the subprocess), but Elixir-side
  # Tasks already in flight can still land here after the Agent is gone.
  # Tolerate that rather than crashing a task nobody is waiting on.
  # Entries are keyed by ref so `finalize/3` can replace a call's
  # "in_flight" placeholder in place; the envelope therefore lists calls
  # in dispatch-start order.
  defp record(agent, ref, entry) do
    Agent.update(agent, fn {reserved, entries} -> {reserved, [{ref, entry} | entries]} end)
  catch
    :exit, _ -> :ok
  end

  defp finalize(agent, ref, entry) do
    Agent.update(agent, fn {reserved, entries} ->
      {reserved,
       Enum.map(entries, fn
         {^ref, _placeholder} -> {ref, entry}
         other -> other
       end)}
    end)
  catch
    :exit, _ -> :ok
  end

  defp in_flight_entry(api_name, operation, idem_key) do
    %{
      "api" => api_name,
      "operation" => operation,
      "status" => "in_flight",
      "note" =>
        "the run ended before this call returned — its outcome is unknown; " <>
          "it may have completed. Verify before retrying."
    }
    |> put_key(idem_key)
  end

  defp put_key(entry, nil), do: entry
  defp put_key(entry, key), do: Map.put(entry, "idempotency_key", key)

  # James (via ele): the model shouldn't have to hand-write idempotency
  # headers. With ApiConfig.auto_idempotency_header set, precedence is
  # explicit idempotencyKey option > explicit headers-map entry > generated
  # UUID (mutating calls only). Whatever key is used is returned for the
  # call log; GET/HEAD are never auto-keyed.
  defp idempotency(meta, req_opts) do
    header = meta && meta.auto_idempotency_header
    {option, req_opts} = Map.pop(req_opts, "idempotencyKey")
    from_headers = header_supplied_key(req_opts, header)

    cond do
      option == nil and from_headers != nil ->
        {:ok, req_opts, from_headers}

      option == nil and header != nil and mutating?(req_opts) ->
        key = generate_key()
        {:ok, put_key_header(req_opts, header, key), key}

      option == nil ->
        {:ok, req_opts, nil}

      header == nil ->
        {:error,
         "idempotencyKey is not supported here: this API has no idempotency header configured"}

      not is_binary(option) ->
        {:error, "idempotencyKey must be a string"}

      from_headers != nil ->
        {:error,
         "provide the idempotency key once — either idempotencyKey or headers[#{inspect(header)}]"}

      true ->
        {:ok, put_key_header(req_opts, header, option), option}
    end
  end

  defp header_supplied_key(_req_opts, nil), do: nil

  defp header_supplied_key(req_opts, header) do
    case Map.get(req_opts, "headers") do
      headers when is_map(headers) ->
        Enum.find_value(headers, fn {name, value} ->
          if is_binary(name) and String.downcase(name) == header, do: value
        end)

      _ ->
        nil
    end
  end

  defp mutating?(req_opts) do
    method = req_opts |> Map.get("method", "GET") |> to_string() |> String.upcase()
    method not in ["GET", "HEAD"]
  end

  defp put_key_header(req_opts, header, key) do
    Map.update(req_opts, "headers", %{header => key}, fn
      headers when is_map(headers) -> Map.put(headers, header, key)
      other -> other
    end)
  end

  defp generate_key do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<a::32, b::16, c::16, d::16, e::48>> = <<u0::48, 4::4, u1::12, 2::2, u2::62>>

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp safe_get(agent) do
    Agent.get(agent, fn {_reserved, entries} ->
      entries |> Enum.reverse() |> Enum.map(fn {_ref, entry} -> entry end)
    end)
  catch
    :exit, _ -> []
  end

  defp safe_stop(agent) do
    Agent.stop(agent)
  catch
    :exit, _ -> :ok
  end

  # I1: an executor that raises must not take the host's tool loop with it —
  # the tool contract is {:ok, json} | {:error, message}, always. Returns
  # the executor's raw {:ok, result} | {:error, reason}; callers decide how
  # to present a sandbox failure (search: as a tool error; execute: as data
  # in the envelope, via `normalize_error/1`).
  defp run_sandbox(opts, code, env) do
    executor = Keyword.fetch!(opts, :executor)
    timeout = Keyword.get(opts, :timeout, 30_000)
    executor_opts = Keyword.get(opts, :executor_opts, [])

    try do
      executor.run(code, env, Keyword.put_new(executor_opts, :timeout, timeout))
    rescue
      e -> {:error, {:raised, Exception.message(e)}}
    end
  end

  # Turns any shape an Executor may return for {:error, reason} into a
  # uniform {message, logs} pair. `%{message: _, logs: _}` is what
  # Deno.ex sends for an in-sandbox crash (the bootstrap's "done" message
  # with an error still carries whatever console.log output happened
  # before the crash) — those logs must reach the caller, not be dropped.
  defp normalize_error({:timeout, ms}), do: {"sandbox timed out after #{ms} ms", []}

  defp normalize_error({:wall_clock, ms}),
    do: {"run exceeded its wall-clock budget of #{ms} ms (host API-call time included)", []}

  # C1 sibling: an executor's own raise is infrastructure failure — its
  # exception text can embed internals and is not model-actionable. Full
  # detail to Logger, fixed string to the envelope. (Guest JS errors take
  # the %{message: ...} clause below and stay verbatim — those the model
  # caused and can fix.)
  defp normalize_error({:raised, message}) do
    Logger.error("oapi_codemode executor raised: #{message}")
    {"sandbox executor error — details in host logs", []}
  end

  defp normalize_error(%{message: message, logs: logs}) when is_list(logs),
    do: {"sandbox error: #{sanitize(message)}", logs}

  defp normalize_error(reason), do: {"sandbox error: #{sanitize(reason)}", []}

  # Error hygiene (the ele formatError lesson): first line only, no file
  # paths or data-URL stack frames. Full detail belongs in host logs.
  defp sanitize(reason) do
    reason
    |> to_string()
    |> String.split("\n")
    |> hd()
    |> String.slice(0, 500)
  rescue
    _ -> inspect(reason) |> String.slice(0, 500)
  end

  defp status_label(:error), do: "error"
  defp status_label(code), do: code

  # Recorded straight from the intercepted request at call time — no
  # re-matching against the operation index (which would need the right
  # HTTP method to match correctly; see plan Task 15 note).
  defp operation_label(req_opts) do
    method = req_opts |> Map.get("method", "GET") |> to_string() |> String.upcase()
    path = Map.get(req_opts, "path", "")
    method <> " " <> path
  end

  defp context_globals(metas) do
    contexts =
      for {name, meta} <- metas, map_size(meta.sandbox_globals) > 0, into: %{} do
        {name, meta.sandbox_globals}
      end

    if map_size(contexts) > 0, do: %{"context" => contexts}, else: %{}
  end

  defp max_tokens(opts), do: Keyword.get(opts, :max_result_tokens, 6000)
end
