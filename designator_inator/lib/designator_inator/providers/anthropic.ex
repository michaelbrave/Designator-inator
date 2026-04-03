defmodule DesignatorInator.Providers.Anthropic do
  @moduledoc """
  Inference provider for the Anthropic Messages API.

  Used as a cloud fallback when local inference is unavailable or insufficient.
  API key is resolved via `DesignatorInator.Pod.Config.resolve_api_key/2` — never stored
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

  alias DesignatorInator.Pod.Config
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
      ...>     %Message{role: :user, content: "What is the capital of France?"}
      ...>   ],
      ...>   model: "claude-sonnet"
      ...> )
      {:ok, "The capital of France is Paris."}
  """
  @impl DesignatorInator.InferenceProvider
  @spec complete([Message.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts) do
    # Template (HTDP step 4):
    # 1. Resolve API key via DesignatorInator.Pod.Config.resolve_api_key(:anthropic, opts)
    # 2. Separate system message from the rest (Anthropic puts it at top level)
    # 3. Map remaining messages to Anthropic format via messages_to_anthropic/1
    # 4. Build request body: %{model: model_id, max_tokens: ..., system: ..., messages: ...}
    # 5. POST to @anthropic_api_url with headers:
    #    x-api-key, anthropic-version, content-type
    # 6. On 200: decode body, extract content[0].text
    # 7. On 429: return {:error, :rate_limited}
    # 8. On other non-200: return {:error, {:http_error, status, body}}
    with {:ok, api_key} <- resolve_api_key(opts),
         {:ok, model} <- fetch_model(opts),
         {:ok, response} <- post_completion(api_key, build_request_body(messages, opts, model), opts) do
      extract_completion_text(response)
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @doc false
  @spec model_id(String.t()) :: String.t()
  def model_id(short_name) do
    case short_name do
      "claude-opus" -> "claude-opus-4-5"
      "claude-sonnet" -> "claude-sonnet-4-5"
      "claude-haiku" -> "claude-haiku-4-5-20251001"
      other -> other
    end
  end

  @doc false
  @spec messages_to_anthropic([Message.t()]) :: [map()]
  def messages_to_anthropic(messages) do
    messages
    |> Enum.reject(&(&1.role == :system))
    |> Enum.map(&message_to_anthropic/1)
  end

  defp resolve_api_key(opts) do
    config = Keyword.get(opts, :config, %Config{})
    Config.resolve_api_key(:anthropic, config)
  end

  defp fetch_model(opts) do
    case Keyword.get(opts, :model) do
      nil -> {:error, :missing_model}
      model -> {:ok, model_id(model)}
    end
  end

  defp build_request_body(messages, opts, model) do
    system = Enum.find(messages, fn message -> message.role == :system end)

    body = %{
      "model" => model,
      "max_tokens" => Keyword.get(opts, :max_tokens, 4096),
      "messages" => messages_to_anthropic(messages)
    }

    body =
      case system do
        nil -> body
        %Message{content: content} -> Map.put(body, "system", content)
      end

    case Keyword.fetch(opts, :temperature) do
      {:ok, temperature} -> Map.put(body, "temperature", temperature)
      :error -> body
    end
  end

  defp post_completion(api_key, body, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:designator_inator, :inference_timeout_ms, 120_000))

    case http_client().post(
           url: Keyword.get(opts, :base_url, @anthropic_api_url),
           json: body,
           receive_timeout: timeout_ms,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", @anthropic_version},
             {"content-type", "application/json"}
           ]
         ) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status, nil}}

      {:error, reason} ->
        normalize_http_error(reason)
    end
  end

  defp extract_completion_text(%{"content" => [%{"text" => text} | _]}) when is_binary(text), do: {:ok, text}
  defp extract_completion_text(%{content: [%{text: text} | _]}) when is_binary(text), do: {:ok, text}
  defp extract_completion_text(response) when is_binary(response), do: response |> Jason.decode() |> decode_completion_text()
  defp extract_completion_text(_response), do: {:error, :malformed_response}

  defp decode_completion_text({:ok, decoded}), do: extract_completion_text(decoded)
  defp decode_completion_text(_), do: {:error, :malformed_response}

  defp message_to_anthropic(%Message{role: :user, content: content}), do: %{"role" => "user", "content" => content}

  defp message_to_anthropic(%Message{role: :assistant, content: content, tool_calls: nil}) do
    %{"role" => "assistant", "content" => content}
  end

  defp message_to_anthropic(%Message{role: :assistant, content: content, tool_calls: tool_calls}) do
    %{"role" => "assistant", "content" => content_to_blocks(content) ++ Enum.map(tool_calls, &tool_call_to_anthropic/1)}
  end

  defp message_to_anthropic(%Message{role: :tool, content: content, tool_call_id: tool_call_id}) do
    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => tool_call_id,
          "content" => content
        }
      ]
    }
  end

  defp content_to_blocks(nil), do: []
  defp content_to_blocks(content) when is_binary(content), do: [%{"type" => "text", "text" => content}]
  defp content_to_blocks(content) when is_list(content), do: content
  defp content_to_blocks(content), do: [%{"type" => "text", "text" => to_string(content)}]

  defp tool_call_to_anthropic(tool_call) do
    %{
      "type" => "tool_use",
      "id" => tool_call.id,
      "name" => tool_call.name,
      "input" => tool_call.arguments
    }
  end

  defp normalize_http_error(%Req.TransportError{reason: :timeout}), do: {:error, :timeout}
  defp normalize_http_error(%Req.TransportError{reason: reason}), do: {:error, reason}
  defp normalize_http_error(reason), do: {:error, reason}

  defp http_client do
    Application.get_env(:designator_inator, :http_client, Req)
  end
end
