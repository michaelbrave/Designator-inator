defmodule DesignatorInator.MCP.Transport.SSE do
  @moduledoc """
  MCP transport over HTTP Server-Sent Events (SSE).

  ## How it works (HTDP step 1)

  The SSE transport exposes two HTTP endpoints via Bandit + Plug:

  - `GET /sse` — client connects and receives a stream of SSE events.
    The server sends an initial `endpoint` event telling the client where
    to POST messages.
  - `POST /message` — client sends MCP requests here. Server processes them
    and pushes responses back over the SSE stream.

  This allows browser-based clients and remote connections (unlike stdio which
  is local-only).

  ## Authentication

  HTTP clients must include `Authorization: Bearer <token>` in all requests.
  Tokens are managed in `~/.designator_inator/tokens.yaml`.
  Stdio connections are trusted by default; SSE connections require auth.

  ## SSE event format

      data: {"jsonrpc":"2.0","id":1,"result":{"tools":[...]}}\n\n
  ## Connection tracking

  Each SSE client connection gets a unique connection ID. The `MCPGateway`
  sends response messages to a specific connection ID so responses go back to
  the right client.

  ## Data definitions

      Connection:
        id: String.t()          — UUID
        send_fn: (map() -> :ok) — sends an event to the client's SSE stream
        authenticated: boolean()
  """

  use Plug.Router
  require Logger

  alias DesignatorInator.MCP.Protocol
  alias DesignatorInator.Types.MCPMessage

  plug Plug.Logger
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  @doc """
  Starts the SSE transport HTTP server.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, Application.get_env(:designator_inator, :mcp_http_port, 4000))
    Bandit.start_link(plug: __MODULE__, scheme: :http, port: port)
  end

  # ── HTTP endpoints ────────────────────────────────────────────────────────────

  get "/sse" do
    case authenticate(conn) do
      :ok ->
        connection_id = Uniq.UUID.uuid4()
        endpoint = "/message?conn=#{connection_id}"

        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        send_event = fn event -> send(self(), {:send_event, event}) end
        :ok = gateway_module().register_sse_connection(connection_id, send_event)

        {:ok, conn} = chunk(conn, sse_event("endpoint", endpoint))
        stream_loop(conn, connection_id)

      {:error, :unauthorized} ->
        send_resp(conn, 401, "Unauthorized")
    end
  end

  post "/message" do
    case authenticate(conn) do
      :ok ->
        connection_id = conn.params["conn"] || conn.query_params["conn"]

        case body_to_message(conn) do
          {:ok, %MCPMessage{} = message} ->
            maybe_dispatch_to_gateway(message, connection_id)
            send_resp(conn, 202, "Accepted")

          {:error, status, body} ->
            send_resp(conn, status, body)
        end

      {:error, :unauthorized} ->
        send_resp(conn, 401, "Unauthorized")
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  # ── Authentication ────────────────────────────────────────────────────────────

  @doc """
  Verifies the Bearer token in the request against stored tokens.

  Returns `:ok` if authenticated, `{:error, :unauthorized}` if not.

  ## Examples

      iex> DesignatorInator.MCP.Transport.SSE.authenticate(conn)
      :ok

      iex> DesignatorInator.MCP.Transport.SSE.authenticate(conn_with_bad_token)
      {:error, :unauthorized}
  """
  @spec authenticate(Plug.Conn.t()) :: :ok | {:error, :unauthorized}
  def authenticate(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        if token in allowed_tokens() do
          :ok
        else
          {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp allowed_tokens do
    case File.read(tokens_file()) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, tokens} -> normalize_tokens(tokens)
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  defp normalize_tokens(tokens) when is_list(tokens), do: Enum.flat_map(tokens, &normalize_tokens/1)
  defp normalize_tokens(tokens) when is_map(tokens), do: Enum.flat_map(Map.values(tokens), &normalize_tokens/1)
  defp normalize_tokens(token) when is_binary(token), do: [token]
  defp normalize_tokens(_), do: []

  defp tokens_file do
    Application.get_env(:designator_inator, :tokens_file, Path.expand("~/.designator_inator/tokens.yaml"))
  end

  defp gateway_module do
    Application.get_env(:designator_inator, :mcp_gateway_module, DesignatorInator.MCPGateway)
  end

  defp body_to_message(%Plug.Conn{body_params: %{} = body_params}) when map_size(body_params) > 0 do
    {:ok,
     %MCPMessage{
       id: body_params["id"],
       method: body_params["method"],
       params: body_params["params"] || %{},
       jsonrpc: body_params["jsonrpc"] || "2.0"
     }}
  end

  defp body_to_message(_conn), do: {:error, 400, "Parse error"}

  defp maybe_dispatch_to_gateway(%MCPMessage{} = message, nil) do
    _ = gateway_module().handle_request(message)
    :ok
  end

  defp maybe_dispatch_to_gateway(%MCPMessage{} = message, _connection_id) do
    _ = gateway_module().handle_request(message)
    :ok
  end

  defp sse_event(event, data) do
    ["event: ", event, "\n", "data: ", data, "\n\n"] |> IO.iodata_to_binary()
  end

  defp stream_loop(conn, connection_id) do
    receive do
      {:send_event, %MCPMessage{} = message} ->
        case Protocol.encode_message(message) do
          {:ok, json} ->
            {:ok, conn} = chunk(conn, sse_event("message", json))
            stream_loop(conn, connection_id)

          {:error, reason} ->
            Logger.warning("Failed to encode SSE message for #{connection_id}: #{inspect(reason)}")
            stream_loop(conn, connection_id)
        end

      {:send_event, event} when is_binary(event) ->
        {:ok, conn} = chunk(conn, sse_event("message", event))
        stream_loop(conn, connection_id)

      {:send_event, event} ->
        {:ok, conn} = chunk(conn, sse_event("message", inspect(event)))
        stream_loop(conn, connection_id)
    after
      15_000 ->
        stream_loop(conn, connection_id)
    end
  end
end
