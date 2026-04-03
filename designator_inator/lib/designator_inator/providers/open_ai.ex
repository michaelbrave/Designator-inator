defmodule DesignatorInator.Providers.OpenAI do
  @moduledoc """
  Inference provider for the OpenAI Chat Completions API.

  Also works with OpenAI-compatible endpoints (Together AI, Fireworks, etc.)
  by overriding `:base_url` in opts.

  API key is resolved via `DesignatorInator.Pod.Config.resolve_api_key/2`.
  """

  use DesignatorInator.InferenceProvider

  require Logger

  alias DesignatorInator.Pod.Config
  alias DesignatorInator.Types.Message

  @openai_api_url "https://api.openai.com/v1/chat/completions"

  # ── InferenceProvider callbacks ─────────────────────────────────────────────

  @doc """
  Sends a chat completion request to the OpenAI Chat Completions API.

  ## Options

  - `:model` — model ID (e.g. `"gpt-4o"`, `"gpt-4o-mini"`)
  - `:base_url` — override the API endpoint (for OpenAI-compatible APIs)
  - `:temperature`, `:max_tokens` — standard inference params

  ## Examples

      iex> DesignatorInator.Providers.OpenAI.complete(
      ...>   [%Message{role: :user, content: "What is 2+2?"}],
      ...>   model: "gpt-4o-mini"
      ...> )
      {:ok, "4"}
  """
  @impl DesignatorInator.InferenceProvider
  @spec complete([Message.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts) do
    # Template (HTDP step 4):
    # 1. Resolve API key via DesignatorInator.Config.resolve_api_key(:openai, opts)
    # 2. Resolve base_url from opts or default to @openai_api_url
    # 3. Convert messages using DesignatorInator.Providers.LlamaCpp.messages_to_openai/1
    #    (OpenAI format is the shared wire format — reuse that conversion)
    # 4. Build request body and POST with Authorization: Bearer ***
    # 5. On 200: decode, extract choices[0].message.content
    # 6. On 429: {:error, :rate_limited}
    # 7. Other errors: {:error, {:http_error, status}}
    with {:ok, api_key} <- resolve_api_key(opts),
         {:ok, model} <- fetch_model(opts),
         {:ok, response} <- post_completion(api_key, build_request_body(messages, opts, model), opts) do
      extract_completion_text(response)
    end
  end

  @doc false
  @spec messages_to_openai([Message.t()]) :: [map()]
  def messages_to_openai(messages) do
    DesignatorInator.Providers.LlamaCpp.messages_to_openai(messages)
  end

  defp resolve_api_key(opts) do
    config = Keyword.get(opts, :config, %Config{})
    Config.resolve_api_key(:openai, config)
  end

  defp fetch_model(opts) do
    case Keyword.get(opts, :model) do
      nil -> {:error, :missing_model}
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

  defp post_completion(api_key, body, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:designator_inator, :inference_timeout_ms, 120_000))

    case http_client().post(
           url: Keyword.get(opts, :base_url, @openai_api_url),
           json: body,
           receive_timeout: timeout_ms,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"content-type", "application/json"}
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
