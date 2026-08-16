defmodule OapiCodemode.Tools.Result do
  @moduledoc "JSON-encodes tool results with a token-measured cap and instructive trailer."

  # ~4 chars per token is close enough for a budget cap.
  @chars_per_token 4

  def encode(value, max_tokens) do
    json = Jason.encode!(value)
    max_chars = max_tokens * @chars_per_token

    if String.length(json) <= max_chars do
      {:ok, json}
    else
      approx = div(String.length(json), @chars_per_token)

      {:ok,
       String.slice(json, 0, max_chars) <>
         "\n--- TRUNCATED ---\n" <>
         "Result was ~#{approx} tokens (limit: #{max_tokens}). " <>
         "Use more specific queries to reduce result size."}
    end
  end
end
