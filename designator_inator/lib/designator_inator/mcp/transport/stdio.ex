defmodule DesignatorInator.MCP.Transport.Stdio do
  @moduledoc """
  MCP transport over stdio (stdin/stdout).

  ## How it works (HTDP step 1)

  This is the transport used by Claude Desktop, Cursor, and any MCP client that
  launches DesignatorInator as a subprocess via:

      {
        "mcpServers": {
          "designator_inator": {
            "command": "designator-inator",
            "args": ["serve", "./my-pod/"]
          }
        }
      }

  The process:
  1. MCP client launches `designator-inator serve ./my-pod/`
  2. DesignatorInator starts the application and this transport process
  3. This module reads newline-delimited JSON from stdin in a loop
  4. Each message is parsed and handed to `MCPGateway.handle_request/1`
  5. The response is encoded and written to stdout

  ## Design

  The read loop runs in a dedicated `Task` (not the GenServer itself) so the
  GenServer mailbox is not blocked while waiting for stdin.  The Task sends
  messages to the GenServer when input arrives.

  `IO.gets(:stdio, "")` blocks until a newline is available.  This is correct
  behavior — we want to wait for client messages.

  ## Security

  Stdio connections are trusted by default (they are local processes launched
  by the user).  No authentication is required.

  ## EOF handling

  When the MCP client closes the connection (process exit, user ctrl-C), stdin
  returns `:eof`.  The transport exits cleanly and stops the application.
  """

  use GenServer
  require Logger

  alias DesignatorInator.MCP.Protocol
  alias DesignatorInator.Types.MCPMessage

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts the stdio transport.

  Spawns a reader Task that blocks on stdin.  Messages are dispatched to
  `MCPGateway` for processing and responses are written to stdout.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # Template:
    # 1. Start the reader task: Task.start_link(fn -> read_loop(self()) end)
    # 2. Return {:ok, %{reader_pid: task_pid}}
    parent_pid = self()
    {:ok, reader_pid} = Task.start_link(fn -> read_loop(parent_pid) end)
    {:ok, %{reader_pid: reader_pid}}
  end

  @impl GenServer
  def handle_info({:mcp_message, json_string}, state) do
    # Template:
    # 1. Protocol.parse_message(json_string)
    # 2. On {:ok, msg}: dispatch to MCPGateway.handle_request(msg)
    # 3. Encode response and write_message(response_json)
    # 4. On {:error, :invalid_json}: write a parse error response
    case Protocol.parse_message(json_string) do
      {:ok, %MCPMessage{} = msg} ->
        case gateway_module().handle_request(msg) do
          %MCPMessage{} = response ->
            {:ok, response_json} = Protocol.encode_message(response)
            write_message(response_json)
            {:noreply, state}

          nil ->
            {:noreply, state}
        end

      {:error, :invalid_json} ->
        response = Protocol.make_error(nil, -32700, "Parse error")
        {:ok, response_json} = Protocol.encode_message(response)
        write_message(response_json)
        {:noreply, state}

      {:error, :invalid_jsonrpc} ->
        response = Protocol.make_error(nil, -32600, "Invalid Request")
        {:ok, response_json} = Protocol.encode_message(response)
        write_message(response_json)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:eof, state) do
    # Template: Log "MCP client disconnected", stop the application
    Logger.info("MCP stdio client disconnected — exiting")
    stop_fun().(0)
    {:noreply, state}
  end

  # ── Pure I/O helpers ─────────────────────────────────────────────────────────

  @doc """
  Reads one newline-delimited JSON message from stdin.

  ## Examples

      # Blocking read — returns when a full line is available
      iex> DesignatorInator.MCP.Transport.Stdio.read_message()
      {:ok, ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"})}

      iex> DesignatorInator.MCP.Transport.Stdio.read_message()
      :eof
  """
  @spec read_message() :: {:ok, String.t()} | :eof | {:error, term()}
  def read_message do
    # Template:
    # IO.gets("") returns a string with a trailing newline, or :eof
    # String.trim the newline and return {:ok, trimmed} or :eof
    case IO.gets(:stdio, "") do
      :eof -> :eof
      data when is_binary(data) -> {:ok, String.trim_trailing(data)}
    end
  end

  @doc """
  Writes a JSON-encoded MCP message to stdout followed by a newline.

  ## Examples

      iex> DesignatorInator.MCP.Transport.Stdio.write_message(~s({"jsonrpc":"2.0","id":1,"result":{}}))
      :ok
  """
  @spec write_message(String.t()) :: :ok
  def write_message(json_string) do
    IO.puts(json_string)
  end

  defp gateway_module do
    Application.get_env(:designator_inator, :mcp_gateway_module, DesignatorInator.MCPGateway)
  end

  defp stop_fun do
    Application.get_env(:designator_inator, :mcp_stdio_stop_fun, &System.stop/1)
  end

  @doc false
  @spec read_loop(pid()) :: no_return()
  def read_loop(parent_pid) do
    # Template:
    # Infinite loop:
    # 1. read_message()
    # 2. On {:ok, json}: send(parent_pid, {:mcp_message, json}), loop
    # 3. On :eof: send(parent_pid, :eof), exit(:normal)
    # 4. On {:error, reason}: log and continue
    case read_message() do
      {:ok, json} ->
        send(parent_pid, {:mcp_message, json})
        read_loop(parent_pid)

      :eof ->
        send(parent_pid, :eof)
        exit(:normal)

      {:error, reason} ->
        Logger.warning("MCP stdio read error: #{inspect(reason)}")
        read_loop(parent_pid)
    end
  end
end
