defmodule DesignatorInator.SwarmRegistryTest do
  use ExUnit.Case, async: false

  alias DesignatorInator.SwarmRegistry
  alias DesignatorInator.Types.NodeInfo

  setup do
    ensure_registry_started()

    pid = Process.whereis(SwarmRegistry)
    original_state = :sys.get_state(pid)

    original_env = %{
      node_module: Application.get_env(:designator_inator, :swarm_registry_node_module),
      rpc_module: Application.get_env(:designator_inator, :swarm_registry_rpc_module),
      model_manager_module: Application.get_env(:designator_inator, :swarm_registry_model_manager_module),
      gateway_module: Application.get_env(:designator_inator, :swarm_registry_gateway_module),
      test_pid: Application.get_env(:designator_inator, :test_pid),
      connect_result: Application.get_env(:designator_inator, :swarm_registry_connect_result),
      rpc_result: Application.get_env(:designator_inator, :swarm_registry_rpc_result),
      self_node_info: Application.get_env(:designator_inator, :swarm_registry_self_node_info)
    }

    on_exit(fn ->
      restore_env(:swarm_registry_node_module, original_env.node_module)
      restore_env(:swarm_registry_rpc_module, original_env.rpc_module)
      restore_env(:swarm_registry_model_manager_module, original_env.model_manager_module)
      restore_env(:swarm_registry_gateway_module, original_env.gateway_module)
      restore_env(:test_pid, original_env.test_pid)
      restore_env(:swarm_registry_connect_result, original_env.connect_result)
      restore_env(:swarm_registry_rpc_result, original_env.rpc_result)
      restore_env(:swarm_registry_self_node_info, original_env.self_node_info)
      if Process.alive?(pid), do: :sys.replace_state(pid, fn _ -> original_state end)
    end)

    {:ok, registry: pid}
  end

  describe "find_pod/1 and list_all/0" do
    test "finds registered pods and lists them by node" do
      pid = start_dummy_process()
      assert :ok = SwarmRegistry.register_pod("assistant", pid)

      current_node = node()
      assert {:ok, {^pid, ^current_node}} = SwarmRegistry.find_pod("assistant")

      all = SwarmRegistry.list_all()
      assert Enum.any?(all, fn entry -> entry.name == "assistant" and entry.pid == pid and entry.node == node() end)

      by_node = SwarmRegistry.list_on_node(node())
      assert Enum.any?(by_node, fn entry -> entry.name == "assistant" and entry.pid == pid end)
    end

    test "returns not_found for missing pods" do
      assert {:error, :not_found} = SwarmRegistry.find_pod("missing-pod")
    end
  end

  describe "connect/1" do
    test "returns the connected node name on success" do
      Application.put_env(:designator_inator, :swarm_registry_node_module, DesignatorInator.SwarmRegistryTest.NodeStub)
      Application.put_env(:designator_inator, :swarm_registry_connect_result, true)
      Application.put_env(:designator_inator, :test_pid, self())

      assert {:ok, :"designator_inator@192.168.1.50"} = SwarmRegistry.connect("192.168.1.50")
      assert_receive {:node_connect, :"designator_inator@192.168.1.50"}
    end

    test "returns an error when the node cannot be reached" do
      Application.put_env(:designator_inator, :swarm_registry_node_module, DesignatorInator.SwarmRegistryTest.NodeStub)
      Application.put_env(:designator_inator, :swarm_registry_connect_result, false)
      Application.put_env(:designator_inator, :test_pid, self())

      assert {:error, :connect_failed} = SwarmRegistry.connect("unreachable-host")
      assert_receive {:node_connect, :"designator_inator@unreachable-host"}
    end
  end

  describe "node_infos/0 and node monitoring" do
    test "returns the current node snapshot from state" do
      info_a = sample_node_info(:"designator_inator@alpha", "alpha.local", ["mistral-7b"], 1_024, 256)
      info_b = sample_node_info(:"designator_inator@beta", "beta.local", ["phi-3-mini"], 2_048, 512)

      :sys.replace_state(Process.whereis(SwarmRegistry), fn _ ->
        %{node_infos: %{info_a.node => info_a, info_b.node => info_b}}
      end)

      infos = SwarmRegistry.node_infos()
      assert Enum.sort_by(infos, & &1.node) == Enum.sort_by([info_a, info_b], & &1.node)
    end

    test "adds and removes remote node info on nodeup/nodedown and refreshes the gateway" do
      Application.put_env(:designator_inator, :swarm_registry_rpc_module, DesignatorInator.SwarmRegistryTest.RpcStub)
      Application.put_env(:designator_inator, :swarm_registry_gateway_module, DesignatorInator.SwarmRegistryTest.GatewayStub)
      Application.put_env(:designator_inator, :test_pid, self())

      remote_node = :"designator_inator@remote"
      remote_info = sample_node_info(remote_node, "remote.local", ["codellama-13b"], 3_072, 768)
      Application.put_env(:designator_inator, :swarm_registry_rpc_result, remote_info)

      :sys.replace_state(Process.whereis(SwarmRegistry), fn _ -> %{node_infos: %{}} end)

      send(Process.whereis(SwarmRegistry), {:nodeup, remote_node})
      wait_for_state(fn state -> Map.has_key?(state.node_infos, remote_node) end)
      assert_receive {:rpc_call, ^remote_node, DesignatorInator.ModelManager, :node_info, []}

      state_after_up = :sys.get_state(Process.whereis(SwarmRegistry))
      assert state_after_up.node_infos[remote_node] == remote_info

      send(Process.whereis(SwarmRegistry), {:nodedown, remote_node})
      wait_for_state(fn state -> not Map.has_key?(state.node_infos, remote_node) end)
      assert_receive :refresh_tools
    end
  end

  defp ensure_registry_started do
    case Process.whereis(SwarmRegistry) do
      nil -> start_supervised!(SwarmRegistry)
      _pid -> :ok
    end
  end

  defp wait_for_state(predicate, attempts \\ 25) do
    pid = Process.whereis(SwarmRegistry)

    Enum.reduce_while(1..attempts, false, fn _, _ ->
      state = :sys.get_state(pid)

      if predicate.(state) do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end

  defp start_dummy_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      after
        5_000 -> :ok
      end
    end)
  end

  defp sample_node_info(node_name, hostname, loaded_models, total_mb, used_mb) do
    %NodeInfo{
      node: node_name,
      hostname: hostname,
      vram_total_mb: total_mb,
      vram_used_mb: used_mb,
      ram_free_mb: 4_096,
      loaded_models: loaded_models,
      updated_at: DateTime.utc_now()
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:designator_inator, key)
  defp restore_env(key, value), do: Application.put_env(:designator_inator, key, value)
end

defmodule DesignatorInator.SwarmRegistryTest.NodeStub do
  def connect(node_name) do
    send(test_pid(), {:node_connect, node_name})
    Application.get_env(:designator_inator, :swarm_registry_connect_result, true)
  end

  def monitor_nodes(flag) do
    send(test_pid(), {:monitor_nodes, flag})
    :ok
  end

  defp test_pid do
    Application.get_env(:designator_inator, :test_pid, self())
  end
end

defmodule DesignatorInator.SwarmRegistryTest.RpcStub do
  def call(node, module, function, args) do
    send(test_pid(), {:rpc_call, node, module, function, args})
    Application.get_env(:designator_inator, :swarm_registry_rpc_result)
  end

  defp test_pid do
    Application.get_env(:designator_inator, :test_pid, self())
  end
end

defmodule DesignatorInator.SwarmRegistryTest.GatewayStub do
  def refresh_tools do
    send(test_pid(), :refresh_tools)
    :ok
  end

  defp test_pid do
    Application.get_env(:designator_inator, :test_pid, self())
  end
end
