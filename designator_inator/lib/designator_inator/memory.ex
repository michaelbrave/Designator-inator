defmodule DesignatorInator.Memory do
  @moduledoc """
  Ecto-backed conversation memory for agent pods.

  ## Data definitions (HTDP step 1)

  Every message sent or received by a pod is persisted as a `ConversationMessage`
  record.  The combination of `pod_name` and `session_id` identifies one
  conversation thread.

  When a pod starts a new request, it calls `load_history/3` to fetch recent
  turns and prepend them to the context window.  This gives the agent memory
  across separate `complete/2` calls.

  ## Schema

  See `DesignatorInator.Memory.ConversationMessage` for the Ecto schema.

  ## Session IDs

  Session IDs are UUIDs.  The caller (CLI, MCP gateway, orchestrator) provides
  a session ID or calls `new_session_id/0` to start a fresh conversation.
  The same session ID can span multiple requests — the pod will remember
  earlier turns.
  """

  import Ecto.Query

  alias DesignatorInator.Memory.{Repo, ConversationMessage}
  alias DesignatorInator.Types.Message

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Persists a single message to the database.

  ## Examples

      iex> DesignatorInator.Memory.save_message(
      ...>   "assistant-pod",
      ...>   "550e8400-e29b-41d4-a716-446655440000",
      ...>   %Message{role: :user, content: "Hello"}
      ...> )
      {:ok, %ConversationMessage{}}
  """
  @spec save_message(String.t(), String.t(), Message.t()) ::
          {:ok, ConversationMessage.t()} | {:error, Ecto.Changeset.t()}
  def save_message(pod_name, session_id, %Message{} = message) do
    attrs = %{
      pod_name: pod_name,
      session_id: session_id,
      role: Atom.to_string(message.role),
      content: message.content,
      tool_calls: encode_tool_calls(message.tool_calls),
      tool_call_id: message.tool_call_id
    }

    struct(ConversationMessage)
    |> ConversationMessage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Loads the most recent `limit` turns for a session, oldest first.

  Returns `Message` structs ready to prepend to the context window.

  ## Examples

      iex> DesignatorInator.Memory.load_history("my-pod", "session-uuid", 10)
      [
        %Message{role: :user, content: "What's the weather?"},
        %Message{role: :assistant, content: "I don't have live data..."}
      ]

      # No history yet
      iex> DesignatorInator.Memory.load_history("my-pod", "new-session", 10)
      []
  """
  @spec load_history(String.t(), String.t(), pos_integer()) :: [Message.t()]
  def load_history(pod_name, session_id, limit \\ 20) do
    ConversationMessage
    |> where([m], m.pod_name == ^pod_name and m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&message_from_record/1)
  end

  @doc """
  Generates a fresh UUID for use as a session ID.

  ## Examples

      iex> DesignatorInator.Memory.new_session_id()
      "550e8400-e29b-41d4-a716-446655440000"
  """
  @spec new_session_id() :: String.t()
  def new_session_id do
    Uniq.UUID.uuid4()
  end

  @doc """
  Returns all session IDs that have messages for a given pod.

  ## Examples

      iex> DesignatorInator.Memory.list_sessions("my-pod")
      ["550e8400-...", "661f9511-..."]

      iex> DesignatorInator.Memory.list_sessions("new-pod")
      []
  """
  @spec list_sessions(String.t()) :: [String.t()]
  def list_sessions(pod_name) do
    ConversationMessage
    |> where([m], m.pod_name == ^pod_name)
    |> select([m], m.session_id)
    |> distinct(true)
    |> order_by([m], asc: m.session_id)
    |> Repo.all()
  end

  @doc """
  Deletes all messages for a session.  Used when a user wants to start fresh.

  ## Examples

      iex> DesignatorInator.Memory.clear_session("my-pod", "session-uuid")
      :ok
  """
  @spec clear_session(String.t(), String.t()) :: :ok
  def clear_session(pod_name, session_id) do
    ConversationMessage
    |> where([m], m.pod_name == ^pod_name and m.session_id == ^session_id)
    |> Repo.delete_all()

    :ok
  end

  defp encode_tool_calls(nil), do: nil
  defp encode_tool_calls(calls), do: Jason.encode!(calls)

  defp message_from_record(record) do
    %Message{
      role: String.to_existing_atom(record.role),
      content: record.content,
      tool_calls: decode_tool_calls(record.tool_calls),
      tool_call_id: record.tool_call_id
    }
  end

  defp decode_tool_calls(nil), do: nil
  defp decode_tool_calls(json) do
    case Jason.decode(json) do
      {:ok, calls} -> calls
      {:error, _} -> nil
    end
  end
end

defmodule DesignatorInator.Memory.Repo do
  @moduledoc "Ecto SQLite repository for DesignatorInator conversation memory."
  use Ecto.Repo,
    otp_app: :designator_inator,
    adapter: Ecto.Adapters.SQLite3
end

defmodule DesignatorInator.Memory.ConversationMessage do
  @moduledoc """
  ## Data Definition (Ecto Schema)

  Persisted record of a single message in a pod conversation.

  | Column        | Type         | Meaning                                        |
  |---------------|--------------|------------------------------------------------|
  | `id`          | `integer`    | Auto-increment primary key                     |
  | `pod_name`    | `string`     | Which pod this message belongs to              |
  | `session_id`  | `string`     | UUID grouping a conversation thread            |
  | `role`        | `string`     | `"system" | "user" | "assistant" | "tool"`     |
  | `content`     | `string`     | Text content (nullable for tool-call messages) |
  | `tool_calls`  | `string`     | JSON-encoded `[ToolCall.t()]` or null          |
  | `tool_call_id`| `string`     | For tool-result messages: which call this is   |
  | `inserted_at` | `utc_datetime`| Used for ordering and LRU history loading     |

  ## Examples

      iex> %DesignatorInator.Memory.ConversationMessage{
      ...>   pod_name: "code-reviewer",
      ...>   session_id: "550e8400-e29b-41d4-a716-446655440000",
      ...>   role: "user",
      ...>   content: "Please review this function."
      ...> }
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          pod_name: String.t(),
          session_id: String.t(),
          role: String.t(),
          content: String.t() | nil,
          tool_calls: String.t() | nil,
          tool_call_id: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "conversation_messages" do
    field :pod_name, :string
    field :session_id, :string
    field :role, :string
    field :content, :string
    field :tool_calls, :string
    field :tool_call_id, :string
    timestamps(type: :utc_datetime)
  end

  @required_fields [:pod_name, :session_id, :role]
  @optional_fields [:content, :tool_calls, :tool_call_id]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message \\ %__MODULE__{}, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:role, ["system", "user", "assistant", "tool"])
  end
end
