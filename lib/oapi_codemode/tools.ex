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
    * `:timeout` — sandbox timeout ms, default 30_000
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
  resolver, never exposed to the sandbox) and `:req_options` (extra Req
  options, e.g. Req.Test plugs). Per-API model-visible values belong in
  `ApiConfig.sandbox_globals` instead.

  M6: the descriptions are a snapshot of registry state at the moment
  `definitions/1` is called. A host that registers, re-registers, or
  unregisters an API afterwards must call `definitions/1` again and re-emit
  the tools — otherwise the model is told about an API surface that no
  longer exists (the handlers themselves re-read the registry per call, so
  they stay correct; only the descriptions go stale).
  """

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

  defp search(%{"code" => code}, _host_ctx, opts) when is_binary(code) do
    entries = Registry.list(Keyword.fetch!(opts, :registry))
    globals = %{"specs" => Map.new(entries, fn {name, e} -> {name, e.artifact.spec} end)}

    case run_sandbox(opts, code, %{globals: globals, callbacks: %{}}) do
      {:ok, %{value: value}} -> Result.encode(value, max_tokens(opts))
      {:error, reason} -> {:error, elem(normalize_error(reason), 0)}
    end
  end

  # M5: a model that emits the tool call with no arguments (or a typo'd key)
  # gets a message it can act on rather than a FunctionClauseError crossing
  # into the host's tool loop.
  defp search(_args, _host_ctx, _opts), do: {:error, "missing required argument: code"}

  defp execute(%{"code" => code}, host_ctx, opts) when is_binary(code) do
    registry = Keyword.fetch!(opts, :registry)
    entries = Registry.list(registry)

    # I1: unlinked, so a late Agent crash can't propagate into the host's
    # caller process, and stopped in an `after` so no execute path — raise,
    # error, timeout — can leak it.
    {:ok, calls} = Agent.start(fn -> [] end)

    try do
      do_execute(code, host_ctx, opts, registry, entries, calls)
    after
      safe_stop(calls)
    end
  end

  defp execute(_args, _host_ctx, _opts), do: {:error, "missing required argument: code"}

  defp do_execute(code, host_ctx, opts, registry, entries, calls) do
    ctx = %{
      resolver: Keyword.fetch!(opts, :resolver),
      context: Map.get(host_ctx, :context, %{}),
      policy: Keyword.get(opts, :policy, :read_only),
      req_options: Map.get(host_ctx, :req_options, [])
    }

    request_callback = fn
      api_name, req_opts when is_map(req_opts) ->
        started = System.monotonic_time(:millisecond)
        operation = operation_label(req_opts)

        {payload, status} = dispatch(registry, entries, api_name, req_opts, ctx)

        record(calls, %{
          "api" => api_name,
          "operation" => operation,
          "status" => status_label(status),
          "duration_ms" => System.monotonic_time(:millisecond) - started
        })

        payload

      # M4: `apis.x.request("GET /pets")` — a shape mistake the model can fix.
      _api_name, _req_opts ->
        %{"error" => "request() expects an options object"}
    end

    globals =
      %{"apiNames" => Enum.map(entries, fn {name, _} -> name end)}
      |> Map.merge(context_globals(entries))

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

  defp dispatch(registry, entries, api_name, req_opts, ctx) do
    with {:ok, entry} <- Registry.lookup(registry, api_name),
         {:ok, resp} <- Proxy.request(entry, api_name, req_opts, ctx) do
      {%{"status" => resp.status, "headers" => resp.headers, "body" => resp.body}, resp.status}
    else
      {:error, :unknown_api} ->
        known = Enum.map_join(entries, ", ", fn {n, _} -> n end)
        {%{"error" => "unknown API #{inspect(api_name)}. Registered: #{known}"}, :error}

      {:error, %{phase: phase, message: message}} ->
        {%{"error" => "[#{phase}] #{message}"}, :error}
    end
  end

  # I1: the executor is expected to cancel outstanding callback work when a
  # run times out (the Deno executor kills the subprocess), but Elixir-side
  # Tasks already in flight can still land here after the Agent is gone.
  # Tolerate that rather than crashing a task nobody is waiting on.
  defp record(agent, entry) do
    Agent.update(agent, &[entry | &1])
  catch
    :exit, _ -> :ok
  end

  defp safe_get(agent) do
    Agent.get(agent, &Enum.reverse/1)
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

    try do
      executor.run(code, env, timeout: timeout)
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
  defp normalize_error({:raised, message}), do: {"sandbox error: #{sanitize(message)}", []}

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

  defp context_globals(entries) do
    contexts =
      for {name, entry} <- entries, map_size(entry.config.sandbox_globals) > 0, into: %{} do
        {name, entry.config.sandbox_globals}
      end

    if map_size(contexts) > 0, do: %{"context" => contexts}, else: %{}
  end

  defp max_tokens(opts), do: Keyword.get(opts, :max_result_tokens, 6000)
end
