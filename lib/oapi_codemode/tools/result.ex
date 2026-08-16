defmodule OapiCodemode.Tools.Result do
  @moduledoc """
  JSON-encodes tool results with a budget cap and an instructive trailer.

  Two things this deliberately never does: raise (a result the sandbox
  produced is attacker-shaped data, and a tool handler that raises takes
  the host's tool loop with it), and measure in graphemes (the budget is a
  *byte* budget — see `@bytes_per_token`).
  """

  # The familiar "~4 characters per token" rule of thumb is really a ~4
  # BYTES per token rule: it holds for ASCII-ish JSON and overestimates
  # capacity badly for multibyte text, which is the safe direction. Counting
  # graphemes instead let a CJK result run ~3x past the cap.
  @bytes_per_token 4

  @doc """
  Encode `value` as JSON, truncated to roughly `max_tokens` tokens.

  Returns `{:ok, json}` when the result fits, `{:ok, truncated_json_prefix
  <> trailer}` when it does not (the prefix is deliberately not valid JSON,
  and the trailer says so), or `{:error, reason}` when the value cannot be
  encoded at all.
  """
  @spec encode(term(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def encode(value, max_tokens) do
    case safe_encode(value) do
      {:ok, json} -> {:ok, cap(json, max_tokens)}
      :error -> {:error, "result not JSON-encodable"}
    end
  end

  defp cap(json, max_tokens) do
    max_bytes = max_tokens * @bytes_per_token
    size = byte_size(json)

    if size <= max_bytes do
      json
    else
      truncate_bytes(json, max_bytes) <>
        "\n--- TRUNCATED ---\n" <>
        "Result was ~#{div(size, @bytes_per_token)} tokens (limit: #{max_tokens}). " <>
        "The output above is truncated and not valid JSON. " <>
        "Use more specific queries to reduce result size."
    end
  end

  defp safe_encode(value) do
    {:ok, Jason.encode!(value)}
  rescue
    _ -> :error
  end

  # Cut at the byte budget, then walk back (at most 3 bytes) off any
  # half-written codepoint so the prefix is still a valid string.
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
