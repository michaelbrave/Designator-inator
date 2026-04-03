defmodule DesignatorInator.MCP.TransportSseTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias DesignatorInator.MCP.Transport.SSE
  alias DesignatorInator.Types.MCPMessage

  defmodule GatewayStub do
    def handle_request(%MCPMessage{} = msg) do
      send(test_pid(), {:gateway_called, msg})
      DesignatorInator.MCP.Protocol.make_response(msg.id, %{"ok" => true})
    end

    defp test_pid do
      Application.fetch_env!(:designator_inator, :mcp_test_pid)
    end
  end

  setup do
    tokens_file = Path.join(System.tmp_dir!(), "designator_inator_tokens_#{System.unique_integer([:positive])}.yaml")
    File.write!(tokens_file, "- secret-token\n")

    old_tokens_file = Application.get_env(:designator_inator, :tokens_file)
    old_gateway = Application.get_env(:designator_inator, :mcp_gateway_module)
    old_test_pid = Application.get_env(:designator_inator, :mcp_test_pid)

    Application.put_env(:designator_inator, :tokens_file, tokens_file)
    Application.put_env(:designator_inator, :mcp_gateway_module, GatewayStub)
    Application.put_env(:designator_inator, :mcp_test_pid, self())

    on_exit(fn ->
      restore_env(:tokens_file, old_tokens_file)
      restore_env(:mcp_gateway_module, old_gateway)
      restore_env(:mcp_test_pid, old_test_pid)
      File.rm_rf(tokens_file)
    end)

    :ok
  end

  test "authenticate/1 accepts a bearer token from the tokens file" do
    conn = conn(:get, "/sse") |> put_req_header("authorization", "Bearer secret-token")
    assert :ok = SSE.authenticate(conn)
  end

  test "authenticate/1 rejects a missing or unknown token" do
    conn = conn(:get, "/sse")
    assert {:error, :unauthorized} = SSE.authenticate(conn)

    conn = conn(:get, "/sse") |> put_req_header("authorization", "Bearer wrong-token")
    assert {:error, :unauthorized} = SSE.authenticate(conn)
  end

  test "POST /message dispatches the parsed MCP request to the gateway" do
    body = ~s({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}})

    conn =
      conn(:post, "/message?conn=test-conn", body)
      |> put_req_header("authorization", "Bearer secret-token")
      |> put_req_header("content-type", "application/json")

    conn = SSE.call(conn, [])

    assert conn.status == 202
    assert_receive {:gateway_called, %MCPMessage{id: 1, method: "tools/list"}}
  end

  defp restore_env(key, value) do
    case value do
      nil -> Application.delete_env(:designator_inator, key)
      _ -> Application.put_env(:designator_inator, key, value)
    end
  end
end
