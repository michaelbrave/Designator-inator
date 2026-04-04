defmodule DesignatorInator.Providers.OpenRouter do
  @moduledoc """
  Inference provider for the OpenRouter API.

  OpenRouter is an OpenAI-compatible endpoint that aggregates hundreds of models
  (open-source and frontier) under a single API key. Use it as a fallback when
  local VRAM is exhausted or as a primary cloud provider.

  Model IDs use the format `openrouter/<provider>/<model>`, e.g.:
    - `openrouter/meta-llama/llama-3.1-8b-instruct`
    - `openrouter/anthropic/claude-3-haiku`
    - `openrouter/mistralai/mistral-7b-instruct`

  The `openrouter/` prefix is stripped before sending to the API.

  API key is resolved via `DesignatorInator.Pod.Config.resolve_api_key/2`.
  Set `OPENROUTER_API_KEY` in your environment, or reference it in `config.yaml`:

      providers:
        openrouter:
          api_key_env: OPENROUTER_API_KEY
  """

  use DesignatorInator.InferenceProvider

  require Logger

  alias DesignatorInator.Pod.Config
  alias DesignatorInator.Types.Message

  @openrouter_api_url "https://openrouter.ai/api/v1/chat/completions"

  # ── InferenceProvider callbacks ─────────────────────────────────────────────

  @doc """
  Sends a chat completion request to the OpenRouter API.

  ## Options

  - `:model` — model ID with `openrouter/` prefix (e.g. `"openrouter/meta-llama/llama-3.1-8b-instruct"`)
  - `:temperature`, `:max_tokens` — standard inference params
  - `:config` — `%Pod.Config{}` for API key resolution

  ## Examples

      iex> DesignatorInator.Providers.OpenRouter.complete(
      ...>   [%Message{role: :user, content: "What is 2+2?"}],
      ...>   model: "openrouter/meta-llama/llama-3.1-8b-instruct"
      ...> )
      {:ok, "4"}
  """
  @impl DesignatorInator.InferenceProvider
  @spec complete([Message.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts) do
    with {:ok, api_key} <- resolve_api_key(opts),
         {:ok, model} <- fetch_model(opts),
         {:ok, response} <- post_completion(api_key, build_request_body(messages, opts, model)) do
      extract_completion_text(response)
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp resolve_api_key(opts) do
    config = Keyword.get(opts, :config, %Config{})
    Config.resolve_api_key(:openrouter, config)
  end

  defp fetch_model(opts) do
    case Keyword.get(opts, :model) do
      nil -> {:error, :missing_model}
      "openrouter/" <> model_id -> {:ok, model_id}
      model -> {:ok, model}
    end
  end

  defp build_request_body(messages, opts, model) do
    body = %{
      "model" => model,
      "messages" => messages_to_openai(messages),
      "stream" => false
    }

    body =
      case Keyword.fetch(opts, :temperature) do
        {:ok, temperature} -> Map.put(body, "temperature", temperature)
        :error -> body
      end

    case Keyword.fetch(opts, :max_tokens) do
      {:ok, max_tokens} -> Map.put(body, "max_tokens", max_tokens)
      :error -> body
    end
  end

  defp post_completion(api_key, body) do
    timeout_ms = Application.get_env(:designator_inator, :inference_timeout_ms, 120_000)

    case http_client().post(
           url: @openrouter_api_url,
           json: body,
           receive_timeout: timeout_ms,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"content-type", "application/json"},
             {"http-referer", "https://github.com/designator-inator"},
             {"x-title", "Designator-inator"}
           ]
         ) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        normalize_http_error(reason)
    end
  end

  defp messages_to_openai(messages) do
    DesignatorInator.Providers.LlamaCpp.messages_to_openai(messages)
  end

  defp extract_completion_text(%{"choices" => [%{"message" => %{"content" => content}} | _]}) when is_binary(content), do: {:ok, content}
  defp extract_completion_text(%{choices: [%{message: %{content: content}} | _]}) when is_binary(content), do: {:ok, content}
  defp extract_completion_text(response) when is_binary(response), do: response |> Jason.decode() |> decode_completion_text()
  defp extract_completion_text(_response), do: {:error, :malformed_response}

  defp decode_completion_text({:ok, decoded}), do: extract_completion_text(decoded)
  defp decode_completion_text(_), do: {:error, :malformed_response}

  defp normalize_http_error(%Req.TransportError{reason: :timeout}), do: {:error, :timeout}
  defp normalize_http_error(%Req.TransportError{reason: reason}), do: {:error, reason}
  defp normalize_http_error(reason), do: {:error, reason}

  defp http_client do
    Application.get_env(:designator_inator, :http_client, Req)
  end
end
