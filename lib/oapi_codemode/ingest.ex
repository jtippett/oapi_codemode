defmodule OapiCodemode.Ingest do
  @moduledoc """
  Pure pipeline: raw spec source -> `OapiCodemode.Artifact`.

  Pure by design so that a build-time mix task and runtime registration are
  both thin callers of the same function.
  """

  alias OapiCodemode.{Artifact, Ingest}

  # Cap on the exception message embedded in the `:malformed_spec` error
  # tuple returned by the rescue backstop below. Exception messages can
  # embed `inspect/1` output of the offending value (e.g.
  # `Protocol.UndefinedError`'s "Got value: ..."), and that value may be
  # attacker-controlled spec content, so it must never be returned unbounded.
  @max_error_message_length 500

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
         security_schemes: security_schemes(deref)
       }}
    end
  rescue
    # Backstop, not a substitute for the targeted lenient-ignore guards
    # above and in `Normalize`: those preserve useful partial ingestion by
    # dropping just the malformed field. This exists so that the *next*
    # unaudited crash site on a hostile tenant-uploaded spec downgrades
    # from a raise to an `{:error, _}` tuple instead of taking the caller
    # down. It only catches raises — `with` above returns `{:error, _}`
    # tuples (e.g. from `Parser.parse/1`) without raising, so those are
    # unaffected and pass through untouched.
    e ->
      {:error, {:malformed_spec, truncate_message(Exception.message(e))}}
  end

  defp truncate_message(msg) do
    if String.length(msg) > @max_error_message_length do
      String.slice(msg, 0, @max_error_message_length) <> "... (truncated)"
    else
      msg
    end
  end

  # `components` (and `components.securitySchemes`) can be any wrong-shape
  # JSON value on a tenant-uploaded spec (a string, a list, ...). Lenient-
  # ignore policy: treat anything but a proper map-of-maps as "no security
  # schemes" rather than raising (`get_in/2` raises on a non-map/keyword-list
  # `components`, and a non-map `securitySchemes` would otherwise flow
  # straight into `Artifact.security_schemes`, which callers index with `[]`).
  defp security_schemes(%{"components" => %{"securitySchemes" => schemes}})
       when is_map(schemes),
       do: schemes

  defp security_schemes(_), do: %{}

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
