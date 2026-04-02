defmodule ForgeClaw.Providers.LlamaCpp do
  @moduledoc """
  Inference provider for local `llama-server` processes (llama.cpp).

  ## Architecture

  Each loaded model gets its own `llama-server` OS process managed via an
  Elixir `Port`.  This is the critical safety decision: if llama-server OOMs
  or segfaults, only this GenServer process dies — the BEAM VM and all other
  pods remain alive.  A NIF would take down the whole VM.

  This module is supervised as a child of `ForgeClaw.ModelManager`.  One
  instance per running model.

                    ModelManager
                         │
            ┌────────────┼────────────┐
            │            │            │
     LlamaCpp            LlamaCpp     LlamaCpp
    (mistral)          (codellama)   (phi-3)
         │                  │             │
       Port               Port           Port
    (OS process)       (OS process)  (OS process)

  ## llama-server API

  llama-server exposes an OpenAI-compatible API at `http://localhost:<port>/v1`.
  We use the `/v1/chat/completions` endpoint.

  ## Key concerns

  - **Port communication**: we use `{:spawn_executable, bin}` with
    `[:exit_status, :use_stdio, :binary]` flags.  We detect process death via
    `handle_info({port, {:exit_status, code}}, state)`.
  - **Health check**: poll `/health` before marking the server ready.
  - **Shutdown**: send SIGTERM, wait up to 5 seconds, then SIGKILL.
  - **Request queuing**: a single GenServer serializes calls, so we never
    overwhelm one llama-server instance.
  """

  use GenServer
  use ForgeClaw.InferenceProvider

  require Logger

  alias ForgeClaw.Types.{Model, Message}

  @health_check_interval_ms 500
  @health_check_max_attempts 20
  @shutdown_grace_ms 5_000

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts a `llama-server` process for the given model.

  ## Options

  - `:port` — HTTP port to bind the server to (required)
  - `:context_size` — context window override (default: model's native size)
  - `:gpu_layers` — number of layers to offload to GPU (default: 99 = all)
  - `:threads` — CPU thread count (default: system core count)

  ## Examples

      iex> ForgeClaw.Providers.LlamaCpp.start_link(
      ...>   model: %Model{path: "/models/mistral.gguf", ...},
      ...>   port: 8080
      ...> )
      {:ok, #PID<0.123.0>}
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Returns `{:ok, port}` when the server is healthy and ready to accept requests.
  Polls until ready or times out.

  ## Examples

      iex> ForgeClaw.Providers.LlamaCpp.await_ready(pid)
      {:ok, 8080}

      # If server fails to start within timeout
      iex> ForgeClaw.Providers.LlamaCpp.await_ready(pid)
      {:error, :timeout}
  """
  @spec await_ready(pid()) :: {:ok, pos_integer()} | {:error, :timeout}
  def await_ready(pid) do
    GenServer.call(pid, :await_ready, 15_000)
  end

  @doc """
  Stops the llama-server process gracefully (SIGTERM then SIGKILL).

  ## Examples

      iex> ForgeClaw.Providers.LlamaCpp.stop(pid)
      :ok
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  # ── InferenceProvider callbacks ─────────────────────────────────────────────

  @doc """
  Sends a chat completion request to the running llama-server instance.

  Converts `ForgeClaw.Types.Message` structs to the OpenAI chat completions
  JSON format, POSTs to `/v1/chat/completions`, and extracts the response text.

  ## Examples

      iex> ForgeClaw.Providers.LlamaCpp.complete(
      ...>   [%Message{role: :user, content: "What is 2+2?"}],
      ...>   model: "mistral-7b-instruct-v0.3.Q4_K_M", temperature: 0.1
      ...> )
      {:ok, "4"}
  """
  @impl ForgeClaw.InferenceProvider
  @spec complete([Message.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts) do
    # Template (HTDP step 4):
    # 1. Resolve the server PID from the model name via ModelManager
    # 2. Build the request body: convert messages to OpenAI format,
    #    merge in opts (temperature, max_tokens, etc.)
    # 3. POST to http://localhost:<port>/v1/chat/completions with Jason.encode!
    # 4. On 200: decode body, extract choices[0].message.content
    # 5. On non-200: return {:error, {:http_error, status}}
    # 6. On timeout: return {:error, :timeout}
    raise "not implemented"
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @doc false
  @spec messages_to_openai([Message.t()]) :: [map()]
  def messages_to_openai(messages) do
    # Template (HTDP step 4):
    # Map each %Message{} to an OpenAI-format map:
    # %{role: "user"|"assistant"|"system"|"tool", content: "..."}
    # For :assistant messages with tool_calls: add "tool_calls" key
    # For :tool messages: add "tool_call_id" key
    raise "not implemented"
  end

  @doc false
  @spec health_check(pos_integer()) :: :ok | {:error, term()}
  def health_check(port) do
    # Template:
    # GET http://localhost:<port>/health
    # Return :ok on 200, {:error, reason} otherwise
    raise "not implemented"
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # Template:
    # 1. Extract model, port, context_size, gpu_layers, threads from opts
    # 2. Build llama-server command: [bin, "-m", model.path, "--port", port, ...]
    # 3. Open Port: Port.open({:spawn_executable, bin}, [:exit_status, :use_stdio, :binary, args: args])
    # 4. Store port handle in state; mark status as :starting
    # 5. Schedule health check via Process.send_after(self(), :health_check, interval)
    # 6. Return {:ok, state}
    raise "not implemented"
  end

  @impl GenServer
  def handle_call(:await_ready, from, state) do
    # Template:
    # If state.status == :ready: reply immediately with {:ok, state.port_number}
    # Else: add `from` to a list of waiters in state
    # When health check succeeds (handle_info :health_check), reply to all waiters
    raise "not implemented"
  end

  @impl GenServer
  def handle_call(:stop, _from, state) do
    # Template:
    # 1. Send SIGTERM to the OS process via Port.command or System.cmd("kill", ...)
    # 2. Schedule a SIGKILL fallback via Process.send_after(self(), :force_kill, grace_ms)
    # 3. Return {:reply, :ok, %{state | status: :stopping}}
    raise "not implemented"
  end

  @impl GenServer
  def handle_info(:health_check, state) do
    # Template:
    # 1. Call health_check(state.port_number)
    # 2. If :ok: mark state as :ready, reply to any waiters
    # 3. If {:error, _} and attempts < max: reschedule health check
    # 4. If attempts exhausted: log error, exit (supervisor will restart)
    raise "not implemented"
  end

  @impl GenServer
  def handle_info({port, {:exit_status, code}}, %{os_port: port} = state) do
    # Template:
    # Log the exit status and reason
    # If state.status == :stopping: normal shutdown, return {:stop, :normal, state}
    # Otherwise: unexpected crash; return {:stop, {:llama_server_crash, code}, state}
    # The supervisor will restart this GenServer, which will relaunch llama-server
    raise "not implemented"
  end
end
