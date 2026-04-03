defmodule DesignatorInator.ReActLoopTest do
  use ExUnit.Case, async: false

  alias DesignatorInator.ReActLoop
  alias DesignatorInator.Types.{Message, ToolCall, ToolDefinition, ToolResult}

  test "executes multiple tool calls concurrently" do
    tool_calls_response = """
    <tool_call>
    {"name": "alpha", "arguments": {"value": 1}}
    </tool_call>
    <tool_call>
    {"name": "beta", "arguments": {"value": 2}}
    </tool_call>
    """

    inference_fn = fn
      [_system, _user], _opts -> {:ok, tool_calls_response}
      [_system, _user, _assistant, _tool_a, _tool_b], _opts -> {:ok, "final answer"}
    end

    parent = self()

    tool_executor = fn %ToolCall{name: name, id: id} ->
      task_pid = self()
      send(parent, {:tool_started, name, task_pid})

      receive do
        {:release, ^task_pid} ->
          send(parent, {:tool_released, name})
          %ToolResult{tool_call_id: id, content: "#{name}-done", is_error: false}
      after
        1_000 ->
          flunk("tool #{name} never received release signal")
      end
    end

    runner = Task.async(fn ->
      ReActLoop.run(
        [%Message{role: :system, content: "You are helpful."}, %Message{role: :user, content: "do the thing"}],
        [tool_definition("alpha"), tool_definition("beta")],
        tool_executor,
        inference_fn,
        pod_name: "orchestrator",
        session_id: "session-1",
        tool_call_format: :llama3,
        max_iterations: 4
      )
    end)

    assert_receive {:tool_started, "alpha", alpha_pid}
    assert_receive {:tool_started, "beta", beta_pid}

    refute alpha_pid == beta_pid

    send(alpha_pid, {:release, alpha_pid})
    send(beta_pid, {:release, beta_pid})

    assert {:ok, "final answer"} = Task.await(runner, 5_000)
  end

  defp tool_definition(name) do
    %ToolDefinition{name: name, description: name, parameters: %{}}
  end
end
