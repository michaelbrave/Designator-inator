defmodule DesignatorInator.Providers.Anthropic do
  @moduledoc """
  Inference provider for the Anthropic Messages API.

  Used as a cloud fallback when local inference is unavailable or insufficient.
  API key is resolved via `DesignatorInator.Config.resolve_api_key/2` — never stored
  in pod directories.

  ## Wire format

  Anthropic's API differs from OpenAI in a few ways:
  - System message is a top-level field, not a message in the array.
  - Tool results use `role: "user"` with a `content` array.
  - Model IDs: `claude-opus-4-5`, `claude-sonnet-4-5`, `claude-haiku-4-5`, etc.

  ## Model name mapping

  DesignatorInator uses short names like `"claude-sonnet"` in pod configs.
  This module maps them to current API model IDs.
  """

  use DesignatorInator.InferenceProvider

  require Logger

  alias DesignatorInator.Types.Message

  @anthropic_api_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"

  # ── InferenceProvider callbacks ─────────────────────────────────────────────

  @doc """
  Sends a chat completion request to the Anthropic Messages API.

  ## Examples

      iex> DesignatorInator.Providers.Anthropic.complete(
      ...>   [
      ...>     %Message{role: :system, content: "You are helpful."},
      ...>     %Message{role: :user,   content: "What is the capital of France?"}
      ...>   ],
      ...>   model: "claude-sonnet"
      ...> )
      {:ok, "The capital of France is Paris."}
  """
  @impl DesignatorInator.InferenceProvider
  @spec complete([Message.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts) do
    # Template (HTDP step 4):
    # 1. Resolve API key via DesignatorInator.Config.resolve_api_key(:anthropic, opts)
    # 2. Separate system message from the rest (Anthropic puts it at top level)
    # 3. Map remaining messages to Anthropic format via messages_to_anthropic/1
    # 4. Build request body: %{model: model_id, max_tokens: ..., system: ..., messages: ...}
    # 5. POST to @anthropic_api_url with headers:
    #    x-api-key, anthropic-version, content-type
    # 6. On 200: decode body, extract content[0].text
    # 7. On 429: return {:error, :rate_limited}
    # 8. On other non-200: return {:error, {:http_error, status, body}}
    raise "not implemented"
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @doc false
  @spec model_id(String.t()) :: String.t()
  def model_id(short_name) do
    # Template:
    # Map short names to current API model IDs.
    # "claude-opus"   -> "claude-opus-4-5"
    # "claude-sonnet" -> "claude-sonnet-4-5"
    # "claude-haiku"  -> "claude-haiku-4-5-20251001"
    # Unrecognized names are passed through unchanged (allow direct model IDs)
    raise "not implemented"
  end

  @doc false
  @spec messages_to_anthropic([Message.t()]) :: [map()]
  def messages_to_anthropic(messages) do
    # Template:
    # Convert :user and :assistant messages to Anthropic format.
    # :tool results become user messages with a content array:
    # %{role: "user", content: [%{type: "tool_result", tool_use_id: id, content: text}]}
    # Filter out :system messages (handled separately as top-level field).
    raise "not implemented"
  end
end
