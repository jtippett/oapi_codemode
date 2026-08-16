defmodule OapiCodemode.Ingest do
  @moduledoc """
  Pure pipeline: raw spec source -> `OapiCodemode.Artifact`.

  Pure by design so that a build-time mix task and runtime registration are
  both thin callers of the same function.
  """

  alias OapiCodemode.{Artifact, Ingest}

  @spec ingest(String.t()) :: {:ok, Artifact.t()} | {:error, term()}
  def ingest(raw) when is_binary(raw) do
    with {:ok, parsed} <- Ingest.Parser.parse(raw) do
      deref = Ingest.Deref.dereference(parsed)
      operations = Ingest.Normalize.operations(deref)

      {:ok,
       %Artifact{
         spec: sandbox_payload(deref),
         operations: operations,
         title: info_map(deref["info"])["title"],
         default_base_url: default_server(deref),
         tags: operations |> Enum.flat_map(& &1.tags) |> Enum.uniq() |> Enum.sort(),
         security_schemes: get_in(deref, ["components", "securitySchemes"]) || %{}
       }}
    end
  end

  defp sandbox_payload(deref) do
    %{
      "info" => Map.take(info_map(deref["info"]), ["title", "description", "version"]),
      "paths" => deref["paths"]
    }
  end

  # Specs in the wild are dirty; tolerate a malformed (non-map) `info` field
  # rather than rejecting the whole spec.
  defp info_map(info) when is_map(info), do: info
  defp info_map(_), do: %{}

  defp default_server(%{"servers" => [%{"url" => url} | _]}), do: url
  defp default_server(_), do: nil
end
