defmodule ForgeClaw.Tool do
  @moduledoc """
  Behaviour for all tools that a pod can use internally.

  ## Design (HTDP step 1)

  A tool is a module that:
  1. Declares its name, description, and parameter schema (used to build the
     tool list sent to the LLM and to validate incoming calls).
  2. Implements `call/1` which executes the tool and returns either a string
     result or a string error.

  Tools are always called by the `ReActLoop` when the LLM produces a tool-call
  response.  The loop formats the result into a `:tool` role message and feeds
  it back to the model.

  ## Built-in tools

  - `ForgeClaw.Tools.Workspace` — read/write/list files in the pod's workspace

  ## Adding a custom tool

  1. Create a module that `use ForgeClaw.Tool`
  2. Implement the four callbacks
  3. List the tool module in the pod's `manifest.yaml` under `internal_tools`

  ## Security

  Tools are responsible for their own input validation.  The `ReActLoop` passes
  whatever arguments the LLM generated — tools must never trust them blindly.
  See `ForgeClaw.Tools.Workspace` for the path traversal prevention pattern.
  """

  alias ForgeClaw.Types.ToolDefinition

  @doc """
  The tool's snake_case name as it appears in tool calls from the LLM.

  Must be unique within a pod.  Should match the name in `manifest.yaml`.

  ## Examples

      iex> ForgeClaw.Tools.Workspace.name()
      "workspace"
  """
  @callback name() :: String.t()

  @doc """
  A concise description of what the tool does.  This text is sent to the LLM
  in the tool list, so it directly influences when and how the model calls it.

  ## Examples

      iex> ForgeClaw.Tools.Workspace.description()
      "Read, write, and list files in the agent's workspace directory."
  """
  @callback description() :: String.t()

  @doc """
  JSON Schema for the tool's parameters, used for LLM prompting and validation.

  Returns a map of parameter name → schema.  See `ToolDefinition.param_schema`.

  ## Examples

      iex> ForgeClaw.Tools.Workspace.parameters_schema()
      %{
        "action"  => %{type: :string, required: true, enum: ["read", "write", "list"]},
        "path"    => %{type: :string, required: true},
        "content" => %{type: :string, required: false}
      }
  """
  @callback parameters_schema() :: %{String.t() => ToolDefinition.param_schema()}

  @doc """
  Executes the tool with `params` and returns a text result for the LLM.

  - On success: `{:ok, result_text}` — fed back as a `:tool` message
  - On failure: `{:error, error_text}` — fed back as an error `:tool` message;
    the LLM sees the error and can react (retry with different params, give up, etc.)

  Implementors MUST validate all params before use.  Do not assume the LLM
  passed correct types or safe values.

  ## Examples

      iex> ForgeClaw.Tools.Workspace.call(%{"action" => "read", "path" => "notes.md"})
      {:ok, "# Notes\\nHello world"}

      iex> ForgeClaw.Tools.Workspace.call(%{"action" => "read", "path" => "../secret"})
      {:error, "Access denied: path traversal detected"}
  """
  @callback call(params :: map()) :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Returns a `ToolDefinition` struct suitable for the `ToolRegistry` and MCP
  tool list.  Default implementation builds it from the other callbacks.
  """
  @spec to_definition(module()) :: ToolDefinition.t()
  def to_definition(module) do
    %ToolDefinition{
      name: module.name(),
      description: module.description(),
      parameters: module.parameters_schema()
    }
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour ForgeClaw.Tool
    end
  end
end
