defmodule ForgeClaw.ReActLoopTest do
  @moduledoc """
  Tests for `ForgeClaw.ReActLoop`.

  ## Testing strategy (HTDP step 6)

  The loop is pure logic — we inject mock inference functions and tool executors
  so tests run without a real LLM or filesystem.

  Key scenarios:
  1. Model answers directly (no tool calls) → {:ok, answer}
  2. Model calls one tool, then answers → tool is executed, result fed back
  3. Model calls tool whose result triggers another tool call → multi-turn works
  4. Max iterations reached → {:error, :max_iterations}
  5. Inference error → {:error, reason}
  """

  use ExUnit.Case, async: true

  alias ForgeClaw.ReActLoop
  alias ForgeClaw.Types.{Message, ToolCall, ToolResult, ToolDefinition}
  alias ForgeClaw.Test.Fixtures

  defp stub_inference(response_text) do
    fn _messages, _opts -> {:ok, response_text} end
  end

  defp always_ok_tool do
    fn %ToolCall{name: name, arguments: args, id: id} ->
      %ToolResult{tool_call_id: id, content: "Result of #{name}(#{inspect(args)})", is_error: false}
    end
  end

  # ── Direct answer (no tool calls) ────────────────────────────────────────────

  describe "run/5 — direct answer" do
    test "returns the model's response when no tool calls are made" do
      messages = [Fixtures.system_message(), Fixtures.user_message("What is 2+2?")]
      inference = stub_inference("4")

      assert {:ok, "4"} = ReActLoop.run(messages, [], always_ok_tool(), inference,
        pod_name: "test", session_id: "s1", tool_call_format: :llama3)
    end
  end

  # ── Single tool call ─────────────────────────────────────────────────────────

  describe "run/5 — single tool call" do
    test "executes a tool call and feeds result back" do
      messages = [Fixtures.system_message(), Fixtures.user_message("List my files")]

      # First call: model produces a tool call. Second call: model answers.
      call_count = :counters.new(1, [])

      inference = fn _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case count do
          0 ->
            {:ok, "<tool_call>\n{\"name\": \"workspace\", \"arguments\": {\"action\": \"list\"}}\n</tool_call>"}
          _ ->
            {:ok, "Your workspace contains: notes.md"}
        end
      end

      tools = [Fixtures.workspace_tool_definition()]
      executor = fn %ToolCall{id: id} ->
        %ToolResult{tool_call_id: id, content: "notes.md\nplan.md", is_error: false}
      end

      assert {:ok, answer} = ReActLoop.run(messages, tools, executor, inference,
        pod_name: "test", session_id: "s1", tool_call_format: :llama3)
      assert answer =~ "workspace"
    end
  end

  # ── Max iterations ────────────────────────────────────────────────────────────

  describe "run/5 — max iterations" do
    test "stops after max_iterations with error" do
      # Inference always returns a tool call, so the loop never finishes
      tool_call_response =
        "<tool_call>\n{\"name\": \"workspace\", \"arguments\": {\"action\": \"list\"}}\n</tool_call>"

      messages = [Fixtures.system_message(), Fixtures.user_message("Loop forever")]
      inference = stub_inference(tool_call_response)
      tools = [Fixtures.workspace_tool_definition()]
      executor = always_ok_tool()

      assert {:error, :max_iterations} = ReActLoop.run(messages, tools, executor, inference,
        pod_name: "test", session_id: "s1", max_iterations: 3, tool_call_format: :llama3)
    end
  end

  # ── Inference error ───────────────────────────────────────────────────────────

  describe "run/5 — inference failure" do
    test "returns error when inference fails" do
      messages = [Fixtures.system_message(), Fixtures.user_message("Hello")]
      inference = fn _messages, _opts -> {:error, :timeout} end

      assert {:error, _} = ReActLoop.run(messages, [], always_ok_tool(), inference,
        pod_name: "test", session_id: "s1")
    end
  end

  # ── tool_result_to_message/1 ──────────────────────────────────────────────────

  describe "tool_result_to_message/1" do
    test "wraps successful result" do
      result = %ToolResult{tool_call_id: "c1", content: "notes.md", is_error: false}
      msg = ReActLoop.tool_result_to_message(result)
      assert msg.role == :tool
      assert msg.content == "notes.md"
      assert msg.tool_call_id == "c1"
    end

    test "prefixes error results" do
      result = %ToolResult{tool_call_id: "c1", content: "Not found", is_error: true}
      msg = ReActLoop.tool_result_to_message(result)
      assert msg.content =~ "Error:"
    end
  end
end
