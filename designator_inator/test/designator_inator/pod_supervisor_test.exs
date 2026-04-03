defmodule DesignatorInator.PodSupervisorTest do
  use ExUnit.Case, async: false

  alias DesignatorInator.Pod
  alias DesignatorInator.PodSupervisor

  @assistant_path Path.expand("../examples/assistant", File.cwd!())

  setup_all do
    case Process.whereis(DesignatorInator.PodRegistry) do
      nil -> {:ok, _} = start_supervised({Registry, keys: :unique, name: DesignatorInator.PodRegistry})
      _pid -> :ok
    end

    case Process.whereis(DesignatorInator.PodSupervisor) do
      nil -> {:ok, _} = start_supervised(DesignatorInator.PodSupervisor)
      _pid -> :ok
    end

    :ok
  end

  setup do
    on_exit(fn ->
      case Pod.lookup("assistant") do
        {:ok, _} -> PodSupervisor.stop_pod("assistant")
        _ -> :ok
      end
    end)

    :ok
  end

  describe "start_pod/1" do
    test "starts a pod from an example directory" do
      assert {:ok, pid} = PodSupervisor.start_pod(@assistant_path)
      assert is_pid(pid)
      assert {:ok, status} = Pod.get_status("assistant")
      assert status.name == "assistant"
      assert status.workspace =~ "assistant"
      assert status.status in [:loading, :idle, :error]
    end

    test "returns already_started when pod is already running" do
      assert {:ok, _pid} = PodSupervisor.start_pod(@assistant_path)
      assert {:error, :already_started} = PodSupervisor.start_pod(@assistant_path)
    end
  end

  describe "list_pods/0" do
    test "lists running pods" do
      assert {:ok, _pid} = PodSupervisor.start_pod(@assistant_path)
      pods = PodSupervisor.list_pods()
      assert Enum.any?(pods, &(&1.name == "assistant"))
    end
  end

  describe "stop_pod/1" do
    test "stops a running pod" do
      assert {:ok, _pid} = PodSupervisor.start_pod(@assistant_path)
      assert :ok = PodSupervisor.stop_pod("assistant")
      assert {:error, :pod_not_found} = Pod.get_status("assistant")
    end
  end
end
