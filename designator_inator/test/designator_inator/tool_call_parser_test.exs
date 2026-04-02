defmodule DesignatorInator.ToolCallParserTest do
  @moduledoc """
  Tests for the pluggable tool-call parsers.

  ## Testing strategy (HTDP step 6)

  Each parser is tested with:
  - A response containing one tool call (happy path)
  - A response containing multiple tool calls
  - A response with no tool calls (final answer)
  - A response with malformed JSON inside the tool call tag
  """

  use ExUnit.Case, async: true

  alias DesignatorInator.ToolCallParser
  alias DesignatorInator.ToolCallParser.{Llama3, ChatML}
  alias DesignatorInator.Types.ToolCall

  # ── Llama3 parser ─────────────────────────────────────────────────────────────

  describe "Llama3.parse/2" do
    test "parses a single tool call" do
      input = """
      <tool_call>
      {"name": "workspace", "arguments": {"action": "list"}}
      </tool_call>
      """

      assert [%ToolCall{name: "workspace", arguments: %{"action" => "list"}}] =
        Llama3.parse(input, "t1")
    end

    test "parses multiple tool calls" do
      input = """
      <tool_call>
      {"name": "read_file", "arguments": {"path": "a.txt"}}
      </tool_call>
      <tool_call>
      {"name": "read_file", "arguments": {"path": "b.txt"}}
      </tool_call>
      """

      assert [first, second] = Llama3.parse(input, "t1")
      assert first.name == "read_file"
      assert second.name == "read_file"
      assert first.id != second.id
    end

    test "returns empty list for plain text response" do
      assert [] = Llama3.parse("The files are: notes.md", "t1")
    end

    test "skips malformed JSON inside tool_call tag" do
      input = "<tool_call>not valid json</tool_call>"
      assert [] = Llama3.parse(input, "t1")
    end

    test "assigns unique IDs with prefix" do
      input = "<tool_call>\n{\"name\": \"foo\", \"arguments\": {}}\n</tool_call>"
      [call] = Llama3.parse(input, "turn_3")
      assert String.starts_with?(call.id, "turn_3")
    end
  end

  # ── ChatML parser ─────────────────────────────────────────────────────────────

  describe "ChatML.parse/2" do
    test "parses tool calls from ChatML format" do
      input = """
      <|tool_calls|>
      [{"name": "workspace", "arguments": {"action": "read", "path": "notes.md"}}]
      <|end_tool_calls|>
      """

      assert [%ToolCall{name: "workspace"}] = ChatML.parse(input, "t1")
    end

    test "returns empty list for plain text" do
      assert [] = ChatML.parse("Here is my answer.", "t1")
    end

    test "handles missing closing tag" do
      input = "<|tool_calls|>\n[{\"name\": \"ping\", \"arguments\": {}}]"
      assert [%ToolCall{name: "ping"}] = ChatML.parse(input, "t1")
    end
  end

  # ── Dispatcher ────────────────────────────────────────────────────────────────

  describe "ToolCallParser.parse/3" do
    test "dispatches to llama3 parser" do
      input = "<tool_call>\n{\"name\": \"foo\", \"arguments\": {}}\n</tool_call>"
      assert [%ToolCall{}] = ToolCallParser.parse(input, :llama3, "t1")
    end

    test "dispatches to chatml parser" do
      input = "<|tool_calls|>\n[{\"name\": \"foo\", \"arguments\": {}}]"
      assert [%ToolCall{}] = ToolCallParser.parse(input, :chatml, "t1")
    end

    test "accepts a module directly" do
      input = "<tool_call>\n{\"name\": \"foo\", \"arguments\": {}}\n</tool_call>"
      assert [%ToolCall{}] = ToolCallParser.parse(input, DesignatorInator.ToolCallParser.Llama3, "t1")
    end
  end
end
