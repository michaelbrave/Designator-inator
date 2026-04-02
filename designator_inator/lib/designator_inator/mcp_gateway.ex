defmodule DesignatorInator.MCPGateway do
  @moduledoc """
  Routes incoming MCP JSON-RPC requests to the appropriate pod.

  ## Role in the system (HTDP step 1)

  The MCPGateway is the single entry point for all external MCP traffic.
  It handles requests from:
  - Claude Desktop / Cursor (via stdio transport)
  - Browser/remote clients (via SSE transport)
  - Pod-to-pod calls (in future — currently pods call each other directly)

  ## Tool namespacing

  When multiple pods are running, tools are namespaced to avoid collisions:

      code_reviewer__review_code   → routes to pod "code-reviewer"
      assistant__chat              → routes to pod "assistant"

  When only one pod is running (or the gateway is in single-pod mode), tools
  are exposed without a namespace.  The routing logic checks the namespace
  separator `__` to determine mode.

  ## MCP method routing

  | Method       | Handler                                                      |
  |--------------|--------------------------------------------------------------|
  | `initialize` | Return server capabilities (no pod involved)                 |
  | `initialized`| Acknowledge (no-op)                                          |
  | `tools/list` | Aggregate tools from all pods via `ToolRegistry`             |
  | `tools/call` | Parse namespace, route to `Pod.call_tool/3`                  |

  ## State (HTDP step 1)

      %{
        mode: :single | :multi,           # single = one pod, no namespace
        active_pod: String.t() | nil,     # for single mode
        sse_connections: %{               # for SSE transport
          connection_id => send_fn
        }
      }
  """

  use GenServer
  require Logger

  alias DesignatorInator.MCP.Protocol
  alias DesignatorInator.Types.MCPMessage
  alias DesignatorInator.{ToolRegistry, Pod}

  @namespace_separator "__"

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Handles a parsed `MCPMessage` and returns the response `MCPMessage`.

  This is the main dispatch function called by both transports.

  ## Examples

      iex> DesignatorInator.MCPGateway.handle_request(%MCPMessage{
      ...>   id: 1, method: "tools/list", params: %{}
      ...> })
      %MCPMessage{id: 1, result: %{"tools" => [...]}}

      iex> DesignatorInator.MCPGateway.handle_request(%MCPMessage{
      ...>   id: 2, method: "tools/call",
      ...>   params: %{"name" => "code_reviewer__review_code",
      ...>             "arguments" => %{"code" => "..."}}
      ...> })
      %MCPMessage{id: 2, result: %{"content" => [%{"type" => "text", "text" => "..."}]}}
  """
  @spec handle_request(MCPMessage.t()) :: MCPMessage.t()
  def handle_request(%MCPMessage{} = message) do
    GenServer.call(__MODULE__, {:handle_request, message}, 130_000)
  end

  @doc """
  Registers an SSE connection so responses can be pushed back to it.
  Called by the SSE transport when a client connects.
  """
  @spec register_sse_connection(String.t(), (map() -> :ok)) :: :ok
  def register_sse_connection(connection_id, send_fn) do
    GenServer.call(__MODULE__, {:register_sse, connection_id, send_fn})
  end

  @doc """
  Removes an SSE connection on client disconnect.
  """
  @spec deregister_sse_connection(String.t()) :: :ok
  def deregister_sse_connection(connection_id) do
    GenServer.call(__MODULE__, {:deregister_sse, connection_id})
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    mode = Keyword.get(opts, :mode, :multi)
    active_pod = Keyword.get(opts, :pod, nil)
    {:ok, %{mode: mode, active_pod: active_pod, sse_connections: %{}}}
  end

  @impl GenServer
  def handle_call({:handle_request, %MCPMessage{method: "initialize"} = msg}, _from, state) do
    {:reply, Protocol.make_initialize_response(msg.id), state}
  end

  @impl GenServer
  def handle_call({:handle_request, %MCPMessage{method: "initialized"}}, _from, state) do
    # Notification — no response needed (id is nil for notifications)
    {:reply, nil, state}
  end

  @impl GenServer
  def handle_call({:handle_request, %MCPMessage{method: "tools/list"} = msg}, _from, state) do
    # Template (HTDP step 4):
    # 1. ToolRegistry.list_all() → list of {pod_name, pid, definition}
    # 2. In :multi mode: namespace each tool name: "#{pod_name}__#{tool.name}"
    # 3. In :single mode: use tool names as-is
    # 4. Protocol.tools_to_mcp(definitions) → result map
    # 5. {:reply, Protocol.make_response(msg.id, result), state}
    raise "not implemented"
  end

  @impl GenServer
  def handle_call({:handle_request, %MCPMessage{method: "tools/call"} = msg}, _from, state) do
    # Template (HTDP step 4):
    # 1. Extract tool_name and arguments from msg.params
    # 2. Parse namespace: split on @namespace_separator
    # 3. :multi mode — {pod_name, bare_tool_name} from "pod_name__tool_name"
    # 4. :single mode — use state.active_pod, tool_name as-is
    # 5. Call Pod.call_tool(pod_name, bare_tool_name, arguments)
    # 6. On {:ok, result}: Protocol.make_tool_result(msg.id, result)
    # 7. On {:error, :pod_not_found}: Protocol.make_error(msg.id, -32601, "Pod not found")
    # 8. On {:error, :tool_not_found}: Protocol.make_error(msg.id, -32601, "Tool not found")
    raise "not implemented"
  end

  @impl GenServer
  def handle_call({:handle_request, %MCPMessage{method: unknown_method} = msg}, _from, state) do
    response = Protocol.make_error(msg.id, -32601, "Method not found: #{unknown_method}")
    {:reply, response, state}
  end

  @impl GenServer
  def handle_call({:register_sse, conn_id, send_fn}, _from, state) do
    {:reply, :ok, put_in(state.sse_connections[conn_id], send_fn)}
  end

  @impl GenServer
  def handle_call({:deregister_sse, conn_id}, _from, state) do
    {:reply, :ok, update_in(state.sse_connections, &Map.delete(&1, conn_id))}
  end
end
