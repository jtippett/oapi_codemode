defmodule OapiCodemode.Tools.Descriptions do
  @moduledoc """
  Assembles search/execute tool descriptions from registry state. The
  description IS the documentation — every global the sandbox actually
  receives must be declared here, with real names, or the model has to
  guess at them.
  """

  @max_tags 40

  @doc "Description for the `search_apis` tool, given `Registry.list/1` output."
  @spec search([{String.t(), struct()}]) :: String.t()
  def search(entries) do
    """
    Search the OpenAPI specs of the registered APIs by running JavaScript
    against them. All $refs are pre-resolved inline (circular refs appear as
    {"$circular": "Name"}). Submit an async arrow function; whatever it
    returns is your result. Only what you return enters your context.

    Registered APIs:
    #{Enum.map_join(entries, "\n", &api_line/1)}

    Types:

    interface OperationInfo {
      summary?: string;
      description?: string;
      tags?: string[];
      parameters?: Array<{ name: string; in: string; required?: boolean; schema?: unknown; description?: string }>;
      requestBody?: { required?: boolean; content?: Record<string, { schema?: unknown }> };
      responses?: Record<string, { description?: string; content?: Record<string, { schema?: unknown }> }>;
    }

    interface PathItem {
      get?: OperationInfo; post?: OperationInfo; put?: OperationInfo;
      patch?: OperationInfo; delete?: OperationInfo;
    }

    declare const specs: Record<string, { info: {title: string, description?: string}, paths: Record<string, PathItem> }>;

    Examples:

    // Find operations by keyword across all APIs
    async () => {
      const results = [];
      for (const [apiName, spec] of Object.entries(specs)) {
        for (const [path, methods] of Object.entries(spec.paths)) {
          for (const [method, op] of Object.entries(methods)) {
            const text = `${op.summary ?? ""} ${op.description ?? ""} ${(op.tags ?? []).join(" ")}`.toLowerCase();
            if (text.includes("pet")) results.push({ api: apiName, method: method.toUpperCase(), path, summary: op.summary });
          }
        }
      }
      return results;
    }

    // Get one endpoint's request body schema (refs already resolved)
    async () => specs.petstore.paths["/pets"].post?.requestBody
    """
  end

  @doc "Description for the `execute_api_code` tool, given `Registry.list/1` output."
  @spec execute([{String.t(), struct()}]) :: String.t()
  def execute(entries) do
    """
    Execute JavaScript that calls the registered APIs. First use the search
    tool to find the right operations, then call apis.<name>.request().
    Requests are validated against the spec and credentialed server-side;
    you never handle credentials.

    interface RequestOptions {
      method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
      path: string;                        // e.g. "/pets/42" — path only, no host
      query?: Record<string, unknown>;
      body?: unknown;
      contentType?: string;                // default application/json when body present
      rawBody?: boolean;                   // send body as-is, no JSON.stringify
    }

    interface Response { status: number; headers: Record<string, string>; body: unknown; }

    declare const apis: Record<string, { request(opts: RequestOptions): Promise<Response> }>;
    declare const apiNames: string[];   // names of the registered APIs, same keys as `apis`
    #{context_declaration(entries)}
    Available: #{Enum.map_join(entries, ", ", fn {name, _} -> "apis.#{name}" end)}
    #{context_globals(entries)}

    Your code must be an async arrow function that returns the result.
    Concurrent requests via Promise.all are fine.

    Example:
    async () => {
      const r = await apis.petstore.request({ method: "GET", path: "/pets", query: { limit: 10 } });
      return r.body;
    }
    """
  end

  defp api_line({name, entry}) do
    title = entry.artifact.title || name
    "- specs.#{name} — #{title}. Tags: #{tags(entry.artifact.tags)}"
  end

  defp tags(tags) when length(tags) > @max_tags do
    shown = Enum.take(tags, @max_tags)
    Enum.join(shown, ", ") <> "... (#{length(tags)} total)"
  end

  defp tags(tags), do: Enum.join(tags, ", ")

  # Only declared when some API actually has context — an empty `context`
  # global is not injected, so declaring it would be a lie.
  defp context_declaration(entries) do
    if Enum.any?(entries, fn {_, e} -> map_size(e.config.context) > 0 end) do
      "declare const context: Record<string, Record<string, unknown>>;"
    else
      ""
    end
  end

  # Spell out the real access paths (context.<api>.<key>) with the values
  # the host registered — a model shown only a JSON blob tends to invent
  # `context.storeId` and get `undefined`.
  defp context_globals(entries) do
    lines =
      for {name, entry} <- entries,
          map_size(entry.config.context) > 0,
          {key, value} <- Enum.sort(entry.config.context) do
        "  context.#{name}.#{key} = #{Jason.encode!(value)}"
      end

    case lines do
      [] -> ""
      lines -> "Host-provided context values:\n" <> Enum.join(lines, "\n")
    end
  end
end
