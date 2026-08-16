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

  Handler contract: `handler.(args, host_ctx) -> {:ok, json_string} | {:error, message}`.
  `host_ctx` may carry `:context` (opaque identity for the credential
  resolver) and `:req_options` (extra Req options, e.g. Req.Test plugs).

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

    [
      %{
        name: "search_apis",
        description: Descriptions.search(entries),
        input_schema: @code_schema,
        handler: fn args, host_ctx -> search(args, host_ctx, opts) end
      },
      %{
        name: "execute_api_code",
        description: Descriptions.execute(entries),
        input_schema: @code_schema,
        handler: fn args, host_ctx -> execute(args, host_ctx, opts) end
      }
    ]
  end

  defp search(%{"code" => code}, _host_ctx, opts) when is_binary(code) do
    entries = Registry.list(Keyword.fetch!(opts, :registry))
    globals = %{"specs" => Map.new(entries, fn {name, e} -> {name, e.artifact.spec} end)}

    run(opts, code, %{globals: globals, callbacks: %{}}, fn %{value: value} ->
      Result.encode(value, max_tokens(opts))
    end)
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

    run(opts, code, %{globals: globals, callbacks: %{request: request_callback}}, fn out ->
      Result.encode(envelope(out, safe_get(calls)), max_tokens(opts))
    end)
  end

  # M1: explicit key order. Truncation chops the TAIL, so the bounded,
  # high-signal metadata (which calls were made, what the code logged) goes
  # first and the unbounded result goes last — losing the tail of a huge
  # result is tolerable; losing the record of what the sandbox actually did
  # upstream is not.
  defp envelope(out, call_log) do
    %Jason.OrderedObject{
      values: [{"calls", call_log}, {"logs", out.logs}, {"result", out.value}]
    }
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

  defp run(opts, code, env, on_ok) do
    executor = Keyword.fetch!(opts, :executor)
    timeout = Keyword.get(opts, :timeout, 30_000)

    # I1: an executor that raises must not take the host's tool loop with
    # it; the tool contract is {:ok, json} | {:error, message}, always.
    result =
      try do
        executor.run(code, env, timeout: timeout)
      rescue
        e -> {:error, {:raised, Exception.message(e)}}
      end

    case result do
      {:ok, out} -> on_ok.(out)
      {:error, {:timeout, ms}} -> {:error, "sandbox timed out after #{ms} ms"}
      {:error, {:raised, message}} -> {:error, "sandbox error: #{sanitize(message)}"}
      {:error, reason} -> {:error, "sandbox error: #{sanitize(reason)}"}
    end
  end

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
      for {name, entry} <- entries, map_size(entry.config.context) > 0, into: %{} do
        {name, entry.config.context}
      end

    if map_size(contexts) > 0, do: %{"context" => contexts}, else: %{}
  end

  defp max_tokens(opts), do: Keyword.get(opts, :max_result_tokens, 6000)
end
