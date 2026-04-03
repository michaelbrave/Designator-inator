defmodule DesignatorInator.MCP.ProtocolTest do
  @moduledoc """
  Tests for `DesignatorInator.MCP.Protocol`.

  ## Testing strategy (HTDP step 6)

  All functions are pure (no side effects), so tests are straightforward
  input-output checks.  Wire format is verified against literal JSON strings
  to catch encoding regressions.
  """

  use ExUnit.Case, async: true

  alias DesignatorInator.MCP.Protocol
  alias DesignatorInator.Types.{MCPMessage, MCPError, ToolDefinition}

  # ── parse_message/1 ───────────────────────────────────────────────────────────

  describe "parse_message/1" do
    test "parses a valid tools/list request" do
      json = ~s({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}})
      assert {:ok, %MCPMessage{id: 1, method: "tools/list", params: %{}}} =
        Protocol.parse_message(json)
    end

    test "parses a tools/call request" do
      json = ~s({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ping","arguments":{}}})
      assert {:ok, %MCPMessage{id: 2, method: "tools/call"}} = Protocol.parse_message(json)
    end

    test "parses a notification (no id)" do
      json = ~s({"jsonrpc":"2.0","method":"initialized"})
      assert {:ok, %MCPMessage{id: nil, method: "initialized"}} = Protocol.parse_message(json)
    end

    test "returns :invalid_json for non-JSON input" do
      assert {:error, :invalid_json} = Protocol.parse_message("not json")
    end

    test "returns :invalid_jsonrpc when jsonrpc field is missing" do
      assert {:error, :invalid_jsonrpc} = Protocol.parse_message(~s({"id":1}))
    end

    test "returns :invalid_jsonrpc when jsonrpc version is wrong" do
      assert {:error, :invalid_jsonrpc} =
        Protocol.parse_message(~s({"jsonrpc":"1.0","id":1,"method":"tools/list"}))
    end
  end

  # ── encode_message/1 ──────────────────────────────────────────────────────────

  describe "encode_message/1" do
    test "encodes a response message" do
      msg = %MCPMessage{jsonrpc: "2.0", id: 1, result: %{"tools" => []}}
      assert {:ok, json} = Protocol.encode_message(msg)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["result"] == %{"tools" => []}
      # nil fields should not appear in output
      refute Map.has_key?(decoded, "error")
      refute Map.has_key?(decoded, "method")
    end
  end

  # ── make_response/2 ───────────────────────────────────────────────────────────

  describe "make_response/2" do
    test "builds a response with the given id and result" do
      msg = Protocol.make_response(42, %{"ok" => true})
      assert %MCPMessage{id: 42, result: %{"ok" => true}} = msg
    end
  end

  # ── make_error/4 ─────────────────────────────────────────────────────────────

  describe "make_error/4" do
    test "builds an error response" do
      msg = Protocol.make_error(1, -32601, "Method not found")
      assert %MCPMessage{
        id: 1,
        error: %MCPError{code: -32601, message: "Method not found"}
      } = msg
    end
  end

  # ── tools_to_mcp/1 ────────────────────────────────────────────────────────────

  describe "tools_to_mcp/1" do
    test "converts tool definitions to MCP format" do
      tools = [
        %ToolDefinition{
          name: "ping",
          description: "Returns pong",
          parameters: %{}
        }
      ]

      result = Protocol.tools_to_mcp(tools)
      assert %{"tools" => [mcp_tool]} = result
      assert mcp_tool["name"] == "ping"
      assert mcp_tool["description"] == "Returns pong"
      assert mcp_tool["inputSchema"]["type"] == "object"
      assert is_map(mcp_tool["inputSchema"]["properties"])
    end

    test "converts parameters to JSON Schema properties including required list" do
      tools = [
        %ToolDefinition{
          name: "workspace",
          description: "File ops",
          parameters: %{
            "action" => %{type: :string, required: true, description: "Op to perform", enum: ["read", "write"]},
            "path" => %{type: :string, required: false, description: "File path"}
          }
        }
      ]

      result = Protocol.tools_to_mcp(tools)
      assert %{"tools" => [mcp_tool]} = result
      schema = mcp_tool["inputSchema"]

      assert schema["type"] == "object"
      assert schema["properties"]["action"]["type"] == "string"
      assert schema["properties"]["action"]["description"] == "Op to perform"
      assert schema["properties"]["action"]["enum"] == ["read", "write"]
      assert schema["properties"]["path"]["type"] == "string"
      assert schema["required"] == ["action"]
      refute Map.has_key?(schema["properties"]["path"], "enum")
    end
  end

  # ── make_tool_result/3 ────────────────────────────────────────────────────────

  describe "make_tool_result/3" do
    test "wraps success result" do
      msg = Protocol.make_tool_result(1, "Hello!")
      assert %MCPMessage{result: %{"content" => [%{"type" => "text", "text" => "Hello!"}]}} = msg
      refute get_in(msg.result, ["isError"])
    end

    test "marks error results" do
      msg = Protocol.make_tool_result(1, "Something failed", is_error: true)
      assert msg.result["isError"] == true
    end
  end
end
