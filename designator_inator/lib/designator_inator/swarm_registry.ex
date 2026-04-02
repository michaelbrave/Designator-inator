defmodule DesignatorInator.SwarmRegistry do
  @moduledoc """
  Cross-node pod discovery using Erlang's `:pg` (process groups).

  ## How Erlang distribution works here (HTDP step 1)

  When two DesignatorInator nodes connect via `Node.connect/1`, Erlang's distribution
  layer makes processes on different nodes reachable by PID.  `:pg` is built on
  top of this: it maintains a group membership list that is replicated across all
  connected nodes automatically.

  When a pod starts on **any** node in the swarm, it joins a `:pg` group named
  `{:pods, pod_name}`.  Every node's `SwarmRegistry` can then find that pod by
  looking up the group — regardless of which machine it's running on.

      Node A (orchestrator)                  Node B (pi4)
      ┌───────────────────────────┐          ┌─────────────────────────┐
      │ SwarmRegistry             │◄─────────►│ SwarmRegistry           │
      │ find_pod("code-reviewer") │  :pg sync │ Pod("code-reviewer")    │
      │  → {:ok, pid_on_B, :B}   │          │  registered in :pg       │
      └───────────────────────────┘          └─────────────────────────┘

  Once the orchestrator has the PID on Node B, it can call
  `GenServer.call(pod_pid_on_B, request)` directly — Erlang handles
  serialization and networking transparently.

  ## Node connection

  Nodes must:
  1. Share the same Erlang cookie (configured in `~/.designator_inator/config.yaml`)
  2. Be reachable on the LAN

  Connect with: `Node.connect(:"designator_inator@192.168.1.50")` via `designator-inator connect <ip>`.

  ## Node failure handling

  `SwarmRegistry` monitors connected nodes via `Node.monitor_nodes(true)`.
  On `:nodedown`, it removes the stale node's pods from the swarm view.
  (`:pg` handles cleanup automatically, but we also notify `MCPGateway` and
  any waiting orchestrators.)

  ## Data definitions

  `:pg` manages the actual data — no ETS table here.
  The `NodeInfo` broadcast is stored separately in `:global` ETS for fast reads.

      :pg group name: {:pods, pod_name}
      members: [pid_on_nodeA, pid_on_nodeB, ...]  (usually 0 or 1)

      node_info table: {node() => NodeInfo.t()}   (global, updated periodically)
  """

  use GenServer
  require Logger

  alias DesignatorInator.Types.NodeInfo

  @pg_scope :designator_inator_swarm

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers `pid` as a member of the pod group `{:pods, pod_name}`.

  Called by `DesignatorInator.Pod` in its `init/1`.  Works identically whether the
  pod is local or (in theory) calling from a remote node.

  ## Examples

      iex> DesignatorInator.SwarmRegistry.register_pod("assistant", self())
      :ok
  """
  @spec register_pod(String.t(), pid()) :: :ok
  def register_pod(pod_name, pid) do
    :pg.join(@pg_scope, {:pods, pod_name}, pid)
    :ok
  end

  @doc """
  Removes `pid` from the pod group for `pod_name`.

  Called by `DesignatorInator.Pod` in its shutdown handler.

  ## Examples

      iex> DesignatorInator.SwarmRegistry.deregister_pod("assistant", self())
      :ok
  """
  @spec deregister_pod(String.t(), pid()) :: :ok
  def deregister_pod(pod_name, pid) do
    :pg.leave(@pg_scope, {:pods, pod_name}, pid)
    :ok
  end

  @doc """
  Finds a running pod by name, anywhere in the swarm.

  Returns the first PID found and its node.  If multiple nodes run a pod with
  the same name, the local one is preferred; otherwise an arbitrary remote one
  is returned.

  ## Examples

      iex> DesignatorInator.SwarmRegistry.find_pod("code-reviewer")
      {:ok, {#PID<0.456.0>, :"designator_inator@pi4.local"}}

      iex> DesignatorInator.SwarmRegistry.find_pod("nonexistent")
      {:error, :not_found}
  """
  @spec find_pod(String.t()) :: {:ok, {pid(), node()}} | {:error, :not_found}
  def find_pod(pod_name) do
    # Template (HTDP step 4):
    # 1. :pg.get_members(@pg_scope, {:pods, pod_name}) → list of pids
    # 2. If empty: {:error, :not_found}
    # 3. Prefer local pids (node(pid) == node()): pick first local, or first remote
    # 4. Return {:ok, {pid, node(pid)}}
    raise "not implemented"
  end

  @doc """
  Returns all pods visible in the swarm, across all connected nodes.

  ## Examples

      iex> DesignatorInator.SwarmRegistry.list_all()
      [
        %{name: "assistant",     pid: #PID<0.123.0>, node: :"designator_inator@macbook"},
        %{name: "code-reviewer", pid: #PID<...>,     node: :"designator_inator@pi4"}
      ]
  """
  @spec list_all() :: [%{name: String.t(), pid: pid(), node: node()}]
  def list_all do
    # Template (HTDP step 4):
    # 1. :pg.which_groups(@pg_scope) → [{:pods, name}, ...]
    # 2. For each group {:pods, name}: get_members and build result maps
    raise "not implemented"
  end

  @doc """
  Returns pods running on a specific node.

  ## Examples

      iex> DesignatorInator.SwarmRegistry.list_on_node(:"designator_inator@pi4.local")
      [%{name: "code-reviewer", pid: #PID<...>}]
  """
  @spec list_on_node(node()) :: [%{name: String.t(), pid: pid()}]
  def list_on_node(node_name) do
    # Template: filter list_all() to entries where node == node_name
    raise "not implemented"
  end

  @doc """
  Connects this node to a remote DesignatorInator node at `ip_or_hostname`.

  The remote node must be running DesignatorInator with the same Erlang cookie.

  ## Examples

      iex> DesignatorInator.SwarmRegistry.connect("192.168.1.50")
      {:ok, :"designator_inator@192.168.1.50"}

      iex> DesignatorInator.SwarmRegistry.connect("unreachable-host")
      {:error, :connect_failed}
  """
  @spec connect(String.t()) :: {:ok, node()} | {:error, :connect_failed}
  def connect(ip_or_hostname) do
    # Template:
    # 1. Build node name: :"designator_inator@#{ip_or_hostname}"
    # 2. Node.connect(node_name) → true | false | :ignored
    # 3. true: {:ok, node_name}
    # 4. false: {:error, :connect_failed}
    raise "not implemented"
  end

  @doc """
  Returns `NodeInfo` for all connected nodes (including this one).

  Used by the orchestrator to make routing decisions.

  ## Examples

      iex> DesignatorInator.SwarmRegistry.node_infos()
      [
        %NodeInfo{node: :"designator_inator@macbook", vram_used_mb: 4096, loaded_models: ["mistral-7b"]},
        %NodeInfo{node: :"designator_inator@pi4",     vram_used_mb: 2048, loaded_models: ["phi-3-mini"]}
      ]
  """
  @spec node_infos() :: [NodeInfo.t()]
  def node_infos do
    GenServer.call(__MODULE__, :node_infos)
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # Template:
    # 1. :pg.start_link(@pg_scope) — start the scope (idempotent if already started)
    # 2. Node.monitor_nodes(true) — subscribe to nodeup/nodedown events
    # 3. Return {:ok, %{node_infos: %{}}}
    raise "not implemented"
  end

  @impl GenServer
  def handle_info({:nodeup, node}, state) do
    # Template:
    # 1. Log the new node
    # 2. Request NodeInfo from the new node's ModelManager
    # 3. Store in state.node_infos
    raise "not implemented"
  end

  @impl GenServer
  def handle_info({:nodedown, node}, state) do
    # Template:
    # 1. Log the lost node
    # 2. Remove from state.node_infos
    # 3. :pg will automatically clean up the dead node's group memberships
    # 4. Notify MCPGateway to refresh its tool list
    raise "not implemented"
  end

  @impl GenServer
  def handle_call(:node_infos, _from, state) do
    # Template: {:reply, Map.values(state.node_infos), state}
    raise "not implemented"
  end
end
