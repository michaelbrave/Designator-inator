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

  alias DesignatorInator.Types.{Message, ToolCall, ToolResult, ToolDefinition, ReActState}

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
    # Template (HTDP step 4):
    # 1. Build initial %ReActState{} from opts and initial_messages
    # 2. Build tools_prompt: format available_tools as a text block to inject
    #    into the system message (or append as a user message for some formats)
    # 3. Call step/4 recursively until state.status is :done, :error, or :max_iterations
    # 4. Map final state to {:ok, state.result} or {:error, state.error | :max_iterations}
    raise "not implemented"
  end

  @doc """
  Executes one iteration of the loop: call the model, parse the response,
  either execute tools or mark done.

  Returns the updated `ReActState`.  The caller loops until `status` is terminal.

  ## Examples

      # Model responds with a tool call → status becomes :tool_calling then :thinking
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
    # Template (HTDP step 4):
    # 1. Guard: if state.iterations >= state.max_iterations,
    #    return %{state | status: :max_iterations}
    # 2. Call inference_fn.(state.messages, []) → {:ok, text} | {:error, reason}
    # 3. On {:error, reason}: return %{state | status: :error, error: inspect(reason)}
    # 4. Append assistant message to state.messages
    # 5. Parse tool calls: ToolCallParser.parse(text, format, call_id_prefix)
    # 6. If tool_calls is empty: return %{state | status: :done, result: text}
    # 7. If tool_calls present:
    #    a. Execute each call with tool_executor.(call)
    #    b. Append each result as a :tool Message
    #    c. Return %{state | status: :thinking, iterations: state.iterations + 1, messages: ...}
    raise "not implemented"
  end

  @doc """
  Formats `available_tools` into a text description injected into the system prompt.

  The exact format depends on `tool_call_format`.  The goal is to tell the model:
  - What tools exist
  - What parameters each tool takes
  - How to invoke them (what syntax to use)

  ## Examples

      iex> DesignatorInator.ReActLoop.format_tools_prompt(
      ...>   [%ToolDefinition{name: "workspace", description: "...", parameters: %{...}}],
      ...>   :llama3
      ...> )
      \"\"\"
      You have access to the following tools:

      - workspace: Read, write, and list files in the workspace.
        Parameters:
          - action (required, string): Operation: read, write, list, delete
          - path (optional, string): File path relative to workspace root
          ...

      To use a tool, respond with:
      <tool_call>
      {"name": "tool_name", "arguments": {"param": "value"}}
      </tool_call>
      \"\"\"
  """
  @spec format_tools_prompt([ToolDefinition.t()], atom()) :: String.t()
  def format_tools_prompt(available_tools, format) do
    # Template (HTDP step 4):
    # 1. If available_tools is empty: return ""
    # 2. Build a header line
    # 3. For each tool: format name, description, and parameters
    # 4. Append the invocation syntax for the given format
    raise "not implemented"
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
    %Message{
      role: :tool,
      content: "Error: #{result.content}",
      tool_call_id: result.tool_call_id
    }
  end

  def tool_result_to_message(%ToolResult{} = result) do
    %Message{
      role: :tool,
      content: result.content,
      tool_call_id: result.tool_call_id
    }
  end
end
