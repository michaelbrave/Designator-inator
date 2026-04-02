defmodule ForgeClaw.MCP.Transport.SSE do
  @moduledoc """
  MCP transport over HTTP Server-Sent Events (SSE).

  ## How it works (HTDP step 1)

  The SSE transport exposes two HTTP endpoints via Bandit + Plug:

  - `GET /sse` — client connects and receives a stream of SSE events.
    The server sends an initial `endpoint` event telling the client where
    to POST messages.
  - `POST /message` — client sends MCP requests here.  Server processes them
    and pushes responses back over the SSE stream.

  This allows browser-based clients and remote connections (unlike stdio which
  is local-only).

  ## Authentication

  HTTP clients must include `Authorization: Bearer <token>` in all requests.
  Tokens are managed in `~/.forgeclaw/tokens.yaml`.
  Stdio connections are trust by default; SSE connections require auth.

  ## SSE event format

      data: {"jsonrpc":"2.0","id":1,"result":{"tools":[...]}}\n\n

  ## Connection tracking

  Each SSE client connection gets a unique connection ID.  The `MCPGateway`
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

  alias ForgeClaw.MCP.Protocol

  plug Plug.Logger
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  # ── HTTP endpoints ────────────────────────────────────────────────────────────

  get "/sse" do
    # Template (HTDP step 4):
    # 1. Authenticate: check Authorization header against tokens file
    # 2. On failure: send 401
    # 3. Generate connection_id = Uniq.UUID.uuid4()
    # 4. Set SSE headers: content-type: text/event-stream, cache-control: no-cache
    # 5. Send initial "endpoint" event: data: /message?conn=<connection_id>
    # 6. Register the connection's send_fn in MCPGateway
    # 7. Enter a loop that waits for :send_event messages and writes them to the client
    # 8. On client disconnect: deregister connection from MCPGateway
    raise "not implemented"
  end

  post "/message" do
    # Template (HTDP step 4):
    # 1. Authenticate
    # 2. Extract connection_id from query param
    # 3. Parse body as MCPMessage via Protocol.parse_message
    # 4. Dispatch to MCPGateway.handle_request/1 (it will push response to SSE stream)
    # 5. Return 202 Accepted immediately (response comes via SSE)
    raise "not implemented"
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  # ── Authentication ────────────────────────────────────────────────────────────

  @doc """
  Verifies the Bearer token in the request against stored tokens.

  Returns `:ok` if authenticated, `{:error, :unauthorized}` if not.

  ## Examples

      iex> ForgeClaw.MCP.Transport.SSE.authenticate(conn)
      :ok

      iex> ForgeClaw.MCP.Transport.SSE.authenticate(conn_with_bad_token)
      {:error, :unauthorized}
  """
  @spec authenticate(Plug.Conn.t()) :: :ok | {:error, :unauthorized}
  def authenticate(conn) do
    # Template (HTDP step 4):
    # 1. Extract Authorization header: get_req_header(conn, "authorization")
    # 2. Parse: "Bearer <token>"
    # 3. Load tokens from tokens file: read and parse YAML/text
    # 4. If token found in list: :ok
    # 5. Otherwise: {:error, :unauthorized}
    raise "not implemented"
  end
end
