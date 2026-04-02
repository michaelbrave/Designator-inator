defmodule ForgeClaw.Providers.OpenAI do
  @moduledoc """
  Inference provider for the OpenAI Chat Completions API.

  Also works with OpenAI-compatible endpoints (Together AI, Fireworks, etc.)
  by overriding `:base_url` in opts.

  API key is resolved via `ForgeClaw.Config.resolve_api_key/2`.
  """

  use ForgeClaw.InferenceProvider

  require Logger

  alias ForgeClaw.Types.Message

  @openai_api_url "https://api.openai.com/v1/chat/completions"

  # ── InferenceProvider callbacks ─────────────────────────────────────────────

  @doc """
  Sends a chat completion request to the OpenAI Chat Completions API.

  ## Options

  - `:model` — model ID (e.g. `"gpt-4o"`, `"gpt-4o-mini"`)
  - `:base_url` — override the API endpoint (for OpenAI-compatible APIs)
  - `:temperature`, `:max_tokens` — standard inference params

  ## Examples

      iex> ForgeClaw.Providers.OpenAI.complete(
      ...>   [%Message{role: :user, content: "What is 2+2?"}],
      ...>   model: "gpt-4o-mini"
      ...> )
      {:ok, "4"}
  """
  @impl ForgeClaw.InferenceProvider
  @spec complete([Message.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts) do
    # Template (HTDP step 4):
    # 1. Resolve API key via ForgeClaw.Config.resolve_api_key(:openai, opts)
    # 2. Resolve base_url from opts or default to @openai_api_url
    # 3. Convert messages using ForgeClaw.Providers.LlamaCpp.messages_to_openai/1
    #    (OpenAI format is the shared wire format — reuse that conversion)
    # 4. Build request body and POST with Authorization: Bearer <key>
    # 5. On 200: decode, extract choices[0].message.content
    # 6. On 429: {:error, :rate_limited}
    # 7. Other errors: {:error, {:http_error, status}}
    raise "not implemented"
  end
end
