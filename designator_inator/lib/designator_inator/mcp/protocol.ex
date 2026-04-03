defmodule DesignatorInator.MCP.Protocol do
  @moduledoc """
  MCP (Model Context Protocol) JSON-RPC 2.0 message encoding and decoding.

  ## Data definitions (HTDP step 1)

  All MCP communication uses the `DesignatorInator.Types.MCPMessage` struct.
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

  Standard JSON-RPC codes are defined in `DesignatorInator.Types.MCPError`.
  MCP-specific codes are in the `-32000` to `-32099` range.

  ## Examples

  See `DesignatorInator.MCP.Protocol.parse_message/1` and `encode_message/1` for
  worked examples.
  """

  alias DesignatorInator.Types.{MCPMessage, MCPError, ToolDefinition}

  # ── Parsing ──────────────────────────────────────────────────────────────────

  @doc """
  Parses a JSON string into a `MCPMessage` struct.

  Returns `{:error, :invalid_json}` if the string is not valid JSON.
  Returns `{:error, :invalid_jsonrpc}` if required fields are missing.

  ## Examples

      iex> DesignatorInator.MCP.Protocol.parse_message(~s({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}))
      {:ok, %DesignatorInator.Types.MCPMessage{id: 1, method: "tools/list", params: %{}}}

      iex> DesignatorInator.MCP.Protocol.parse_message("not json")
      {:error, :invalid_json}

      iex> DesignatorInator.MCP.Protocol.parse_message(~s({"not": "jsonrpc"}))
      {:error, :invalid_jsonrpc}
  """
  @spec parse_message(String.t()) :: {:ok, MCPMessage.t()} | {:error, atom()}
  def parse_message(json_string) do
    # Template (HTDP step 4):
    # 1. Jason.decode(json_string) → {:ok, map} | {:error, _} → :invalid_json
    # 2. Validate map["jsonrpc"] == "2.0" → :invalid_jsonrpc if not
    # 3. Build %MCPMessage{} from the map, converting types as needed
    with {:ok, map} <- Jason.decode(json_string),
         true <- Map.get(map, "jsonrpc") == "2.0" do
      {:ok,
       %MCPMessage{
         jsonrpc: "2.0",
         id: Map.get(map, "id"),
         method: Map.get(map, "method"),
         params: Map.get(map, "params"),
         result: Map.get(map, "result"),
         error: parse_error(Map.get(map, "error"))
       }}
    else
      {:error, _} -> {:error, :invalid_json}
      false -> {:error, :invalid_jsonrpc}
      nil -> {:error, :invalid_jsonrpc}
    end
  end

  # ── Encoding ─────────────────────────────────────────────────────────────────

  @doc """
  Encodes an `MCPMessage` to a JSON string.

  ## Examples

      iex> DesignatorInator.MCP.Protocol.encode_message(%MCPMessage{
      ...>   jsonrpc: "2.0", id: 1, result: %{"tools" => []}
      ...> })
      {:ok, ~s({"jsonrpc":"2.0","id":1,"result":{"tools":[]}})}
  """
  @spec encode_message(MCPMessage.t()) :: {:ok, String.t()} | {:error, term()}
  def encode_message(%MCPMessage{} = message) do
    # Template:
    # 1. Convert message to a map, dropping nil fields
    # 2. Jason.encode(map)
    message
    |> Map.from_struct()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> maybe_encode_nested()
    |> Jason.encode()
  end

  # ── Response builders ─────────────────────────────────────────────────────────

  @doc """
  Builds a successful JSON-RPC response message.

  ## Examples

      iex> DesignatorInator.MCP.Protocol.make_response(1, %{"tools" => []})
      %DesignatorInator.Types.MCPMessage{jsonrpc: "2.0", id: 1, result: %{"tools" => []}}
  """
  @spec make_response(MCPMessage.id(), term()) :: MCPMessage.t()
  def make_response(id, result) do
    %MCPMessage{jsonrpc: "2.0", id: id, result: result}
  end

  @doc """
  Builds a JSON-RPC error response.

  ## Examples

      iex> DesignatorInator.MCP.Protocol.make_error(1, -32601, "Method not found")
      %DesignatorInator.Types.MCPMessage{
        jsonrpc: "2.0", id: 1,
        error: %DesignatorInator.Types.MCPError{code: -32601, message: "Method not found"}
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

      iex> DesignatorInator.MCP.Protocol.make_initialize_response(1)
      %DesignatorInator.Types.MCPMessage{
        id: 1,
        result: %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "DesignatorInator", "version" => "0.1.0"}
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
        "name" => "DesignatorInator",
        "version" => "0.1.0"
      }
    })
  end

  @doc """
  Converts a list of `ToolDefinition` structs to MCP `tools/list` result format.

  ## Examples

      iex> DesignatorInator.MCP.Protocol.tools_to_mcp([
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
    tools = Enum.map(tool_definitions, &tool_definition_to_mcp/1)
    %{"tools" => tools}
  end

  defp tool_definition_to_mcp(%ToolDefinition{name: name, description: description, parameters: parameters}) do
    {properties, required} =
      Enum.reduce(parameters, {%{}, []}, fn {param_name, schema}, {props_acc, req_acc} ->
        {Map.put(props_acc, param_name, param_schema_to_json_schema(schema)), maybe_add_required(req_acc, param_name, schema)}
      end)

    input_schema =
      %{"type" => "object", "properties" => properties}
      |> maybe_put_required(required)

    %{"name" => name, "description" => description, "inputSchema" => input_schema}
  end

  defp param_schema_to_json_schema(schema) when is_map(schema) do
    Enum.reduce(schema, %{}, fn
      {:type, type}, acc -> Map.put(acc, "type", param_type_to_json_schema(type))
      {:required, _required}, acc -> acc
      {:description, description}, acc when is_nil(description) -> acc
      {:description, description}, acc -> Map.put(acc, "description", description)
      {:enum, values}, acc when is_nil(values) -> acc
      {:enum, values}, acc -> Map.put(acc, "enum", values)
      {:default, default}, acc when is_nil(default) -> acc
      {:default, default}, acc -> Map.put(acc, "default", default)
      {key, value}, acc -> Map.put(acc, to_string(key), value)
    end)
  end

  defp param_type_to_json_schema(type) when is_atom(type), do: Atom.to_string(type)
  defp param_type_to_json_schema(type), do: type

  defp maybe_add_required(required, param_name, schema) do
    if Map.get(schema, :required, false), do: [param_name | required], else: required
  end

  defp maybe_put_required(map, []), do: map
  defp maybe_put_required(map, required), do: Map.put(map, "required", Enum.reverse(required))

  defp maybe_encode_nested(%MCPMessage{} = message), do: maybe_encode_nested(Map.from_struct(message))
  defp maybe_encode_nested(%MCPError{} = error), do: error |> Map.from_struct() |> Map.reject(fn {_k, v} -> is_nil(v) end)

  defp maybe_encode_nested(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key, maybe_encode_nested(value)} end)
    |> Enum.into(%{})
  end

  defp maybe_encode_nested(list) when is_list(list), do: Enum.map(list, &maybe_encode_nested/1)
  defp maybe_encode_nested(other), do: other

  defp parse_error(nil), do: nil
  defp parse_error(%{} = error) do
    %MCPError{
      code: Map.get(error, "code") || Map.get(error, :code),
      message: Map.get(error, "message") || Map.get(error, :message),
      data: Map.get(error, "data") || Map.get(error, :data)
    }
  end
  defp parse_error(_), do: nil

  @doc """
  Wraps a tool result string in MCP `tools/call` response format.

  ## Examples

      iex> DesignatorInator.MCP.Protocol.make_tool_result(1, "The code looks good.")
      %DesignatorInator.Types.MCPMessage{
        id: 1,
        result: %{"content" => [%{"type" => "text", "text" => "The code looks good."}]}
      }

      iex> DesignatorInator.MCP.Protocol.make_tool_result(1, "File not found", is_error: true)
      %DesignatorInator.Types.MCPMessage{
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
