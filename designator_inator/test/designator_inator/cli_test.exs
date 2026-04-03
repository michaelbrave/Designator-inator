defmodule DesignatorInator.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias DesignatorInator.{CLI, ModelInventory, Pod, PodSupervisor}

  @assistant_path Path.expand("../examples/assistant", File.cwd!())

  defmodule StubPod do
    def chat(_pod_name, message, session_id) do
      {:ok, "echo: #{message}", session_id || "session-123"}
    end
  end

  defmodule StubPodSupervisor do
    def start_pod(pod_path) do
      send(test_pid(), {:start_pod, pod_path})
      {:ok, self()}
    end

    defp test_pid do
      Application.fetch_env!(:designator_inator, :cli_test_pid)
    end
  end

  defmodule StubTransport do
    def start_link(_opts) do
      pid = test_pid()

      Task.start_link(fn ->
        send(pid, :transport_started)
        Process.sleep(10)
      end)
    end

    defp test_pid do
      Application.fetch_env!(:designator_inator, :cli_test_pid)
    end
  end

  defmodule ServeGatewayStub do
    def handle_request(%{method: "initialize", id: id}) do
      DesignatorInator.MCP.Protocol.make_initialize_response(id)
    end

    def handle_request(%{method: "tools/list", id: id}) do
      DesignatorInator.MCP.Protocol.make_response(id, %{"tools" => []})
    end

    def handle_request(msg) do
      DesignatorInator.MCP.Protocol.make_error(msg.id, -32601, "Method not found")
    end
  end

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

      Application.delete_env(:designator_inator, :cli_pod_module)
      Application.delete_env(:designator_inator, :cli_pod_supervisor_module)
      Application.delete_env(:designator_inator, :cli_mcp_transport_module)
      Application.delete_env(:designator_inator, :mcp_gateway_module)
      Application.delete_env(:designator_inator, :mcp_stdio_stop_fun)
      Application.delete_env(:designator_inator, :cli_test_pid)
      Application.delete_env(:designator_inator, :models_dir)
    end)

    :ok
  end

  test "cmd_run/2 starts a pod in detach mode" do
    output = capture_io(fn ->
      assert :ok = CLI.cmd_run([@assistant_path], detach: true)
    end)

    assert output =~ "Pod started: assistant"
    assert {:ok, _pid} = Pod.lookup("assistant")
  end

  test "cmd_stop/1 stops a running pod" do
    assert {:ok, _pid} = PodSupervisor.start_pod(@assistant_path)

    output = capture_io(fn ->
      assert :ok = CLI.cmd_stop(["assistant"])
    end)

    assert output =~ "Pod stopped: assistant"
    assert {:error, :not_found} = Pod.lookup("assistant")
  end

  test "cmd_list/0 prints running pods" do
    assert {:ok, _pid} = PodSupervisor.start_pod(@assistant_path)

    output = capture_io(fn ->
      assert :ok = CLI.cmd_list()
    end)

    assert output =~ "NAME"
    assert output =~ "assistant"
  end

  test "cmd_models/0 prints available models" do
    models_dir = Path.join(System.tmp_dir!(), "designator_inator_cli_models_")
    File.rm_rf!(models_dir)
    File.mkdir_p!(models_dir)
    File.write!(Path.join(models_dir, "mistral-7b-instruct-v0.3.Q4_K_M.gguf"), "fake")

    Application.put_env(:designator_inator, :models_dir, models_dir)
    {:ok, _} = start_supervised({ModelInventory, []})

    output = capture_io(fn ->
      assert :ok = CLI.cmd_models()
    end)

    assert output =~ "NAME"
    assert output =~ "mistral-7b-instruct-v0.3.Q4_K_M"
  end

  test "cmd_serve/2 starts the pod and blocks on the configured transport" do
    Application.put_env(:designator_inator, :cli_pod_supervisor_module, StubPodSupervisor)
    Application.put_env(:designator_inator, :cli_mcp_transport_module, StubTransport)
    Application.put_env(:designator_inator, :cli_test_pid, self())

    pod_path = Path.expand(@assistant_path)

    output = capture_io(fn ->
      assert :ok = CLI.cmd_serve([@assistant_path], [])
    end)

    assert output =~ "Starting MCP stdio server: assistant"
    assert_receive {:start_pod, ^pod_path}
    assert_receive :transport_started
  end

  test "cmd_serve/2 works end-to-end with the real stdio transport and initialize request" do
    test_pid = self()
    Application.put_env(:designator_inator, :cli_pod_supervisor_module, StubPodSupervisor)
    Application.put_env(:designator_inator, :mcp_gateway_module, ServeGatewayStub)
    Application.put_env(:designator_inator, :mcp_stdio_stop_fun, fn _code ->
      send(test_pid, :stdio_stop_called)
      exit(:normal)
    end)
    Application.put_env(:designator_inator, :cli_test_pid, test_pid)

    input = ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n)

    pod_path = Path.expand(@assistant_path)

    output = capture_io(input, fn ->
      assert :ok = CLI.cmd_serve([@assistant_path], [])
    end)

    assert output =~ ~s("protocolVersion":"2024-11-05")
    assert output =~ ~s("serverInfo")
    assert_receive {:start_pod, ^pod_path}
    assert_receive :stdio_stop_called
  end

  test "chat_loop/2 uses the configured pod module and exits on /quit" do
    Application.put_env(:designator_inator, :cli_pod_module, StubPod)

    output = capture_io("Hello\n/quit\n", fn ->
      assert :ok = CLI.chat_loop("assistant", "session-123")
    end)

    assert output =~ "You: "
    assert output =~ "assistant: echo: Hello"
    assert output =~ "Goodbye"
  end
end
