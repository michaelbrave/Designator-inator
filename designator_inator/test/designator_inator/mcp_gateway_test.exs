defmodule DesignatorInator.MCPGatewayTest do
  use ExUnit.Case, async: false

  alias DesignatorInator.MCPGateway
  alias DesignatorInator.ToolRegistry
  alias DesignatorInator.Types.{MCPMessage, ToolDefinition}

  defmodule FakePod do
    use GenServer

    def child_spec({pod_name, test_pid}) do
      %{
        id: {__MODULE__, pod_name},
        start: {__MODULE__, :start_link, [{pod_name, test_pid}]}
      }
    end

    def start_link({pod_name, test_pid}) do
      GenServer.start_link(__MODULE__, {pod_name, test_pid})
    end

    def init({pod_name, test_pid}) do
      _ = Registry.register(DesignatorInator.PodRegistry, pod_name, :fake_pod)
      {:ok, %{pod_name: pod_name, test_pid: test_pid}}
    end

    def handle_call({:call_tool, tool_name, params}, _from, state) do
      send(state.test_pid, {:fake_pod_called, state.pod_name, tool_name, params})
      {:reply, {:ok, "#{state.pod_name}:#{tool_name}:#{Map.get(params, "code", "")}"}, state}
    end
  end

  defp tool_definition(name, description \\ "desc") do
    %ToolDefinition{name: name, description: description, parameters: %{}}
  end

  setup_all do
    case Process.whereis(DesignatorInator.PodRegistry) do
      nil -> {:ok, _} = start_supervised({Registry, keys: :unique, name: DesignatorInator.PodRegistry})
      _pid -> :ok
    end

    :ok
  end

  setup do
    start_supervised!({ToolRegistry, []})
    start_supervised!({MCPGateway, [mode: :multi]})

    :ok
  end

  test "tools/list namespaces tools in multi-pod mode" do
    assistant = start_supervised!({FakePod, {"assistant", self()}})
    reviewer = start_supervised!({FakePod, {"code-reviewer", self()}})

    ToolRegistry.register("assistant", assistant, [tool_definition("chat")])
    ToolRegistry.register("code-reviewer", reviewer, [tool_definition("review_code")])

    response = MCPGateway.handle_request(%MCPMessage{id: 1, method: "tools/list", params: %{}})
    assert %MCPMessage{result: %{"tools" => tools}} = response

    names = Enum.map(tools, & &1["name"]) |> Enum.sort()
    assert names == ["assistant__chat", "code-reviewer__review_code"]
  end

  test "tools/call routes a namespaced call to the correct pod" do
    pod_pid = start_supervised!({FakePod, {"code-reviewer", self()}})
    ToolRegistry.register("code-reviewer", pod_pid, [tool_definition("review_code")])

    response =
      MCPGateway.handle_request(%MCPMessage{
        id: 2,
        method: "tools/call",
        params: %{"name" => "code-reviewer__review_code", "arguments" => %{"code" => "hello"}}
      })

    assert %MCPMessage{result: %{"content" => [%{"text" => "code-reviewer:review_code:hello"}]}} = response
    assert_receive {:fake_pod_called, "code-reviewer", "review_code", %{"code" => "hello"}}
  end

  test "tools/call returns pod not found for missing namespace pod" do
    response =
      MCPGateway.handle_request(%MCPMessage{
        id: 3,
        method: "tools/call",
        params: %{"name" => "missing__review_code", "arguments" => %{}}
      })

    assert %MCPMessage{error: %{code: -32601, message: "Pod not found"}} = response
  end

  test "push_to_sse_connection/2 calls the registered send_fn with the message" do
    test_pid = self()
    send_fn = fn message -> send(test_pid, {:sse_event, message}) end
    connection_id = "test-connection-123"

    :ok = MCPGateway.register_sse_connection(connection_id, send_fn)

    message = %MCPMessage{jsonrpc: "2.0", id: 42, result: %{"tools" => []}}
    assert :ok = MCPGateway.push_to_sse_connection(connection_id, message)

    assert_receive {:sse_event, ^message}
  end

  test "push_to_sse_connection/2 returns error for unknown connection" do
    message = %MCPMessage{jsonrpc: "2.0", id: 1, result: %{}}
    assert {:error, :not_found} = MCPGateway.push_to_sse_connection("no-such-conn", message)
  end
end
