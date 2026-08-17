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

  @doc """
  Description for the execute tool, given `Registry.list/1` output.

  `policy` is `:read_only` (default) or `:all`. Under `:all` an extra
  paragraph is appended stating that mutating requests are allowed — a host
  that registers a second, mutating tool variant (via `Tools.definitions/1`
  with `policy: :all` and a distinct `:execute_tool_name`) must not leave
  the model to assume the read-only default's restrictions still apply.

  `search_tool_name` is the name of the paired search tool, named so the
  model pairs the right search with the right execute when a host emits
  several search/execute trios under distinct names — pass `nil` when no
  search tool exists for this execute tool to point to (the description
  then makes no claim that one does).
  """
  @spec execute([{String.t(), struct()}], :read_only | :all, String.t() | nil) :: String.t()
  def execute(entries, policy \\ :read_only, search_tool_name \\ "search_apis") do
    """
    Execute JavaScript that calls the registered APIs. #{intro_sentence(search_tool_name)}
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
    #{policy_paragraph(policy)}
    """
  end

  defp intro_sentence(nil), do: "Call apis.<name>.request() for the operation you need."

  defp intro_sentence(search_tool_name),
    do:
      "First use the `#{search_tool_name}` tool to find the right operations, " <>
        "then call apis.<name>.request()."

  defp policy_paragraph(:all) do
    "\nMutating requests are allowed with this tool: POST, PUT, PATCH, and " <>
      "DELETE requests are permitted in addition to GET, and will be sent " <>
      "to the live API. Use this tool only when the user's request actually " <>
      "requires creating, changing, or deleting data."
  end

  defp policy_paragraph(_read_only), do: ""

  defp api_line({name, entry}) do
    title = entry.artifact.title || name
    "- specs.#{name} — #{title}. Tags: #{tags(entry.artifact.tags)}"
  end

  defp tags(tags) when length(tags) > @max_tags do
    shown = Enum.take(tags, @max_tags)
    Enum.join(shown, ", ") <> "... (#{length(tags)} total)"
  end

  defp tags(tags), do: Enum.join(tags, ", ")

  # Only declared when some API actually has sandbox globals — an empty
  # `context` global is not injected, so declaring it would be a lie.
  defp context_declaration(entries) do
    if Enum.any?(entries, fn {_, e} -> map_size(e.config.sandbox_globals) > 0 end) do
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
          map_size(entry.config.sandbox_globals) > 0,
          {key, value} <- Enum.sort(entry.config.sandbox_globals) do
        "  context.#{name}.#{key} = #{Jason.encode!(value)}"
      end

    case lines do
      [] -> ""
      lines -> "Host-provided context values:\n" <> Enum.join(lines, "\n")
    end
  end
end
