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

  defp node_module do
    Application.get_env(:designator_inator, :swarm_registry_node_module, Node)
  end

  defp rpc_module do
    Application.get_env(:designator_inator, :swarm_registry_rpc_module, :rpc)
  end

  defp model_manager_module do
    Application.get_env(:designator_inator, :swarm_registry_model_manager_module, DesignatorInator.ModelManager)
  end

  defp gateway_module do
    Application.get_env(:designator_inator, :swarm_registry_gateway_module, DesignatorInator.MCPGateway)
  end

  defp self_node_info do
    fallback = %NodeInfo{node: node(), hostname: hostname(), updated_at: DateTime.utc_now()}

    try do
      model_manager_module().node_info()
    rescue
      _ -> fallback
    catch
      :exit, _ -> fallback
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end

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
    candidates =
      :pg.get_members(@pg_scope, {:pods, pod_name})
      |> Enum.filter(&Process.alive?/1)
      |> Enum.map(&candidate_metadata/1)

    case preferred_candidate(candidates, node_info_index()) do
      nil -> {:error, :not_found}
      %{pid: pid} -> {:ok, {pid, node(pid)}}
    end
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
    @pg_scope
    |> :pg.which_groups()
    |> Enum.flat_map(fn
      {:pods, pod_name} ->
        :pg.get_members(@pg_scope, {:pods, pod_name})
        |> Enum.map(fn pid -> %{name: pod_name, pid: pid, node: node(pid)} end)

      _other ->
        []
    end)
  end

  @doc """
  Returns pods running on a specific node.

  ## Examples

      iex> DesignatorInator.SwarmRegistry.list_on_node(:"designator_inator@pi4.local")
      [%{name: "code-reviewer", pid: #PID<...>}]
  """
  @spec list_on_node(node()) :: [%{name: String.t(), pid: pid()}]
  def list_on_node(node_name) do
    list_all()
    |> Enum.filter(&(&1.node == node_name))
    |> Enum.map(fn %{name: name, pid: pid} -> %{name: name, pid: pid} end)
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
    node_name = String.to_atom("designator_inator@#{ip_or_hostname}")

    case node_module().connect(node_name) do
      true -> {:ok, node_name}
      :ignored -> {:ok, node_name}
      false -> {:error, :connect_failed}
      _ -> {:error, :connect_failed}
    end
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

  @doc false
  @spec preferred_candidate([
          %{pid: pid(), node: node(), model: String.t() | nil}
        ],
        %{node() => NodeInfo.t()}
      ) :: %{pid: pid(), node: node(), model: String.t() | nil} | nil
  def preferred_candidate(candidates, node_infos) do
    candidates
    |> Enum.max_by(fn candidate -> candidate_score(candidate, node_infos) end, fn -> nil end)
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    case :pg.start_link(@pg_scope) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> :ok
    end

    :net_kernel.monitor_nodes(true)

    state = %{node_infos: %{node() => self_node_info()}}
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:nodeup, node}, state) do
    Logger.info("SwarmRegistry node up: #{inspect(node)}")

    case fetch_node_info(node) do
      {:ok, node_info} ->
        {:noreply, put_in(state.node_infos[node], node_info)}

      {:error, reason} ->
        Logger.warning("Unable to fetch node info for #{inspect(node)}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:nodedown, node}, state) do
    Logger.warning("SwarmRegistry node down: #{inspect(node)}")
    gateway_module().refresh_tools()
    {:noreply, update_in(state.node_infos, &Map.delete(&1, node))}
  end

  @impl GenServer
  def handle_call(:node_infos, _from, state) do
    {:reply, Map.values(state.node_infos), state}
  end

  defp candidate_metadata(pid) do
    status = pod_status(pid)
    model = status && Map.get(status, :model)

    %{pid: pid, node: node(pid), model: model}
  end

  defp candidate_score(%{node: candidate_node, model: model}, node_infos) do
    node_info = Map.get(node_infos, candidate_node)

    model_loaded? =
      if model != nil and node_info do
        model in node_info.loaded_models
      else
        false
      end

    local? = candidate_node == node()
    {model_loaded?, local?}
  end

  defp node_info_index do
    try do
      node_infos()
      |> Map.new(fn %NodeInfo{node: node_name} = info -> {node_name, info} end)
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end

  defp pod_status(pid) do
    try do
      GenServer.call(pid, :get_status, 5_000)
    catch
      :exit, _ -> nil
    end
  end

  defp fetch_node_info(node) do
    if node == node() do
      {:ok, self_node_info()}
    else
      case rpc_module().call(node, model_manager_module(), :node_info, []) do
        %NodeInfo{} = info -> {:ok, info}
        other -> {:error, other}
      end
    end
  end
end
