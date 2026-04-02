defmodule DesignatorInator.MemoryTest do
  use ExUnit.Case, async: false

  alias DesignatorInator.Memory
  alias DesignatorInator.Memory.{Repo, ConversationMessage}
  alias DesignatorInator.Types.Message

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  describe "save_message/3" do
    test "persists a message with role, content, and tool calls" do
      message = %Message{
        role: :assistant,
        content: nil,
        tool_calls: [%{id: "c1", name: "workspace", arguments: %{"action" => "list"}}]
      }

      assert {:ok, %ConversationMessage{} = record} =
               Memory.save_message("assistant-pod", "session-1", message)

      assert record.pod_name == "assistant-pod"
      assert record.session_id == "session-1"
      assert record.role == "assistant"
      assert record.tool_calls =~ "workspace"
    end
  end

  describe "load_history/3" do
    test "returns messages in chronological order and decodes tool calls" do
      {:ok, _} =
        Memory.save_message("assistant-pod", "session-2", %Message{role: :user, content: "hello"})

      {:ok, _} =
        Memory.save_message("assistant-pod", "session-2", %Message{role: :assistant, content: "hi"})

      {:ok, _} =
        Memory.save_message("assistant-pod", "session-2", %Message{
          role: :assistant,
          content: nil,
          tool_calls: [%{id: "c1", name: "workspace", arguments: %{"action" => "list"}}]
        })

      history = Memory.load_history("assistant-pod", "session-2", 10)

      assert [
               %Message{role: :user, content: "hello"},
               %Message{role: :assistant, content: "hi"},
               %Message{role: :assistant, tool_calls: [%{"name" => "workspace", "arguments" => %{"action" => "list"}}]}
             ] = history
    end
  end

  describe "list_sessions/1" do
    test "returns distinct session ids for a pod" do
      {:ok, _} = Memory.save_message("assistant-pod", "session-a", %Message{role: :user, content: "a"})
      {:ok, _} = Memory.save_message("assistant-pod", "session-b", %Message{role: :user, content: "b"})
      {:ok, _} = Memory.save_message("other-pod", "session-z", %Message{role: :user, content: "z"})

      assert Memory.list_sessions("assistant-pod") == ["session-a", "session-b"]
      assert Memory.list_sessions("other-pod") == ["session-z"]
    end
  end

  describe "clear_session/2" do
    test "deletes all messages for a session" do
      {:ok, _} = Memory.save_message("assistant-pod", "session-clear", %Message{role: :user, content: "keep?"})

      assert :ok = Memory.clear_session("assistant-pod", "session-clear")
      assert Memory.load_history("assistant-pod", "session-clear", 10) == []
    end
  end

  describe "new_session_id/0" do
    test "returns a UUID-like string" do
      id = Memory.new_session_id()
      assert is_binary(id)
      assert String.length(id) == 36
    end
  end
end
