defmodule DesignatorInator.Pod do
  @moduledoc """
  GenServer representing one running agent pod.

  ## Lifecycle (HTDP step 1)

  A pod goes through these states (see `DesignatorInator.Types.PodState.pod_status`):

      :loading → :idle ⟷ :running → :stopping → (terminated)
                    ↘ :error (supervisor restarts → back to :loading)

  ## Starting a pod

  Pods are started by `DesignatorInator.PodSupervisor.start_pod/1`, not directly.
  The supervisor provides fault isolation: if a pod crashes, only that pod
  restarts — other pods and the rest of the system are unaffected.

  ## How a request flows through a pod

  1. `Pod.chat/3` or `Pod.call_tool/3` arrives at the GenServer
  2. Pod sets status to `:running`, updates `current_task_id`
  3. Pod calls `ReActLoop.run/5` with:
     - `soul.md` content as the system message
     - conversation history from `Memory.load_history/3`
     - available tools (built-in + manifest internal_tools)
     - `ModelManager.complete/2` as the inference function
  4. ReAct loop runs to completion
  5. Pod persists all new messages via `Memory.save_message/3`
  6. Pod sets status back to `:idle`, returns result

  ## MCP dual role

  Each pod is simultaneously:
  - An **MCP client**: calls tools during its ReAct loop
  - An **MCP server**: exposes `exposed_tools` from manifest to the MCPGateway

  The MCPGateway calls `Pod.call_tool/3` when an external MCP client invokes
  one of the pod's exposed tools.

  ## soul.md hot reload

  The pod uses the `file_system` library to watch `soul.md` for changes.
  On change, the soul is reloaded and used for subsequent requests without
  restarting the pod.
  """

  use GenServer
  require Logger

  alias DesignatorInator.Types.{PodState, Message, ToolResult, ToolCall, ToolDefinition}
  alias DesignatorInator.{ReActLoop, Memory, ModelManager, ToolRegistry}
  alias DesignatorInator.Pod.{Config}

  @workspace_dir_default Path.expand("~/.designator_inator/workspaces")
  @namespace_separator "__"

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts a pod from a directory path and registers it in the `ToolRegistry`.

  Not called directly — use `DesignatorInator.PodSupervisor.start_pod/1`.

  ## Options

  - `:path` — `Path.t()` (required) — absolute path to the pod directory
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    manifest = Keyword.fetch!(opts, :manifest)
    GenServer.start_link(__MODULE__, opts, name: via(manifest.name))
  end

  @doc """
  Sends a chat message to the pod and returns the response.

  If `session_id` is nil, a new session is created.

  ## Examples

      iex> DesignatorInator.Pod.chat("assistant", "What files do I have?", nil)
      {:ok, "Your workspace contains: notes.md, plan.md", "session-uuid"}

      iex> DesignatorInator.Pod.chat("assistant", "And what's in notes.md?", "session-uuid")
      {:ok, "The notes file contains...", "session-uuid"}

      iex> DesignatorInator.Pod.chat("nonexistent", "Hello", nil)
      {:error, :pod_not_found}
  """
  @spec chat(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def chat(pod_name, user_message, session_id) do
    case lookup(pod_name) do
      {:ok, pid} ->
        GenServer.call(pid, {:chat, user_message, session_id}, 130_000)

      {:error, :not_found} ->
        {:error, :pod_not_found}
    end
  end

  @doc """
  Calls one of the pod's exposed tools by name.

  This is how the `MCPGateway` and the orchestrator invoke a pod's capabilities.
  The pod runs a ReAct loop to fulfill the tool call.

  ## Examples

      iex> DesignatorInator.Pod.call_tool("code-reviewer", "review_code",
      ...>   %{"code" => "def foo, do: :bar", "language" => "elixir"})
      {:ok, "The code looks good. One suggestion: ..."}

      iex> DesignatorInator.Pod.call_tool("code-reviewer", "nonexistent_tool", %{})
      {:error, :tool_not_found}
  """
  @spec call_tool(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def call_tool(pod_name, tool_name, params) do
    case lookup(pod_name) do
      {:ok, pid} ->
        GenServer.call(pid, {:call_tool, tool_name, params}, 130_000)

      {:error, :not_found} ->
        {:error, :pod_not_found}
    end
  end

  @doc """
  Returns the current status of the pod.

  ## Examples

      iex> DesignatorInator.Pod.get_status("assistant")
      {:ok, %DesignatorInator.Types.PodState{status: :idle, model: "mistral-7b", ...}}

      iex> DesignatorInator.Pod.get_status("nonexistent")
      {:error, :pod_not_found}
  """
  @spec get_status(String.t()) :: {:ok, PodState.t()} | {:error, :pod_not_found}
  def get_status(pod_name) do
    case lookup(pod_name) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :get_status)}
      {:error, :not_found} -> {:error, :pod_not_found}
    end
  end

  @doc """
  Cancels the pod's current task and returns it to `:idle`.

  If no task is running, this is a no-op.

  ## Examples

      iex> DesignatorInator.Pod.halt("assistant")
      :ok
  """
  @spec halt(String.t()) :: :ok
  def halt(pod_name) do
    case lookup(pod_name) do
      {:ok, pid} -> GenServer.call(pid, :halt)
      {:error, :not_found} -> :ok
    end
  end

  # ── Registry helpers ─────────────────────────────────────────────────────────

  @doc false
  @spec via(String.t()) :: {:via, Registry, term()}
  def via(pod_name) do
    {:via, Registry, {DesignatorInator.PodRegistry, pod_name}}
  end

  @doc false
  @spec lookup(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(pod_name) do
    case Registry.lookup(DesignatorInator.PodRegistry, pod_name) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          Registry.unregister(DesignatorInator.PodRegistry, pod_name)
          lookup_via_swarm(pod_name, pid)
        end

      [] ->
        lookup_via_swarm(pod_name, nil)
    end
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    manifest = Keyword.fetch!(opts, :manifest)
    config =
      case Keyword.get(opts, :config) do
        nil ->
          case Config.load(Path.join(path, "config.yaml")) do
            {:ok, loaded} -> loaded
            {:error, _} -> %Config{}
          end

        loaded ->
          loaded
      end

    soul_path = Path.join(path, "soul.md")
    soul = read_soul(soul_path)
    workspace_root = workspace_root(manifest.name)
    File.mkdir_p!(workspace_root)

    model = resolve_model(manifest, config)

    state = %PodState{
      name: manifest.name,
      path: Path.expand(path),
      manifest: manifest,
      soul: soul,
      status: :loading,
      model: model,
      workspace: workspace_root,
      config: config,
      started_at: DateTime.utc_now()
    }

    if Process.whereis(ModelManager) do
      send(self(), :load_model)
    end

    register_tools(state)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:chat, user_message, session_id}, _from, state) do
    session_id = session_id || Memory.new_session_id()
    running_state = %{state | status: :running, current_task_id: session_id}

    persist_message(running_state.name, session_id, %Message{role: :user, content: user_message})

    system_message = %Message{role: :system, content: running_state.soul}
    history = Memory.load_history(running_state.name, session_id, running_state.config.max_history || 20)
    messages = [system_message | history] ++ [%Message{role: :user, content: user_message}]

    tool_executor = fn call ->
      result = execute_tool_call(call, running_state)
      persist_message(running_state.name, session_id, ReActLoop.tool_result_to_message(result))
      result
    end

    inference_fn = fn msgs, opts ->
      model_opts = [model: running_state.model, temperature: running_state.config.temperature, max_tokens: running_state.config.max_tokens]
      model_opts = Keyword.merge(model_opts, opts)
      ModelManager.complete(msgs, model_opts)
    end

    result =
      ReActLoop.run(messages, available_tools(running_state), tool_executor, inference_fn,
        pod_name: running_state.name,
        session_id: session_id,
        tool_call_format: running_state.config.tool_call_format,
        max_iterations: 20
      )

    case result do
      {:ok, answer} ->
        persist_message(running_state.name, session_id, %Message{role: :assistant, content: answer})
        {:reply, {:ok, answer, session_id}, %{running_state | status: :idle, current_task_id: nil}}

      {:error, reason} ->
        persist_message(running_state.name, session_id, %Message{role: :assistant, content: "Error: #{inspect(reason)}"})
        {:reply, {:error, reason}, %{running_state | status: :idle, current_task_id: nil}}
    end
  end

  @impl GenServer
  def handle_call({:call_tool, tool_name, params}, _from, state) do
    if tool_name in exposed_tool_names(state.manifest) do
      case tool_name do
        "chat" ->
          message = Map.get(params, "message", "")
          session_id = Map.get(params, "session_id")
          {:reply, chat(state.name, message, session_id), state}

        "get_status" ->
          {:reply, {:ok, status_text(state)}, state}

        "halt" ->
          {:reply, :ok, %{state | status: :idle, current_task_id: nil}}

        _ ->
          {:reply, {:error, :unsupported_tool}, state}
      end
    else
      {:reply, {:error, :tool_not_found}, state}
    end
  end

  @impl GenServer
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_call(:halt, _from, state) do
    {:reply, :ok, %{state | status: :idle, current_task_id: nil}}
  end

  @impl GenServer
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    if Path.basename(path) == "soul.md" do
      {:noreply, %{state | soul: read_soul(path)}}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:load_model, state) do
    case ModelManager.load_model(state.model) do
      :ok -> {:noreply, %{state | status: :idle}}
      {:error, reason} ->
        Logger.warning("Failed to load model #{state.model}: #{inspect(reason)}")
        {:noreply, %{state | status: :error}}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    deregister_tools(state)
    :ok
  end

  defp available_tools(%PodState{} = state) do
    state.manifest.internal_tools
    |> Enum.flat_map(fn
      "workspace" -> [DesignatorInator.Tool.to_definition(DesignatorInator.Tools.Workspace)]
      "pods" -> pod_tools(state.name)
      _ -> []
    end)
  end

  defp pod_tools(current_pod_name) do
    tool_registry_module().list_all()
    |> Enum.reject(fn {pod_name, _pid, _definition} -> pod_name == current_pod_name end)
    |> Enum.map(fn {pod_name, _pid, %ToolDefinition{} = definition} ->
      %ToolDefinition{definition | name: namespace_tool_name(pod_name, definition.name)}
    end)
  end

  defp execute_tool_call(%ToolCall{name: tool_name, arguments: params, id: call_id}, state) do
    case String.split(tool_name, @namespace_separator, parts: 2) do
      [pod_name, nested_tool_name] ->
        call_external_tool(call_id, pod_name, nested_tool_name, params, state)

      [_single] ->
        call_internal_tool(call_id, tool_name, params, state)
    end
  end

  defp call_internal_tool(call_id, "workspace", params, state) do
    params =
      params
      |> Map.put("_workspace_root", state.workspace)
      |> Map.put("_pod_name", state.name)

    case DesignatorInator.Tools.Workspace.call(params) do
      {:ok, content} -> %ToolResult{tool_call_id: call_id, content: content, is_error: false}
      {:error, error} -> %ToolResult{tool_call_id: call_id, content: error, is_error: true}
    end
  end

  defp call_internal_tool(call_id, tool_name, _params, _state) do
    %ToolResult{tool_call_id: call_id, content: "Unsupported internal tool: #{tool_name}", is_error: true}
  end

  defp call_external_tool(call_id, pod_name, tool_name, params, state) do
    case DesignatorInator.Pod.call_tool(pod_name, tool_name, params) do
      {:ok, content} ->
        %ToolResult{tool_call_id: call_id, content: content, is_error: false}

      {:error, error} ->
        case alternate_pod_for(tool_name, pod_name) do
          nil ->
            maybe_fallback_to_self(call_id, tool_name, params, state, error)

          alternate_pod ->
            case DesignatorInator.Pod.call_tool(alternate_pod, tool_name, params) do
              {:ok, content} ->
                %ToolResult{tool_call_id: call_id, content: content, is_error: false}

              {:error, alternate_error} ->
                maybe_fallback_to_self(call_id, tool_name, params, state, alternate_error)
            end
        end
    end
  end

  defp register_tools(%PodState{name: name, manifest: %{exposed_tools: tools}}) do
    registry = tool_registry_module()

    if registry_ready?(registry) do
      registry.register(name, self(), tools)
    else
      :ok
    end
  end

  defp deregister_tools(%PodState{name: name}) do
    registry = tool_registry_module()

    if registry_ready?(registry) do
      registry.deregister(name)
    else
      :ok
    end
  end

  defp registry_ready?(DesignatorInator.ToolRegistry) do
    Process.whereis(DesignatorInator.ToolRegistry) != nil
  end

  defp registry_ready?(_module), do: true

  defp tool_registry_module do
    case Application.get_env(:designator_inator, :tool_registry_module) do
      nil -> ToolRegistry
      module -> module
    end
  end

  defp swarm_registry_module do
    case Application.get_env(:designator_inator, :swarm_registry_module) do
      nil -> DesignatorInator.SwarmRegistry
      module -> module
    end
  end

  defp lookup_via_swarm(pod_name, _stale_pid) do
    case swarm_registry_module().find_pod(pod_name) do
      {:ok, {pid, _node}} ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}

      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp namespace_tool_name(pod_name, tool_name), do: "#{pod_name}#{@namespace_separator}#{tool_name}"

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  defp alternate_pod_for(tool_name, excluded_pod) do
    tool_registry_module().lookup(tool_name)
    |> Enum.reject(fn {pod_name, _pid, _definition} -> pod_name == excluded_pod end)
    |> case do
      [] -> nil
      [{pod_name, _pid, _definition} | _] -> pod_name
    end
  end

  defp maybe_fallback_to_self(call_id, tool_name, params, state, error) do
    if tool_name in exposed_tool_names(state.manifest) or tool_name in available_tool_names(state) do
      call_internal_tool(call_id, tool_name, params, state)
    else
      %ToolResult{tool_call_id: call_id, content: format_error(error), is_error: true}
    end
  end

  defp available_tool_names(%PodState{} = state) do
    available_tools(state)
    |> Enum.map(& &1.name)
  end

  defp persist_message(pod_name, session_id, %Message{} = message) do
    _ = Memory.save_message(pod_name, session_id, message)
    :ok
  end

  defp exposed_tool_names(%{exposed_tools: tools}) do
    Enum.map(tools, & &1.name)
  end

  defp read_soul(path) do
    case File.read(path) do
      {:ok, text} -> text
      {:error, _} -> ""
    end
  end

  defp workspace_root(pod_name) do
    Application.get_env(:designator_inator, :workspaces_dir, @workspace_dir_default)
    |> Path.join(pod_name)
  end

  defp resolve_model(manifest, config) do
    cond do
      config.model && is_binary(config.model.primary) -> config.model.primary
      is_binary(manifest.model.primary) -> manifest.model.primary
      true -> manifest.name
    end
  end

  defp status_text(%PodState{} = state) do
    "#{state.status}"
  end
end
