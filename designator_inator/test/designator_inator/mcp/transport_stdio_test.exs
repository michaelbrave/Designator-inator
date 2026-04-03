defmodule DesignatorInator.MCP.TransportStdioTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias DesignatorInator.MCP.Transport.Stdio

  defmodule GatewayStub do
    def handle_request(%{method: "initialize", id: id}) do
      DesignatorInator.MCP.Protocol.make_initialize_response(id)
    end

    def handle_request(msg) do
      DesignatorInator.MCP.Protocol.make_error(msg.id, -32601, "Method not found")
    end
  end

  setup do
    previous = Application.get_env(:designator_inator, :mcp_gateway_module)
    Application.put_env(:designator_inator, :mcp_gateway_module, GatewayStub)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:designator_inator, :mcp_gateway_module)
      else
        Application.put_env(:designator_inator, :mcp_gateway_module, previous)
      end
    end)

    :ok
  end

  describe "read_message/0" do
    test "reads one line and trims the newline" do
      input = ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"}\n)

      assert capture_io(input, fn ->
               assert {:ok, ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"})} = Stdio.read_message()
             end) == ""
    end

    test "returns :eof when stdin is closed" do
      assert capture_io("", fn ->
               assert :eof = Stdio.read_message()
             end) == ""
    end
  end

  describe "write_message/1" do
    test "writes a line to stdout" do
      assert capture_io(fn ->
               assert :ok = Stdio.write_message(~s({"jsonrpc":"2.0","id":1,"result":{}}))
             end) == ~s({"jsonrpc":"2.0","id":1,"result":{}}\n)
    end
  end

  describe "handle_info/2" do
    test "writes a parse error for invalid JSON" do
      output =
        capture_io(fn ->
          assert {:noreply, %{}} = Stdio.handle_info({:mcp_message, "not json"}, %{})
        end)

      assert output =~ ~s("code":-32700)
      assert output =~ ~s(Parse error)
    end

    test "writes an initialize response for a valid request" do
      json = ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})

      output =
        capture_io(fn ->
          assert {:noreply, %{}} = Stdio.handle_info({:mcp_message, json}, %{})
        end)

      assert output =~ ~s("method":"initialize") == false
      assert output =~ ~s("protocolVersion":"2024-11-05")
      assert output =~ ~s("serverInfo")
    end
  end
end
