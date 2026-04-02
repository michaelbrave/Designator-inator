defmodule DesignatorInator.ToolRegistry do
  @moduledoc """
  ETS-backed catalog of all tools exposed by running pods.

  ## Data definitions (HTDP step 1)

  The registry is an ETS table with entries of shape:

      {tool_name :: String.t(), pod_name :: String.t(), pod_pid :: pid(), definition :: ToolDefinition.t()}

  One row per tool per pod.  Multiple pods can expose the same tool name
  (different instances, or different specialist pods).  `lookup/1` returns all
  matches; callers pick based on routing strategy (usually first available).

  ## Why ETS?

  Reads are the common case (every ReAct loop iteration may query the registry
  to discover orchestrator tools).  ETS gives O(1) concurrent reads without
  going through the GenServer.  The GenServer is only the owner — it serializes
  writes (register/deregister) but reads bypass it.

  ## Concurrency

  - Reads (`lookup/1`, `list_all/0`, `tools_for_pod/1`): direct ETS reads, no GenServer
  - Writes (`register/2`, `deregister/1`): go through GenServer to serialize

  ## Lifecycle

  Pods call `register/2` when they start and `deregister/1` when they stop.
  `PodSupervisor` can also deregister pods when it detects a crash.
  """

  use GenServer
  require Logger

  alias DesignatorInator.Types.ToolDefinition

  @table_name :designator_inator_tool_registry

  # ── Public API (reads — direct ETS) ─────────────────────────────────────────

  @doc """
  Starts the ToolRegistry GenServer and creates the ETS table.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up all pods that expose a tool with `tool_name`.

  Returns a list because multiple pods may expose the same tool name.
  Returns `[]` if no pod exposes that tool.

  ## Examples

      iex> DesignatorInator.ToolRegistry.lookup("review_code")
      [{"code-reviewer", #PID<0.456.0>, %ToolDefinition{name: "review_code", ...}}]

      iex> DesignatorInator.ToolRegistry.lookup("nonexistent_tool")
      []
  """
  @spec lookup(String.t()) :: [{String.t(), pid(), ToolDefinition.t()}]
  def lookup(tool_name) do
    # Template:
    # :ets.match_object(@table_name, {tool_name, :"$1", :"$2", :"$3"})
    # Map results to {pod_name, pod_pid, definition} tuples
    raise "not implemented"
  end

  @doc """
  Returns all registered tools across all pods.

  ## Examples

      iex> DesignatorInator.ToolRegistry.list_all()
      [
        {"assistant",    #PID<...>, %ToolDefinition{name: "chat",        ...}},
        {"code-reviewer",#PID<...>, %ToolDefinition{name: "review_code", ...}}
      ]
  """
  @spec list_all() :: [{String.t(), pid(), ToolDefinition.t()}]
  def list_all do
    # Template: :ets.tab2list(@table_name) |> format
    raise "not implemented"
  end

  @doc """
  Returns all tools registered by a specific pod.

  ## Examples

      iex> DesignatorInator.ToolRegistry.tools_for_pod("code-reviewer")
      [%ToolDefinition{name: "review_code", ...}, %ToolDefinition{name: "get_status", ...}]
  """
  @spec tools_for_pod(String.t()) :: [ToolDefinition.t()]
  def tools_for_pod(pod_name) do
    # Template: ETS match on pod_name field
    raise "not implemented"
  end

  # ── Public API (writes — via GenServer) ──────────────────────────────────────

  @doc """
  Registers a pod's exposed tools.  Called by `DesignatorInator.Pod` on startup.

  If the pod was previously registered (e.g. after a restart), its old entries
  are replaced.

  ## Examples

      iex> DesignatorInator.ToolRegistry.register("assistant", self(), [
      ...>   %ToolDefinition{name: "chat", description: "Chat with the assistant", parameters: %{}}
      ...> ])
      :ok
  """
  @spec register(String.t(), pid(), [ToolDefinition.t()]) :: :ok
  def register(pod_name, pod_pid, tools) do
    GenServer.call(__MODULE__, {:register, pod_name, pod_pid, tools})
  end

  @doc """
  Removes all tool registrations for `pod_name`.  Called on pod shutdown.

  No-op if the pod was not registered.

  ## Examples

      iex> DesignatorInator.ToolRegistry.deregister("assistant")
      :ok
  """
  @spec deregister(String.t()) :: :ok
  def deregister(pod_name) do
    GenServer.call(__MODULE__, {:deregister, pod_name})
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # Template:
    # :ets.new(@table_name, [:named_table, :bag, :public, read_concurrency: true])
    # Return {:ok, %{}}
    raise "not implemented"
  end

  @impl GenServer
  def handle_call({:register, pod_name, pod_pid, tools}, _from, state) do
    # Template:
    # 1. Delete existing entries for pod_name
    # 2. Insert new entries: :ets.insert(@table_name, {tool.name, pod_name, pod_pid, tool})
    #    for each tool in tools
    # 3. Log how many tools registered
    # 4. Reply :ok
    raise "not implemented"
  end

  @impl GenServer
  def handle_call({:deregister, pod_name}, _from, state) do
    # Template:
    # :ets.match_delete(@table_name, {:"_", pod_name, :"_", :"_"})
    # Reply :ok
    raise "not implemented"
  end
end
