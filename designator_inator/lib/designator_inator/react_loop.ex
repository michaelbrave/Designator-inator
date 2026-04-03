defmodule DesignatorInator.ReActLoop do
  @moduledoc """
  The core agent reasoning loop: Reason → Act → Observe → repeat.

  ## Algorithm (HTDP step 1 — data and process definition)

  The ReAct loop is a state machine over `DesignatorInator.Types.ReActState`:

      :thinking → model call → response has tool calls? → :tool_calling
                                                        ↘ no tool calls → :done

      :tool_calling → execute all tool calls → append results → :thinking

      :done → return {:ok, result}
      :error | :max_iterations → return {:error, reason}

  Each iteration:
  1. Call `inference_fn.(state.messages, opts)` to get the model's response
  2. Parse tool calls from the response text using the configured parser
  3. If tool calls found: execute each, append results, loop back to step 1
  4. If no tool calls: the response is the final answer — return it

  ## Inputs and outputs (HTDP step 2)

  - Input:
    - `initial_messages` — `[Message.t()]` — the system prompt + user request
    - `available_tools` — `[ToolDefinition.t()]` — tools the LLM can call
    - `tool_executor` — `(ToolCall.t() -> ToolResult.t())` — how to run a tool
    - `inference_fn` — `([Message.t()], keyword() -> {:ok, String.t()} | {:error, term()})`
    - `opts` — keyword list of options (see below)
  - Output: `{:ok, final_answer_text} | {:error, reason}`

  ## Options

  - `:pod_name` — `String.t()` (for logging)
  - `:session_id` — `String.t()`
  - `:max_iterations` — `pos_integer()` (default from config)
  - `:tool_call_format` — `:llama3 | :chatml` (default `:llama3`)

  ## Examples

      iex> DesignatorInator.ReActLoop.run(
      ...>   [
      ...>     %Message{role: :system, content: "You are helpful."},
      ...>     %Message{role: :user, content: "List the files in my workspace."}
      ...>   ],
      ...>   [%ToolDefinition{name: "workspace", ...}],
      ...>   fn call -> DesignatorInator.Tools.Workspace.call(call.arguments) end,
      ...>   fn msgs, _opts -> ModelManager.complete(msgs, model: "mistral-7b") end,
      ...>   pod_name: "assistant", session_id: "abc"
      ...> )
      {:ok, "Your workspace contains: notes.md, plan.md"}
  """

  require Logger

  alias DesignatorInator.ToolCallParser
  alias DesignatorInator.Types.{Message, ToolCall, ToolDefinition, ToolResult, ReActState}

  @doc """
  Runs the ReAct loop until the model produces a final answer or an error occurs.

  See module doc for full description of arguments.

  ## Examples

      iex> DesignatorInator.ReActLoop.run(messages, tools, executor, inference_fn, pod_name: "test")
      {:ok, "The answer is 42."}

      # Model called a tool that failed, then gave up after max_iterations
      iex> DesignatorInator.ReActLoop.run(messages, tools, executor, inference_fn,
      ...>   max_iterations: 3, pod_name: "test")
      {:error, :max_iterations}
  """
  @spec run(
          [Message.t()],
          [ToolDefinition.t()],
          (ToolCall.t() -> ToolResult.t()),
          ([Message.t()], keyword() -> {:ok, String.t()} | {:error, term()}),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def run(initial_messages, available_tools, tool_executor, inference_fn, opts \\ []) do
    pod_name = Keyword.get(opts, :pod_name, "unknown")
    session_id = Keyword.get(opts, :session_id, "unknown")
    max_iterations = Keyword.get(opts, :max_iterations, 20)
    tool_call_format = Keyword.get(opts, :tool_call_format, :llama3)

    messages =
      case format_tools_prompt(available_tools, tool_call_format) do
        "" -> initial_messages
        tools_prompt -> inject_tools_prompt(initial_messages, tools_prompt)
      end

    state = %ReActState{
      pod_name: pod_name,
      session_id: session_id,
      messages: messages,
      status: :thinking,
      iterations: 0,
      max_iterations: max_iterations
    }

    final_state = loop(state, available_tools, tool_executor, inference_fn, tool_call_format)

    case final_state.status do
      :done -> {:ok, final_state.result}
      :error -> {:error, final_state.error}
      :max_iterations -> {:error, :max_iterations}
      other -> {:error, other}
    end
  end

  @doc """
  Executes one iteration of the loop: call the model, parse the response,
  either execute tools or mark done.

  Returns the updated `ReActState`. The caller loops until `status` is terminal.

  ## Examples

      # Model responds with a tool call → status becomes :thinking after execution
      iex> state = %ReActState{status: :thinking, messages: [...], iterations: 0, ...}
      iex> DesignatorInator.ReActLoop.step(state, tools, executor, inference_fn)
      %ReActState{status: :thinking, iterations: 1, messages: [...tool result appended...]}

      # Model responds with final text → status becomes :done
      iex> DesignatorInator.ReActLoop.step(state, tools, executor, inference_fn)
      %ReActState{status: :done, result: "The answer is 42."}
  """
  @spec step(
          ReActState.t(),
          [ToolDefinition.t()],
          (ToolCall.t() -> ToolResult.t()),
          ([Message.t()], keyword() -> {:ok, String.t()} | {:error, term()})
        ) :: ReActState.t()
  def step(state, available_tools, tool_executor, inference_fn) do
    do_step(state, available_tools, tool_executor, inference_fn, :llama3)
  end

  @doc """
  Formats `available_tools` into a text description injected into the system prompt.

  The exact format depends on `tool_call_format`. The goal is to tell the model:
  - What tools exist
  - What parameters each tool takes
  - How to invoke them (what syntax to use)

  ## Examples

      iex> prompt = DesignatorInator.ReActLoop.format_tools_prompt(
      ...>   [%ToolDefinition{name: "workspace", description: "...", parameters: %{...}}],
      ...>   :llama3
      ...> )
      iex> prompt =~ "You have access to the following tools:"
      true
      iex> prompt =~ "<tool_call>"
      true
  """
  @spec format_tools_prompt([ToolDefinition.t()], atom()) :: String.t()
  def format_tools_prompt(available_tools, format) do
    if available_tools == [] do
      ""
    else
      tool_lines =
        Enum.map(available_tools, fn tool ->
          params =
            tool.parameters
            |> Enum.map(fn {name, schema} ->
              required = if Map.get(schema, :required, false), do: "required", else: "optional"
              type = Map.get(schema, :type, :string)
              description = Map.get(schema, :description, "")
              enum = Map.get(schema, :enum)
              enum_text = if is_list(enum), do: ", enum: #{Enum.join(enum, ", ")}", else: ""
              "  - #{name} (#{required}, #{type}): #{description}#{enum_text}"
            end)
            |> Enum.join("\n")

          "- #{tool.name}: #{tool.description}\n#{params}"
        end)

      invocation =
        case format do
          :chatml ->
            "To use a tool, respond with:\n<|tool_calls|>\n[{\"name\": \"tool_name\", \"arguments\": {\"param\": \"value\"}}]\n<|end_tool_calls|>"

          _ ->
            "To use a tool, respond with:\n<tool_call>\n{\"name\": \"tool_name\", \"arguments\": {\"param\": \"value\"}}\n</tool_call>"
        end

      ["You have access to the following tools:", Enum.join(tool_lines, "\n\n"), invocation]
      |> Enum.join("\n\n")
    end
  end

  @doc """
  Converts a `ToolResult` into a `:tool` role `Message` to append to the
  conversation.

  ## Examples

      iex> DesignatorInator.ReActLoop.tool_result_to_message(
      ...>   %ToolResult{tool_call_id: "c1", content: "notes.md\\nplan.md", is_error: false}
      ...> )
      %Message{role: :tool, content: "notes.md\\nplan.md", tool_call_id: "c1"}

      iex> DesignatorInator.ReActLoop.tool_result_to_message(
      ...>   %ToolResult{tool_call_id: "c1", content: "File not found", is_error: true}
      ...> )
      %Message{role: :tool, content: "Error: File not found", tool_call_id: "c1"}
  """
  @spec tool_result_to_message(ToolResult.t()) :: Message.t()
  def tool_result_to_message(%ToolResult{is_error: true} = result) do
    %Message{role: :tool, content: "Error: #{result.content}", tool_call_id: result.tool_call_id}
  end

  def tool_result_to_message(%ToolResult{} = result) do
    %Message{role: :tool, content: result.content, tool_call_id: result.tool_call_id}
  end

  defp loop(%ReActState{status: status} = state, _tools, _executor, _inference_fn, _format)
       when status in [:done, :error, :max_iterations],
       do: state

  defp loop(state, available_tools, tool_executor, inference_fn, format) do
    next_state = do_step(state, available_tools, tool_executor, inference_fn, format)

    if next_state.status in [:done, :error, :max_iterations] do
      next_state
    else
      loop(next_state, available_tools, tool_executor, inference_fn, format)
    end
  end

  defp do_step(%ReActState{iterations: iterations, max_iterations: max} = state, _tools, _executor, _inference_fn, _format)
       when iterations >= max do
    %{state | status: :max_iterations}
  end

  defp do_step(state, _available_tools, tool_executor, inference_fn, format) do
    case inference_fn.(state.messages, tool_call_format: format) do
      {:error, reason} ->
        %{state | status: :error, error: inspect(reason)}

      {:ok, text} ->
        call_id_prefix = "#{state.pod_name}_#{state.session_id}_#{state.iterations}"
        tool_calls = ToolCallParser.parse(text, format, call_id_prefix)
        assistant_message = %Message{role: :assistant, content: assistant_content(text, tool_calls), tool_calls: tool_calls}
        messages = state.messages ++ [assistant_message]

        if tool_calls == [] do
          %{state | status: :done, result: text, messages: messages}
        else
          tool_messages =
            tool_calls
            |> Task.async_stream(
              fn call -> {call, tool_executor.(call)} end,
              max_concurrency: max(1, length(tool_calls)),
              ordered: true,
              timeout: 120_000
            )
            |> Enum.map(fn
              {:ok, {call, %ToolResult{} = result}} ->
                tool_result_to_message(result)

              {:ok, {_call, %Message{} = message}} ->
                message

              {:ok, {call, other}} ->
                %Message{role: :tool, content: inspect(other), tool_call_id: call.id}

              {:exit, reason} ->
                %Message{role: :tool, content: "Error: #{inspect(reason)}", tool_call_id: nil}
            end)

          %{state | status: :thinking, iterations: state.iterations + 1, messages: messages ++ tool_messages}
        end
    end
  end

  defp assistant_content(text, []), do: text
  defp assistant_content(_text, _tool_calls), do: nil

  defp inject_tools_prompt(messages, tools_prompt) do
    case messages do
      [%Message{role: :system, content: content} = system | rest] ->
        [%Message{system | content: merge_prompt(content, tools_prompt)} | rest]

      _ ->
        [%Message{role: :system, content: tools_prompt} | messages]
    end
  end

  defp merge_prompt(nil, tools_prompt), do: tools_prompt
  defp merge_prompt(content, tools_prompt), do: content <> "\n\n" <> tools_prompt
end
