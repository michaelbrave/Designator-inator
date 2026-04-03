defmodule DesignatorInator.Providers.LlamaCpp do
  @moduledoc """
  Inference provider for local `llama-server` processes (llama.cpp).

  ## Architecture

  Each loaded model gets its own `llama-server` OS process managed via an
  Elixir `Port`.  This is the critical safety decision: if llama-server OOMs
  or segfaults, only this GenServer process dies — the BEAM VM and all other
  pods remain alive.  A NIF would take down the whole VM.

  This module is supervised as a child of `DesignatorInator.ModelManager`.  One
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
  use DesignatorInator.InferenceProvider

  require Logger

  alias DesignatorInator.Types.Message

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

      iex> DesignatorInator.Providers.LlamaCpp.start_link(
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

      iex> DesignatorInator.Providers.LlamaCpp.await_ready(pid)
      {:ok, 8080}

      # If server fails to start within timeout
      iex> DesignatorInator.Providers.LlamaCpp.await_ready(pid)
      {:error, :timeout}
  """
  @spec await_ready(pid()) :: {:ok, pos_integer()} | {:error, :timeout}
  def await_ready(pid) do
    timeout_ms = Application.get_env(:designator_inator, :llama_ready_timeout_ms, 15_000)
    GenServer.call(pid, :await_ready, timeout_ms)
  end

  @doc """
  Stops the llama-server process gracefully (SIGTERM then SIGKILL).

  ## Examples

      iex> DesignatorInator.Providers.LlamaCpp.stop(pid)
      :ok
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  # ── InferenceProvider callbacks ─────────────────────────────────────────────

  @doc """
  Sends a chat completion request to the running llama-server instance.

  Converts `DesignatorInator.Types.Message` structs to the OpenAI chat completions
  JSON format, POSTs to `/v1/chat/completions`, and extracts the response text.

  ## Examples

      iex> DesignatorInator.Providers.LlamaCpp.complete(
      ...>   [%Message{role: :user, content: "What is 2+2?"}],
      ...>   model: "mistral-7b-instruct-v0.3.Q4_K_M", temperature: 0.1
      ...> )
      {:ok, "4"}
  """
  @impl DesignatorInator.InferenceProvider
  @spec complete([Message.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts) do
    with {:ok, port_number} <- resolve_port(opts),
         {:ok, response} <- post_completion(port_number, messages, opts) do
      extract_completion_text(response)
    end

    # Was:
    # Template (HTDP step 4):
    # 1. Resolve the server PID from the model name via ModelManager
    # 2. Build the request body: convert messages to OpenAI format,
    #    merge in opts (temperature, max_tokens, etc.)
    # 3. POST to http://localhost:<port>/v1/chat/completions with Jason.encode!
    # 4. On 200: decode body, extract choices[0].message.content
    # 5. On non-200: return {:error, {:http_error, status}}
    # 6. On timeout: return {:error, :timeout}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @doc false
  @spec messages_to_openai([Message.t()]) :: [map()]
  def messages_to_openai(messages) do
    Enum.map(messages, &message_to_openai/1)

    # Was:
    # Template (HTDP step 4):
    # Map each %Message{} to an OpenAI-format map:
    # %{role: "user"|"assistant"|"system"|"tool", content: "..."}
    # For :assistant messages with tool_calls: add "tool_calls" key
    # For :tool messages: add "tool_call_id" key
  end

  @doc false
  @spec health_check(pos_integer()) :: :ok | {:error, term()}
  def health_check(port) do
    case http_client().get(url: "http://127.0.0.1:#{port}/health") do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> normalize_http_error(reason)
    end

    # Was:
    # Template:
    # GET http://localhost:<port>/health
    # Return :ok on 200, {:error, reason} otherwise
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    model = Keyword.fetch!(opts, :model)
    port_number = Keyword.fetch!(opts, :port)
    context_size = Keyword.get(opts, :context_size, model.context_length)
    gpu_layers = Keyword.get(opts, :gpu_layers, 99)
    threads = Keyword.get(opts, :threads, System.schedulers_online())
    executable = Keyword.get(opts, :bin, llama_server_bin())
    args = build_llama_args(model, port_number, context_size, gpu_layers, threads)
    os_port = port_opener().({:spawn_executable, executable}, port_options(args))
    os_pid = extract_os_pid(os_port)

    state = %{
      model: model,
      port_number: port_number,
      context_size: context_size,
      gpu_layers: gpu_layers,
      threads: threads,
      os_port: os_port,
      os_pid: os_pid,
      status: :starting,
      waiters: [],
      health_attempts: 0
    }

    Process.send_after(self(), :health_check, @health_check_interval_ms)
    {:ok, state}

    # Was:
    # Template:
    # 1. Extract model, port, context_size, gpu_layers, threads from opts
    # 2. Build llama-server command: [bin, "-m", model.path, "--port", port, ...]
    # 3. Open Port: Port.open({:spawn_executable, bin}, [:exit_status, :use_stdio, :binary, args: args])
    # 4. Store port handle in state; mark status as :starting
    # 5. Schedule health check via Process.send_after(self(), :health_check, interval)
    # 6. Return {:ok, state}
  end

  @impl GenServer
  def handle_call(:await_ready, from, state) do
    case state.status do
      :ready ->
        {:reply, {:ok, state.port_number}, state}

      _ ->
        {:noreply, %{state | waiters: [from | state.waiters]}}
    end

    # Was:
    # Template:
    # If state.status == :ready: reply immediately with {:ok, state.port_number}
    # Else: add `from` to a list of waiters in state
    # When health check succeeds (handle_info :health_check), reply to all waiters
  end

  @impl GenServer
  def handle_call(:stop, _from, state) do
    kill_os_process(state.os_pid, "-TERM")
    Process.send_after(self(), :force_kill, @shutdown_grace_ms)
    {:reply, :ok, %{state | status: :stopping}}

    # Was:
    # Template:
    # 1. Send SIGTERM to the OS process via Port.command or System.cmd("kill", ...)
    # 2. Schedule a SIGKILL fallback via Process.send_after(self(), :force_kill, grace_ms)
    # 3. Return {:reply, :ok, %{state | status: :stopping}}
  end

  @impl GenServer
  def handle_info(:health_check, state) do
    case health_check(state.port_number) do
      :ok ->
        Enum.each(state.waiters, &GenServer.reply(&1, {:ok, state.port_number}))
        {:noreply, %{state | status: :ready, waiters: [], health_attempts: state.health_attempts + 1}}

      {:error, reason} ->
        attempts = state.health_attempts + 1

        if attempts < @health_check_max_attempts do
          Process.send_after(self(), :health_check, @health_check_interval_ms)
          {:noreply, %{state | health_attempts: attempts}}
        else
          Logger.error("llama-server failed health checks on port #{state.port_number}: #{inspect(reason)}")
          Enum.each(state.waiters, &GenServer.reply(&1, {:error, :timeout}))
          {:stop, {:health_check_failed, reason}, %{state | waiters: [], health_attempts: attempts}}
        end
    end

    # Was:
    # Template:
    # 1. Call health_check(state.port_number)
    # 2. If :ok: mark state as :ready, reply to any waiters
    # 3. If {:error, _} and attempts < max: reschedule health check
    # 4. If attempts exhausted: log error, exit (supervisor will restart)
  end

  @impl GenServer
  def handle_info({port, {:exit_status, code}}, %{os_port: port} = state) do
    Logger.info("llama-server exited on port #{state.port_number} with status #{code}")

    case state.status do
      :stopping ->
        {:stop, :normal, state}

      _ ->
        Enum.each(state.waiters, &GenServer.reply(&1, {:error, :timeout}))
        {:stop, {:llama_server_crash, code}, %{state | waiters: []}}
    end

    # Was:
    # Template:
    # Log the exit status and reason
    # If state.status == :stopping: normal shutdown, return {:stop, :normal, state}
    # Otherwise: unexpected crash; return {:stop, {:llama_server_crash, code}, state}
    # The supervisor will restart this GenServer, which will relaunch llama-server
  end

  @impl GenServer
  def handle_info({port, {:data, _data}}, %{os_port: port} = state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:force_kill, %{status: :stopping} = state) do
    kill_os_process(state.os_pid, "-KILL")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:force_kill, state) do
    {:noreply, state}
  end

  defp resolve_port(opts) do
    case Keyword.get(opts, :port) do
      port_number when is_integer(port_number) and port_number > 0 ->
        {:ok, port_number}

      _ ->
        resolve_port_from_model(Keyword.get(opts, :model))
    end
  end

  defp resolve_port_from_model(nil), do: {:error, :missing_port}

  defp resolve_port_from_model(model_name) do
    model_manager_pid = Process.whereis(DesignatorInator.ModelManager)

    cond do
      is_nil(model_manager_pid) ->
        {:error, :missing_port}

      model_manager_pid == self() ->
        {:error, :missing_port}

      true ->
        case Enum.find(DesignatorInator.ModelManager.list_loaded(), &(&1.model.name == model_name)) do
          nil -> {:error, :missing_port}
          loaded_model -> {:ok, loaded_model.port_number}
        end
    end
  end

  defp post_completion(port_number, messages, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:designator_inator, :inference_timeout_ms, 120_000))

    body = %{
      "messages" => messages_to_openai(messages),
      "temperature" => Keyword.get(opts, :temperature, 0.7),
      "max_tokens" => Keyword.get(opts, :max_tokens, 4096),
      "stream" => false
    }

    case http_client().post(
           url: "http://127.0.0.1:#{port_number}/v1/chat/completions",
           json: body,
           receive_timeout: timeout_ms
         ) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        normalize_http_error(reason)
    end
  end

  defp extract_completion_text(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    {:ok, content}
  end

  defp extract_completion_text(%{choices: [%{message: %{content: content}} | _]})
       when is_binary(content) do
    {:ok, content}
  end

  defp extract_completion_text(_response), do: {:error, :malformed_response}

  defp message_to_openai(%Message{role: role, content: content, tool_calls: tool_calls, tool_call_id: tool_call_id}) do
    %{"role" => Atom.to_string(role), "content" => content}
    |> maybe_put_tool_calls(tool_calls)
    |> maybe_put_tool_call_id(tool_call_id)
  end

  defp maybe_put_tool_calls(message, nil), do: message

  defp maybe_put_tool_calls(message, tool_calls) do
    Map.put(message, "tool_calls", Enum.map(tool_calls, &tool_call_to_openai/1))
  end

  defp maybe_put_tool_call_id(message, nil), do: message
  defp maybe_put_tool_call_id(message, tool_call_id), do: Map.put(message, "tool_call_id", tool_call_id)

  defp tool_call_to_openai(tool_call) do
    %{
      "id" => tool_call.id,
      "type" => "function",
      "function" => %{
        "name" => tool_call.name,
        "arguments" => Jason.encode!(tool_call.arguments)
      }
    }
  end

  defp build_llama_args(model, port_number, context_size, gpu_layers, threads) do
    [
      "-m",
      model.path,
      "--port",
      Integer.to_string(port_number),
      "--ctx-size",
      Integer.to_string(max(context_size, 0)),
      "--gpu-layers",
      Integer.to_string(gpu_layers),
      "--threads",
      Integer.to_string(threads)
    ]
  end

  defp port_options(args) do
    [:exit_status, :use_stdio, :binary, :hide, args: args]
  end

  defp extract_os_pid(os_port) do
    case Port.info(os_port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  end

  defp kill_os_process(nil, _signal) do
    :ok
  end

  defp kill_os_process(os_pid, signal) do
    case kill_runner().(signal, os_pid) do
      {_output, 0} -> :ok
      {_output, _status} -> :ok
    end
  end

  defp normalize_http_error(%Req.TransportError{reason: :timeout}), do: {:error, :timeout}
  defp normalize_http_error(%Req.TransportError{reason: reason}), do: {:error, reason}
  defp normalize_http_error(reason), do: {:error, reason}

  defp http_client do
    Application.get_env(:designator_inator, :http_client, Req)
  end

  defp port_opener do
    Application.get_env(:designator_inator, :llama_port_opener, &Port.open/2)
  end

  defp kill_runner do
    Application.get_env(:designator_inator, :llama_kill_runner, fn signal, os_pid ->
      System.cmd("kill", [signal, Integer.to_string(os_pid)])
    end)
  end

  defp llama_server_bin do
    Application.get_env(:designator_inator, :llama_server_bin, "llama-server")
  end
end
