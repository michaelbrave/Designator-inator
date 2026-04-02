defmodule ForgeClaw.MCP.Protocol do
  @moduledoc """
  MCP (Model Context Protocol) JSON-RPC 2.0 message encoding and decoding.

  ## Data definitions (HTDP step 1)

  All MCP communication uses the `ForgeClaw.Types.MCPMessage` struct.
  See that module for the full field definition.

  ## MCP methods we implement

  | Method              | Direction         | Description                            |
  |---------------------|-------------------|----------------------------------------|
  | `initialize`        | client → server   | Handshake; server returns capabilities |
  | `initialized`       | client → server   | Client acknowledges handshake          |
  | `tools/list`        | client → server   | List available tools                   |
  | `tools/call`        | client → server   | Invoke a tool                          |
  | `resources/list`    | client → server   | List workspace resources (future)      |
  | `resources/read`    | client → server   | Read a resource (future)               |

  ## Wire format

  Messages are newline-delimited JSON objects.  Each message is one JSON
  object followed by `\\n`.  This is the stdio transport format.

  The SSE transport uses the same JSON objects but wraps them in SSE events:

      data: {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}\n\n

  ## Error codes

  Standard JSON-RPC codes are defined in `ForgeClaw.Types.MCPError`.
  MCP-specific codes are in the `-32000` to `-32099` range.

  ## Examples

  See `ForgeClaw.MCP.Protocol.parse_message/1` and `encode_message/1` for
  worked examples.
  """

  alias ForgeClaw.Types.{MCPMessage, MCPError, ToolDefinition}

  # ── Parsing ──────────────────────────────────────────────────────────────────

  @doc """
  Parses a JSON string into a `MCPMessage` struct.

  Returns `{:error, :invalid_json}` if the string is not valid JSON.
  Returns `{:error, :invalid_jsonrpc}` if required fields are missing.

  ## Examples

      iex> ForgeClaw.MCP.Protocol.parse_message(~s({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}))
      {:ok, %ForgeClaw.Types.MCPMessage{id: 1, method: "tools/list", params: %{}}}

      iex> ForgeClaw.MCP.Protocol.parse_message("not json")
      {:error, :invalid_json}

      iex> ForgeClaw.MCP.Protocol.parse_message(~s({"not": "jsonrpc"}))
      {:error, :invalid_jsonrpc}
  """
  @spec parse_message(String.t()) :: {:ok, MCPMessage.t()} | {:error, atom()}
  def parse_message(json_string) do
    # Template (HTDP step 4):
    # 1. Jason.decode(json_string) → {:ok, map} | {:error, _} → :invalid_json
    # 2. Validate map["jsonrpc"] == "2.0" → :invalid_jsonrpc if not
    # 3. Build %MCPMessage{} from the map, converting types as needed
    raise "not implemented"
  end

  # ── Encoding ─────────────────────────────────────────────────────────────────

  @doc """
  Encodes an `MCPMessage` to a JSON string.

  ## Examples

      iex> ForgeClaw.MCP.Protocol.encode_message(%MCPMessage{
      ...>   jsonrpc: "2.0", id: 1, result: %{"tools" => []}
      ...> })
      {:ok, ~s({"jsonrpc":"2.0","id":1,"result":{"tools":[]}})}
  """
  @spec encode_message(MCPMessage.t()) :: {:ok, String.t()} | {:error, term()}
  def encode_message(%MCPMessage{} = message) do
    # Template:
    # 1. Convert message to a map, dropping nil fields
    # 2. Jason.encode(map)
    raise "not implemented"
  end

  # ── Response builders ─────────────────────────────────────────────────────────

  @doc """
  Builds a successful JSON-RPC response message.

  ## Examples

      iex> ForgeClaw.MCP.Protocol.make_response(1, %{"tools" => []})
      %ForgeClaw.Types.MCPMessage{jsonrpc: "2.0", id: 1, result: %{"tools" => []}}
  """
  @spec make_response(MCPMessage.id(), term()) :: MCPMessage.t()
  def make_response(id, result) do
    %MCPMessage{jsonrpc: "2.0", id: id, result: result}
  end

  @doc """
  Builds a JSON-RPC error response.

  ## Examples

      iex> ForgeClaw.MCP.Protocol.make_error(1, -32601, "Method not found")
      %ForgeClaw.Types.MCPMessage{
        jsonrpc: "2.0", id: 1,
        error: %ForgeClaw.Types.MCPError{code: -32601, message: "Method not found"}
      }
  """
  @spec make_error(MCPMessage.id(), integer(), String.t(), term()) :: MCPMessage.t()
  def make_error(id, code, message, data \\ nil) do
    %MCPMessage{
      jsonrpc: "2.0",
      id: id,
      error: %MCPError{code: code, message: message, data: data}
    }
  end

  @doc """
  Builds an MCP `initialize` response declaring this server's capabilities.

  ## Examples

      iex> ForgeClaw.MCP.Protocol.make_initialize_response(1)
      %ForgeClaw.Types.MCPMessage{
        id: 1,
        result: %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "ForgeClaw", "version" => "0.1.0"}
        }
      }
  """
  @spec make_initialize_response(MCPMessage.id()) :: MCPMessage.t()
  def make_initialize_response(id) do
    make_response(id, %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{
        "tools" => %{},
        "resources" => %{}
      },
      "serverInfo" => %{
        "name" => "ForgeClaw",
        "version" => "0.1.0"
      }
    })
  end

  @doc """
  Converts a list of `ToolDefinition` structs to MCP `tools/list` result format.

  ## Examples

      iex> ForgeClaw.MCP.Protocol.tools_to_mcp([
      ...>   %ToolDefinition{name: "review_code", description: "Reviews code", parameters: %{}}
      ...> ])
      %{"tools" => [%{"name" => "review_code", "description" => "Reviews code", "inputSchema" => %{...}}]}
  """
  @spec tools_to_mcp([ToolDefinition.t()]) :: map()
  def tools_to_mcp(tool_definitions) do
    # Template:
    # Convert each ToolDefinition to MCP tool format:
    # %{"name" => name, "description" => desc, "inputSchema" => json_schema_map}
    # where inputSchema is a JSON Schema object with "type": "object", "properties": {...}
    raise "not implemented"
  end

  @doc """
  Wraps a tool result string in MCP `tools/call` response format.

  ## Examples

      iex> ForgeClaw.MCP.Protocol.make_tool_result(1, "The code looks good.")
      %ForgeClaw.Types.MCPMessage{
        id: 1,
        result: %{"content" => [%{"type" => "text", "text" => "The code looks good."}]}
      }

      iex> ForgeClaw.MCP.Protocol.make_tool_result(1, "File not found", is_error: true)
      %ForgeClaw.Types.MCPMessage{
        id: 1,
        result: %{"content" => [...], "isError" => true}
      }
  """
  @spec make_tool_result(MCPMessage.id(), String.t(), keyword()) :: MCPMessage.t()
  def make_tool_result(id, text, opts \\ []) do
    is_error = Keyword.get(opts, :is_error, false)
    content = [%{"type" => "text", "text" => text}]

    result =
      if is_error,
        do: %{"content" => content, "isError" => true},
        else: %{"content" => content}

    make_response(id, result)
  end
end
