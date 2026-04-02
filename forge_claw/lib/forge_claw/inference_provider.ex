defmodule ForgeClaw.InferenceProvider do
  @moduledoc """
  Behaviour that all inference backends must implement.

  ## Design rationale

  The `ModelManager` routes requests to a provider based on the model name.
  A pod calls `ModelManager.complete/2` and never knows or cares whether the
  underlying backend is a local llama-server, the Anthropic API, or OpenAI.
  This is the abstraction that makes pods portable between local and cloud setups.

  ## Provider selection rules (implemented in ModelManager)

  | Model name prefix | Provider                         |
  |-------------------|----------------------------------|
  | `claude-*`        | `ForgeClaw.Providers.Anthropic`  |
  | `gpt-*`           | `ForgeClaw.Providers.OpenAI`     |
  | anything else     | `ForgeClaw.Providers.LlamaCpp`   |

  ## Implementing a new provider

  1. `use ForgeClaw.InferenceProvider` (gets default implementations)
  2. Implement `complete/2` (required)
  3. Optionally implement `stream/3` for token streaming
  4. Register in `ModelManager.provider_for/1`

  ## Message format

  All providers receive messages as `[ForgeClaw.Types.Message.t()]`.  Providers
  are responsible for converting this to their backend's wire format (e.g.
  OpenAI chat completions JSON, Anthropic messages API JSON).
  """

  alias ForgeClaw.Types.Message

  @doc """
  Sends `messages` to the inference backend and returns the full response text.

  ## Options

  - `:model` — `String.t()` — the model name or ID to use
  - `:temperature` — `float()` in `0.0..2.0` (default `0.7`)
  - `:max_tokens` — `pos_integer()` (default `4096`)
  - `:timeout_ms` — `pos_integer()` override for this call only

  ## Return values

  - `{:ok, response_text}` — the model's text reply
  - `{:error, :timeout}` — request exceeded timeout
  - `{:error, :rate_limited}` — cloud provider returned 429
  - `{:error, {:http_error, status}}` — unexpected HTTP status
  - `{:error, reason}` — other error

  ## Examples

      iex> ForgeClaw.Providers.LlamaCpp.complete(
      ...>   [%Message{role: :user, content: "Hello"}],
      ...>   model: "mistral-7b-instruct-v0.3.Q4_K_M"
      ...> )
      {:ok, "Hello! How can I help you today?"}
  """
  @callback complete([Message.t()], keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Streams tokens from the backend, calling `callback` with each chunk.

  The callback receives `{:token, text}` for each token and `:done` when
  the stream ends.  Useful for interactive CLI sessions.

  Default implementation: calls `complete/2` and delivers the full response
  as a single `:token` event followed by `:done`.

  ## Examples

      ForgeClaw.Providers.LlamaCpp.stream(
        [%Message{role: :user, content: "Tell me a story"}],
        [model: "mistral-7b"],
        fn
          {:token, chunk} -> IO.write(chunk)
          :done -> IO.puts("")
        end
      )
  """
  @callback stream([Message.t()], keyword(), (term() -> any())) :: :ok | {:error, term()}

  @optional_callbacks stream: 3

  defmacro __using__(_opts) do
    quote do
      @behaviour ForgeClaw.InferenceProvider

      @doc """
      Default streaming implementation: completes and delivers as one chunk.
      Override for real token-by-token streaming.
      """
      def stream(messages, opts, callback) do
        case complete(messages, opts) do
          {:ok, text} ->
            callback.({:token, text})
            callback.(:done)
            :ok

          {:error, _} = err ->
            err
        end
      end

      defoverridable stream: 3
    end
  end
end
