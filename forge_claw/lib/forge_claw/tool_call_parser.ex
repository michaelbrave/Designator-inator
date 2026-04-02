defmodule ForgeClaw.ToolCallParser do
  @moduledoc """
  Behaviour for pluggable tool-call parsers.

  ## Why pluggable?

  Different GGUF models produce tool calls in different text formats.  There is
  no single standard.  Rather than hard-coding one format, parsers are modules
  that implement this behaviour.  Adding support for a new model family means
  adding one module.

  ## Built-in parsers

  | Module                               | Format        | Models           |
  |--------------------------------------|---------------|------------------|
  | `ForgeClaw.ToolCallParser.Llama3`    | Llama3 / Meta | Llama 3.x, Mistral Nemo |
  | `ForgeClaw.ToolCallParser.ChatML`    | ChatML        | Mistral, Qwen, Phi-3 |

  ## Parser selection

  The parser to use is specified per-pod in `config.yaml`:

      inference:
        tool_call_format: llama3   # or chatML, or a module name

  The `ReActLoop` calls `ForgeClaw.ToolCallParser.parse/3` which dispatches to
  the right parser.  Unknown formats default to `Llama3`.

  ## Data definitions (HTDP step 1)

  Input: raw model response text (`String.t()`)
  Output: `[ForgeClaw.Types.ToolCall.t()]` — zero or more calls parsed out

  If the model produced no tool calls (it wrote a final answer instead), the
  parser returns `[]`.  The `ReActLoop` treats an empty list as "done".
  """

  alias ForgeClaw.Types.ToolCall

  @doc """
  Parses tool calls out of `response_text` using `format`.

  `format` is an atom: `:llama3`, `:chatml`, or a module that implements this
  behaviour.

  Returns an empty list if no tool calls are found (the response is a final answer).

  ## Examples

      iex> ForgeClaw.ToolCallParser.parse(
      ...>   "<tool_call>\\n{\\"name\\": \\"read_file\\", \\"arguments\\": {\\"path\\": \\"notes.md\\"}}\\n</tool_call>",
      ...>   :llama3,
      ...>   "c1"
      ...> )
      [%ForgeClaw.Types.ToolCall{id: "c1_0", name: "read_file", arguments: %{"path" => "notes.md"}}]

      iex> ForgeClaw.ToolCallParser.parse("The answer is 42.", :llama3, "c1")
      []
  """
  @callback parse(response_text :: String.t(), call_id_prefix :: String.t()) :: [ToolCall.t()]

  @doc """
  Dispatches to the parser for `format`.

  `call_id_prefix` is used to build unique call IDs when the response contains
  multiple tool calls.

  ## Examples

      iex> ForgeClaw.ToolCallParser.parse("...", :llama3, "turn_3")
      [%ToolCall{...}]
  """
  @spec parse(String.t(), atom() | module(), String.t()) :: [ToolCall.t()]
  def parse(response_text, format, call_id_prefix) do
    parser_module = resolve_parser(format)
    parser_module.parse(response_text, call_id_prefix)
  end

  @doc false
  @spec resolve_parser(atom() | module()) :: module()
  def resolve_parser(:llama3), do: ForgeClaw.ToolCallParser.Llama3
  def resolve_parser(:chatml), do: ForgeClaw.ToolCallParser.ChatML
  def resolve_parser(module) when is_atom(module), do: module
end

defmodule ForgeClaw.ToolCallParser.Llama3 do
  @moduledoc """
  Parses tool calls in Llama3/Meta format.

  ## Format

  Llama 3.x models (and some Mistral variants) emit tool calls wrapped in
  `<tool_call>` XML-like tags containing a JSON object:

      <tool_call>
      {"name": "read_file", "arguments": {"path": "notes.md"}}
      </tool_call>

  Multiple tool calls appear as multiple `<tool_call>` blocks in the same
  response.  Text outside the tags is ignored (it's the model "thinking").

  ## Examples

      iex> ForgeClaw.ToolCallParser.Llama3.parse(
      ...>   "<tool_call>\\n{\\"name\\": \\"list_files\\", \\"arguments\\": {}}\\n</tool_call>",
      ...>   "t1"
      ...> )
      [%ForgeClaw.Types.ToolCall{id: "t1_0", name: "list_files", arguments: %{}}]

      # No tool call — final answer
      iex> ForgeClaw.ToolCallParser.Llama3.parse("The files are: notes.md, plan.md", "t1")
      []

      # Malformed JSON inside tag — logged and skipped
      iex> ForgeClaw.ToolCallParser.Llama3.parse("<tool_call>not json</tool_call>", "t1")
      []
  """

  @behaviour ForgeClaw.ToolCallParser

  require Logger

  alias ForgeClaw.Types.ToolCall

  @tool_call_regex ~r/<tool_call>\s*(.*?)\s*<\/tool_call>/s

  @impl ForgeClaw.ToolCallParser
  @spec parse(String.t(), String.t()) :: [ToolCall.t()]
  def parse(response_text, call_id_prefix) do
    # Template (HTDP step 4):
    # 1. Find all matches of @tool_call_regex in response_text
    # 2. For each match (the captured JSON string):
    #    a. Jason.decode(json)
    #    b. If {:ok, %{"name" => name, "arguments" => args}}:
    #       build %ToolCall{id: "#{call_id_prefix}_#{index}", name: name, arguments: args}
    #    c. If {:error, _} or unexpected shape: Logger.warning and skip
    # 3. Return list of successfully parsed ToolCalls
    raise "not implemented"
  end
end

defmodule ForgeClaw.ToolCallParser.ChatML do
  @moduledoc """
  Parses tool calls in ChatML format.

  ## Format

  ChatML models (Mistral 7B, Qwen, Phi-3) use a `<|tool_calls|>` token
  followed by a JSON array of tool call objects:

      <|tool_calls|>
      [{"name": "read_file", "arguments": {"path": "notes.md"}}]
      <|end_tool_calls|>

  Some variants use a JSON array directly without the closing token — the
  parser handles both.

  ## Examples

      iex> ForgeClaw.ToolCallParser.ChatML.parse(
      ...>   "<|tool_calls|>\\n[{\\"name\\": \\"read_file\\", \\"arguments\\": {\\"path\\": \\"f.md\\"}}]",
      ...>   "t1"
      ...> )
      [%ForgeClaw.Types.ToolCall{id: "t1_0", name: "read_file", arguments: %{"path" => "f.md"}}]
  """

  @behaviour ForgeClaw.ToolCallParser

  require Logger

  alias ForgeClaw.Types.ToolCall

  @tool_calls_regex ~r/<\|tool_calls\|>\s*(.*?)(?:<\|end_tool_calls\|>|$)/s

  @impl ForgeClaw.ToolCallParser
  @spec parse(String.t(), String.t()) :: [ToolCall.t()]
  def parse(response_text, call_id_prefix) do
    # Template (HTDP step 4):
    # 1. Find @tool_calls_regex match in response_text
    # 2. If no match: return []
    # 3. Jason.decode the captured JSON array
    # 4. Map each item to %ToolCall{id: ..., name: ..., arguments: ...}
    # 5. Log and skip malformed items
    raise "not implemented"
  end
end
