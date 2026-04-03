defmodule DesignatorInator.PodTest do
  use ExUnit.Case, async: false

  alias DesignatorInator.Pod
  alias DesignatorInator.Pod.Manifest
  alias DesignatorInator.Memory
  alias DesignatorInator.Types.Message
  alias DesignatorInator.Types.ToolDefinition

  setup do
    case Process.whereis(DesignatorInator.PodRegistry) do
      nil -> {:ok, _} = start_supervised({Registry, keys: :unique, name: DesignatorInator.PodRegistry})
      _pid -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(DesignatorInator.Memory.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(DesignatorInator.Memory.Repo, {:shared, self()})

    original_tool_registry_module = Application.get_env(:designator_inator, :tool_registry_module)
    original_tool_registry_entries = Application.get_env(:designator_inator, :test_tool_registry_entries)
    original_test_pid = Application.get_env(:designator_inator, :test_pid)

    on_exit(fn ->
      Application.put_env(:designator_inator, :tool_registry_module, original_tool_registry_module)
      Application.put_env(:designator_inator, :test_tool_registry_entries, original_tool_registry_entries)
      Application.put_env(:designator_inator, :test_pid, original_test_pid)
      Ecto.Adapters.SQL.Sandbox.mode(DesignatorInator.Memory.Repo, :manual)
    end)

    :ok
  end

  describe "pod registration lifecycle" do
    test "registers exposed tools on start and deregisters on stop" do
      Application.put_env(:designator_inator, :tool_registry_module, DesignatorInator.PodTest.ToolRegistryStub)
      Application.put_env(:designator_inator, :test_pid, self())

      {pod_dir, manifest} = pod_dir("registry-pod")

      assert {:ok, pid} = Pod.start_link(path: pod_dir, manifest: manifest)

      assert_receive {:tool_registry_registered, "registry-pod", ^pid, ["ping"]}

      :ok = GenServer.stop(pid)
      assert_receive {:tool_registry_deregistered, "registry-pod"}
    end
  end

  describe "pod-to-pod delegation" do
    test "treats registered pods as tools when internal_tools includes pods" do
      Application.put_env(:designator_inator, :tool_registry_module, DesignatorInator.PodTest.ToolRegistryStub)
      Application.put_env(:designator_inator, :test_pid, self())

      external_pod_name = "code-reviewer"
      external_pid = start_external_pod_stub(external_pod_name)

      Application.put_env(:designator_inator, :test_tool_registry_entries, [
        {external_pod_name, external_pid, review_code_tool_definition()}
      ])

      start_supervised!({DesignatorInator.PodTest.ModelManagerStub, [
        "<tool_call>\n{\"name\": \"code-reviewer__review_code\", \"arguments\": {\"code\": \"def foo, do: :bar\"}}\n</tool_call>",
        "Delegation complete"
      ]})

      {pod_dir, manifest} = pod_dir("orchestrator", ["pods"])

      assert {:ok, pid} = Pod.start_link(path: pod_dir, manifest: manifest)
      assert_receive {:tool_registry_registered, "orchestrator", ^pid, _tools}

      assert {:ok, "Delegation complete", session_id} = Pod.chat("orchestrator", "review the code", nil)
      assert is_binary(session_id)
      assert session_id != ""

      assert_receive {:external_tool_called, ^external_pod_name, "review_code", %{"code" => "def foo, do: :bar"}}

      history = Memory.load_history("orchestrator", session_id, 20)

      assert [
               %Message{role: :user, content: "review the code"},
               %Message{role: :tool, content: "reviewed"},
               %Message{role: :assistant, content: "Delegation complete"}
             ] = history

      :ok = GenServer.stop(pid)
      assert_receive {:tool_registry_deregistered, "orchestrator"}
    end

    test "retries an alternate pod when the first delegated pod fails" do
      Application.put_env(:designator_inator, :tool_registry_module, DesignatorInator.PodTest.ToolRegistryStub)
      Application.put_env(:designator_inator, :test_pid, self())

      failing_pod_name = "primary-reviewer"
      backup_pod_name = "backup-reviewer"

      failing_pid = start_external_pod_stub(failing_pod_name, DesignatorInator.PodTest.FailingExternalPodStub)
      backup_pid = start_external_pod_stub(backup_pod_name)

      Application.put_env(:designator_inator, :test_tool_registry_entries, [
        {failing_pod_name, failing_pid, review_code_tool_definition()},
        {backup_pod_name, backup_pid, review_code_tool_definition()}
      ])

      start_supervised!({DesignatorInator.PodTest.ModelManagerStub, [
        "<tool_call>\n{\"name\": \"primary-reviewer__review_code\", \"arguments\": {\"code\": \"def foo, do: :bar\"}}\n</tool_call>",
        "Recovered"
      ]})

      {pod_dir, manifest} = pod_dir("orchestrator", ["pods"])

      assert {:ok, pid} = Pod.start_link(path: pod_dir, manifest: manifest)
      assert_receive {:tool_registry_registered, "orchestrator", ^pid, _tools}

      assert {:ok, "Recovered", session_id} = Pod.chat("orchestrator", "review the code", nil)

      assert_receive {:external_tool_called, ^failing_pod_name, "review_code", %{"code" => "def foo, do: :bar"}}
      assert_receive {:external_tool_called, ^backup_pod_name, "review_code", %{"code" => "def foo, do: :bar"}}

      history = Memory.load_history("orchestrator", session_id, 20)
      assert Enum.any?(history, fn
               %Message{role: :tool, content: content} -> content == "reviewed"
               _ -> false
             end)

      :ok = GenServer.stop(pid)
      assert_receive {:tool_registry_deregistered, "orchestrator"}
    end
  end

  defp pod_dir(name, internal_tools \\ ["workspace"]) do
    dir = Path.join(System.tmp_dir!(), "designator_inator_pod_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "soul.md"), "You are #{name}.")

    File.write!(
      Path.join(dir, "config.yaml"),
      """
      model:
        primary: mistral-7b-instruct-v0.3.Q4_K_M
      inference:
        tool_call_format: llama3
      memory:
        max_history_turns: 20
      """
    )

    File.write!(Path.join(dir, "manifest.yaml"), manifest_yaml(name, internal_tools))

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    {:ok, manifest} = Manifest.load(Path.join(dir, "manifest.yaml"))
    {dir, manifest}
  end

  defp manifest_yaml(name, internal_tools) do
    internal_tools_yaml =
      internal_tools
      |> Enum.map(fn tool -> "  - #{tool}" end)
      |> Enum.join("\n")

    """
    name: #{name}
    version: 1.0.0
    description: Test pod #{name}
    exposed_tools:
      - name: ping
        description: Ping the pod
        parameters: {}
    internal_tools:
    #{internal_tools_yaml}
    """
  end

  defp review_code_tool_definition do
    %ToolDefinition{
      name: "review_code",
      description: "Reviews code for issues.",
      parameters: %{
        "code" => %{type: :string, required: true, description: "Code to review"}
      }
    }
  end

  defp start_external_pod_stub(pod_name, module \\ __MODULE__.ExternalPodStub) do
    {:ok, pid} =
      GenServer.start_link(
        module,
        %{pod_name: pod_name},
        name: {:via, Registry, {DesignatorInator.PodRegistry, pod_name}}
      )

    pid
  end
end

defmodule DesignatorInator.PodTest.ToolRegistryStub do
  def register(pod_name, pod_pid, tools) do
    send(test_pid(), {:tool_registry_registered, pod_name, pod_pid, Enum.map(tools, & &1.name)})
    :ok
  end

  def deregister(pod_name) do
    send(test_pid(), {:tool_registry_deregistered, pod_name})
    :ok
  end

  def lookup(tool_name) do
    list_all()
    |> Enum.filter(fn {_pod_name, _pid, tool} -> tool.name == tool_name end)
  end

  def list_all do
    Application.get_env(:designator_inator, :test_tool_registry_entries, [])
  end

  def tools_for_pod(pod_name) do
    list_all()
    |> Enum.filter(fn {entry_pod_name, _pid, _tool} -> entry_pod_name == pod_name end)
    |> Enum.map(fn {_pod_name, _pid, tool} -> tool end)
  end

  defp test_pid do
    Application.fetch_env!(:designator_inator, :test_pid)
  end
end

defmodule DesignatorInator.PodTest.ModelManagerStub do
  use GenServer

  def start_link(responses) do
    GenServer.start_link(__MODULE__, responses, name: DesignatorInator.ModelManager)
  end

  @impl GenServer
  def init(responses) do
    {:ok, responses}
  end

  @impl GenServer
  def handle_call({:load_model, _model}, _from, responses) do
    {:reply, :ok, responses}
  end

  @impl GenServer
  def handle_call({:unload_model, _model}, _from, responses) do
    {:reply, :ok, responses}
  end

  @impl GenServer
  def handle_call({:complete, _messages, _opts}, _from, [response | rest]) do
    {:reply, {:ok, response}, rest}
  end

  @impl GenServer
  def handle_call({:complete, _messages, _opts}, _from, []) do
    {:reply, {:error, :no_more_responses}, []}
  end
end

defmodule DesignatorInator.PodTest.ExternalPodStub do
  use GenServer

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:call_tool, tool_name, params}, _from, %{pod_name: pod_name} = state) do
    send(Application.fetch_env!(:designator_inator, :test_pid), {:external_tool_called, pod_name, tool_name, params})
    {:reply, {:ok, "reviewed"}, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, %{status: :idle}, state}
  end
end

defmodule DesignatorInator.PodTest.FailingExternalPodStub do
  use GenServer

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:call_tool, tool_name, params}, _from, %{pod_name: pod_name} = state) do
    send(Application.fetch_env!(:designator_inator, :test_pid), {:external_tool_called, pod_name, tool_name, params})
    {:reply, {:error, :boom}, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, %{status: :idle}, state}
  end
end
