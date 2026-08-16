defmodule OapiCodemode.Tools.Descriptions do
  @moduledoc "Assembles search/execute tool descriptions from registry state. The description IS the documentation."

  @max_tags 40

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

  defp context_globals(entries) do
    lines =
      for {name, entry} <- entries, map_size(entry.config.context) > 0 do
        "Context globals for #{name}: #{Jason.encode!(entry.config.context)}"
      end

    Enum.join(lines, "\n")
  end
end
