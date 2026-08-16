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

  defp search(%{"code" => code}, _host_ctx, opts) do
    entries = Registry.list(Keyword.fetch!(opts, :registry))
    globals = %{"specs" => Map.new(entries, fn {name, e} -> {name, e.artifact.spec} end)}

    run(opts, code, %{globals: globals, callbacks: %{}}, fn %{value: value} ->
      Result.encode(value, max_tokens(opts))
    end)
  end

  defp execute(%{"code" => code}, host_ctx, opts) do
    registry = Keyword.fetch!(opts, :registry)
    entries = Registry.list(registry)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    ctx = %{
      resolver: Keyword.fetch!(opts, :resolver),
      context: Map.get(host_ctx, :context, %{}),
      policy: Keyword.get(opts, :policy, :read_only),
      req_options: Map.get(host_ctx, :req_options, [])
    }

    request_callback = fn api_name, req_opts ->
      started = System.monotonic_time(:millisecond)
      operation = operation_label(req_opts)

      {payload, status} =
        with {:ok, entry} <- Registry.lookup(registry, api_name),
             {:ok, resp} <- Proxy.request(entry, api_name, req_opts, ctx) do
          {%{"status" => resp.status, "headers" => Map.new(resp.headers), "body" => resp.body},
           resp.status}
        else
          {:error, :unknown_api} ->
            known = Enum.map_join(entries, ", ", fn {n, _} -> n end)
            {%{"error" => "unknown API #{inspect(api_name)}. Registered: #{known}"}, :error}

          {:error, %{phase: phase, message: message}} ->
            {%{"error" => "[#{phase}] #{message}"}, :error}
        end

      Agent.update(calls, fn acc ->
        [
          %{
            "api" => api_name,
            "operation" => operation,
            "status" => status_label(status),
            "duration_ms" => System.monotonic_time(:millisecond) - started
          }
          | acc
        ]
      end)

      payload
    end

    globals =
      %{"apiNames" => Enum.map(entries, fn {name, _} -> name end)}
      |> Map.merge(context_globals(entries))

    result =
      run(opts, code, %{globals: globals, callbacks: %{request: request_callback}}, fn out ->
        call_log = calls |> Agent.get(&Enum.reverse/1)

        Result.encode(
          %{"result" => out.value, "logs" => out.logs, "calls" => call_log},
          max_tokens(opts)
        )
      end)

    Agent.stop(calls)
    result
  end

  defp run(opts, code, env, on_ok) do
    executor = Keyword.fetch!(opts, :executor)
    timeout = Keyword.get(opts, :timeout, 30_000)

    case executor.run(code, env, timeout: timeout) do
      {:ok, out} -> on_ok.(out)
      {:error, {:timeout, ms}} -> {:error, "sandbox timed out after #{ms} ms"}
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
