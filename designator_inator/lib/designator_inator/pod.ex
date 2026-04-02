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

  alias DesignatorInator.Types.{PodState, PodManifest, Message}
  alias DesignatorInator.{ReActLoop, Memory, ModelManager, ToolRegistry}
  alias DesignatorInator.Pod.{Manifest, Config}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts a pod from a directory path and registers it in the `ToolRegistry`.

  Not called directly — use `DesignatorInator.PodSupervisor.start_pod/1`.

  ## Options

  - `:path` — `Path.t()` (required) — absolute path to the pod directory
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
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
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # Template (HTDP step 4):
    # 1. Extract path, manifest from opts
    # 2. Load soul.md: File.read!(Path.join(path, "soul.md"))
    # 3. Load config: Config.load(Path.join(path, "config.yaml"))
    # 4. Resolve workspace dir: Path.join(workspaces_dir, manifest.name)
    # 5. File.mkdir_p! workspace dir
    # 6. Set up file_system watcher for soul.md
    # 7. Register exposed tools in ToolRegistry
    # 8. Register in SwarmRegistry
    # 9. Build initial %PodState{} with status: :loading
    # 10. Request model from ModelManager asynchronously (send self :load_model)
    # 11. Return {:ok, state}
    raise "not implemented"
  end

  @impl GenServer
  def handle_call({:chat, user_message, session_id}, _from, state) do
    # Template (HTDP step 4):
    # 1. Resolve or generate session_id
    # 2. Set state.status = :running
    # 3. Load history from Memory.load_history/3
    # 4. Build messages: [system_msg | history] ++ [%Message{role: :user, content: user_message}]
    # 5. Build tool list from manifest.internal_tools
    # 6. Call ReActLoop.run/5
    # 7. Save all new messages to Memory
    # 8. Set state.status = :idle
    # 9. Return {:reply, {:ok, result, session_id}, new_state}
    raise "not implemented"
  end

  @impl GenServer
  def handle_call({:call_tool, tool_name, params}, _from, state) do
    # Template (HTDP step 4):
    # 1. Verify tool_name is in manifest.exposed_tools — return {:error, :tool_not_found} if not
    # 2. Build a synthetic user message: "Call tool #{tool_name} with #{Jason.encode!(params)}"
    # 3. Run via ReActLoop (the pod decides HOW to fulfill the tool — it may use internal tools)
    # 4. Return {:reply, {:ok, result}, state}
    raise "not implemented"
  end

  @impl GenServer
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_call(:halt, _from, state) do
    # Template: Cancel current task if running, set status to :idle
    {:reply, :ok, %{state | status: :idle, current_task_id: nil}}
  end

  @impl GenServer
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    # Template: If path ends in "soul.md", re-read and update state.soul
    raise "not implemented"
  end

  @impl GenServer
  def handle_info(:load_model, state) do
    # Template:
    # 1. Call ModelManager.load_model(state.manifest.model.primary)
    # 2. On :ok: update state.status to :idle
    # 3. On error with fallback: try fallback model
    # 4. On failure: set state.status to :error, log
    raise "not implemented"
  end
end
