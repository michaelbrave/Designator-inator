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
  are exposed without a namespace. The routing logic checks the namespace
  separator `__` to determine mode.

  ## MCP method routing

  | Method        | Handler                                               |
  |---------------|--------------------------------------------------------|
  | `initialize`  | Return server capabilities (no pod involved)          |
  | `initialized` | Acknowledge (no-op)                                   |
  | `tools/list`  | Aggregate tools from all pods via `ToolRegistry`      |
  | `tools/call`  | Parse namespace, route to `Pod.call_tool/3`           |

  ## State (HTDP step 1)

      %{
        mode: :single | :multi,
        active_pod: String.t() | nil,
        sse_connections: %{connection_id => send_fn}
      }
  """

  use GenServer
  require Logger

  alias DesignatorInator.MCP.Protocol
  alias DesignatorInator.Types.MCPMessage
  alias DesignatorInator.{Pod, ToolRegistry}

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

  @doc """
  Pushes an MCP response message to a registered SSE connection.

  Called by the SSE transport after getting a response from `handle_request/1`,
  so it can be streamed back to the client over the open SSE connection.

  Returns `{:error, :not_found}` if the connection has already disconnected.
  """
  @spec push_to_sse_connection(String.t(), MCPMessage.t()) :: :ok | {:error, :not_found}
  def push_to_sse_connection(connection_id, %MCPMessage{} = message) do
    GenServer.call(__MODULE__, {:push_to_sse, connection_id, message})
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
    {:reply, nil, state}
  end

  @impl GenServer
  def handle_call({:handle_request, %MCPMessage{method: "tools/list"} = msg}, _from, state) do
    definitions =
      ToolRegistry.list_all()
      |> Enum.map(fn {pod_name, _pid, definition} ->
        maybe_namespace_tool(definition, pod_name, state.mode)
      end)

    result = Protocol.tools_to_mcp(definitions)
    {:reply, Protocol.make_response(msg.id, result), state}
  end

  @impl GenServer
  def handle_call({:handle_request, %MCPMessage{method: "tools/call"} = msg}, _from, state) do
    {tool_name, arguments} = extract_tool_call_params(msg.params)

    case resolve_tool_route(tool_name, state) do
      {:ok, pod_name, bare_tool_name} ->
        case Pod.call_tool(pod_name, bare_tool_name, arguments) do
          {:ok, result} ->
            {:reply, Protocol.make_tool_result(msg.id, result), state}

          {:error, :pod_not_found} ->
            {:reply, Protocol.make_error(msg.id, -32601, "Pod not found"), state}

          {:error, :tool_not_found} ->
            {:reply, Protocol.make_error(msg.id, -32601, "Tool not found"), state}

          {:error, reason} ->
            {:reply, Protocol.make_error(msg.id, -32603, "Tool call failed", reason), state}
        end

      {:error, :invalid_params} ->
        {:reply, Protocol.make_error(msg.id, -32602, "Invalid params"), state}

      {:error, :pod_not_found} ->
        {:reply, Protocol.make_error(msg.id, -32601, "Pod not found"), state}
    end
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

  @impl GenServer
  def handle_call({:push_to_sse, connection_id, message}, _from, state) do
    case Map.get(state.sse_connections, connection_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      send_fn ->
        send_fn.(message)
        {:reply, :ok, state}
    end
  end

  defp maybe_namespace_tool(definition, pod_name, :multi) do
    %{definition | name: pod_name <> @namespace_separator <> definition.name}
  end

  defp maybe_namespace_tool(definition, _pod_name, :single), do: definition

  defp extract_tool_call_params(params) when is_map(params) do
    {Map.get(params, "name"), Map.get(params, "arguments", %{})}
  end

  defp extract_tool_call_params(_), do: {nil, %{}}

  defp resolve_tool_route(_tool_name, %{mode: :single, active_pod: nil}) do
    {:error, :pod_not_found}
  end

  defp resolve_tool_route(tool_name, %{mode: :single, active_pod: pod_name}) when is_binary(tool_name) do
    {:ok, pod_name, tool_name}
  end

  defp resolve_tool_route(tool_name, %{mode: :multi}) when is_binary(tool_name) do
    case String.split(tool_name, @namespace_separator, parts: 2) do
      [pod_name, bare_tool_name] when pod_name != "" and bare_tool_name != "" ->
        {:ok, pod_name, bare_tool_name}

      _ ->
        {:error, :invalid_params}
    end
  end

  defp resolve_tool_route(_tool_name, _state), do: {:error, :invalid_params}
end
