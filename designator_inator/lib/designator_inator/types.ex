defmodule DesignatorInator.Types do
  @moduledoc """
  Canonical data definitions for DesignatorInator.

  ## Design note (HTDP step 1)

  Every value that flows between modules is defined here as a named struct with
  explicit `@type` annotations.  Keeping all data definitions in one place means:

  1. A reader can understand the whole system's data model in one file.
  2. Modules only need to `alias DesignatorInator.Types.Foo` rather than finding the
     definition scattered across GenServers.
  3. Changes to a data shape are visible in one diff.

  ### Naming conventions

  - Structs use `%StructName{}` syntax with all fields always present (no
    dynamically-added keys).
  - `nil` is an explicit allowed value where a field is optional.
  - Sum types (fields with a finite set of values) are expressed as union types
    using atoms.
  """
end

# ─────────────────────────────────────────────────────────────────────────────
# Inference layer
# ─────────────────────────────────────────────────────────────────────────────

defmodule DesignatorInator.Types.Model do
  @moduledoc """
  ## Data Definition

  A `Model` represents a GGUF model file discovered on disk.

  | Field            | Type              | Meaning                                        |
  |------------------|-------------------|------------------------------------------------|
  | `name`           | `String.t()`      | Human-friendly name, e.g. `"mistral-7b-instruct-v0.3.Q4_K_M"` |
  | `path`           | `Path.t()`        | Absolute path to the `.gguf` file              |
  | `size_params_b`  | `float()`         | Parameter count in billions (7.0, 13.0, etc.)  |
  | `quantization`   | `quantization()`  | Quantization scheme parsed from the filename   |
  | `context_length` | `pos_integer()`   | Maximum context window; 0 = unknown            |
  | `size_bytes`     | `pos_integer()`   | File size on disk                              |

  ## Examples

      iex> %DesignatorInator.Types.Model{
      ...>   name: "mistral-7b-instruct-v0.3.Q4_K_M",
      ...>   path: "/home/user/.designator_inator/models/mistral-7b-instruct-v0.3.Q4_K_M.gguf",
      ...>   size_params_b: 7.0,
      ...>   quantization: :q4_k_m,
      ...>   context_length: 32768,
      ...>   size_bytes: 4_368_438_272
      ...> }
  """

  @type quantization ::
          :q2_k
          | :q3_k_s
          | :q3_k_m
          | :q3_k_l
          | :q4_0
          | :q4_k_s
          | :q4_k_m
          | :q5_k_s
          | :q5_k_m
          | :q6_k
          | :q8_0
          | :f16
          | :f32
          | :bf16
          | {:unknown, String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          path: Path.t(),
          size_params_b: float(),
          quantization: quantization(),
          context_length: non_neg_integer(),
          size_bytes: pos_integer()
        }

  defstruct [
    :name,
    :path,
    :size_params_b,
    :quantization,
    context_length: 0,
    size_bytes: 0
  ]
end

defmodule DesignatorInator.Types.LoadedModel do
  @moduledoc """
  ## Data Definition

  A `LoadedModel` tracks a model that has been loaded into a running
  `llama-server` process.  `ModelManager` holds one of these per active model.

  | Field          | Type                 | Meaning                                    |
  |----------------|----------------------|--------------------------------------------|
  | `model`        | `Model.t()`          | The model metadata                         |
  | `server_pid`   | `pid()`              | PID of the `LlamaCpp` GenServer managing the Port |
  | `port_number`  | `pos_integer()`      | HTTP port llama-server is bound to         |
  | `vram_mb`      | `non_neg_integer()`  | Estimated VRAM usage in MB                 |
  | `last_used_at` | `DateTime.t()`       | Used for LRU eviction decisions            |
  | `request_count`| `non_neg_integer()`  | Total completed requests (for metrics)     |

  ## Examples

      iex> %DesignatorInator.Types.LoadedModel{
      ...>   model: %DesignatorInator.Types.Model{name: "mistral-7b-instruct-v0.3.Q4_K_M", ...},
      ...>   server_pid: #PID<0.123.0>,
      ...>   port_number: 8080,
      ...>   vram_mb: 4096,
      ...>   last_used_at: ~U[2025-01-01 12:00:00Z],
      ...>   request_count: 42
      ...> }
  """

  alias DesignatorInator.Types.Model

  @type t :: %__MODULE__{
          model: Model.t(),
          server_pid: pid(),
          port_number: pos_integer(),
          vram_mb: non_neg_integer(),
          last_used_at: DateTime.t(),
          request_count: non_neg_integer()
        }

  defstruct [
    :model,
    :server_pid,
    :port_number,
    :vram_mb,
    :last_used_at,
    request_count: 0
  ]
end

# ─────────────────────────────────────────────────────────────────────────────
# Conversation / messaging layer
# ─────────────────────────────────────────────────────────────────────────────

defmodule DesignatorInator.Types.ToolCall do
  @moduledoc """
  ## Data Definition

  A `ToolCall` is a request from the LLM to invoke a tool.  It is parsed out
  of the model's raw text response by `DesignatorInator.ReActLoop`.

  | Field       | Type         | Meaning                                         |
  |-------------|--------------|------------------------------------------------- |
  | `id`        | `String.t()` | Opaque call identifier (generated or parsed)    |
  | `name`      | `String.t()` | Tool name as declared in the pod manifest       |
  | `arguments` | `map()`      | Key-value arguments decoded from JSON           |

  ## Examples

      iex> %DesignatorInator.Types.ToolCall{
      ...>   id: "call_abc123",
      ...>   name: "read_file",
      ...>   arguments: %{"path" => "notes.md"}
      ...> }
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          arguments: map()
        }

  defstruct [:id, :name, arguments: %{}]
end

defmodule DesignatorInator.Types.ToolResult do
  @moduledoc """
  ## Data Definition

  A `ToolResult` is the response from executing a `ToolCall`.  It is fed back
  into the conversation as a tool-role message.

  | Field          | Type         | Meaning                                      |
  |----------------|--------------|----------------------------------------------|
  | `tool_call_id` | `String.t()` | Matches `ToolCall.id` this result answers    |
  | `content`      | `String.t()` | The tool's output text                       |
  | `is_error`     | `boolean()`  | `true` if the tool failed                    |

  ## Examples

      # Successful tool result
      iex> %DesignatorInator.Types.ToolResult{
      ...>   tool_call_id: "call_abc123",
      ...>   content: "# Notes\\nHello world",
      ...>   is_error: false
      ...> }

      # Failed tool result — the model will see the error and can react
      iex> %DesignatorInator.Types.ToolResult{
      ...>   tool_call_id: "call_abc123",
      ...>   content: "File not found: notes.md",
      ...>   is_error: true
      ...> }
  """

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          content: String.t(),
          is_error: boolean()
        }

  defstruct [:tool_call_id, :content, is_error: false]
end

defmodule DesignatorInator.Types.Message do
  @moduledoc """
  ## Data Definition

  A `Message` is a single turn in a conversation.  The sequence of messages
  forms the context window fed to the inference backend.

  | Field          | Type                          | Meaning                                      |
  |----------------|-------------------------------|----------------------------------------------|
  | `role`         | `role()`                      | Who authored this message                    |
  | `content`      | `String.t() \\| nil`           | Text content; `nil` when role is `:assistant` with tool calls |
  | `tool_calls`   | `[ToolCall.t()] \\| nil`       | Tool calls the assistant wants to make       |
  | `tool_call_id` | `String.t() \\| nil`           | For `:tool` role: which call this answers    |

  ### Role semantics

  - `:system`    — loaded from `soul.md`; always the first message
  - `:user`      — input from the human or orchestrator
  - `:assistant` — model response (may include tool calls)
  - `:tool`      — result of executing a tool call

  ## Examples

      iex> %DesignatorInator.Types.Message{role: :system, content: "You are a helpful assistant."}
      iex> %DesignatorInator.Types.Message{role: :user, content: "What files are in my workspace?"}
      iex> %DesignatorInator.Types.Message{
      ...>   role: :assistant,
      ...>   content: nil,
      ...>   tool_calls: [%DesignatorInator.Types.ToolCall{id: "c1", name: "list_files", arguments: %{}}]
      ...> }
      iex> %DesignatorInator.Types.Message{
      ...>   role: :tool,
      ...>   content: "notes.md\\nplan.md",
      ...>   tool_call_id: "c1"
      ...> }
  """

  alias DesignatorInator.Types.ToolCall

  @type role :: :system | :user | :assistant | :tool

  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | nil,
          tool_calls: [ToolCall.t()] | nil,
          tool_call_id: String.t() | nil
        }

  defstruct [:role, :content, tool_calls: nil, tool_call_id: nil]
end

# ─────────────────────────────────────────────────────────────────────────────
# Pod layer
# ─────────────────────────────────────────────────────────────────────────────

defmodule DesignatorInator.Types.ResourceRequirements do
  @moduledoc """
  ## Data Definition

  Hardware requirements declared in a pod's `manifest.yaml`.
  Used by `PodSupervisor` to check feasibility before starting a pod.

  | Field         | Type                        | Meaning                              |
  |---------------|-----------------------------|--------------------------------------|
  | `min_ram_mb`  | `non_neg_integer()`         | Minimum system RAM required          |
  | `min_context` | `non_neg_integer()`         | Minimum context window size needed   |
  | `gpu`         | `:required \\| :optional \\| :none` | GPU requirement                |

  ## Examples

      iex> %DesignatorInator.Types.ResourceRequirements{
      ...>   min_ram_mb: 8192,
      ...>   min_context: 8192,
      ...>   gpu: :optional
      ...> }
  """

  @type gpu_requirement :: :required | :optional | :none

  @type t :: %__MODULE__{
          min_ram_mb: non_neg_integer(),
          min_context: non_neg_integer(),
          gpu: gpu_requirement()
        }

  defstruct min_ram_mb: 0, min_context: 2048, gpu: :optional
end

defmodule DesignatorInator.Types.ModelPreference do
  @moduledoc """
  ## Data Definition

  A pod's model preferences from `config.yaml`.  Determines which inference
  backend to use and when to fall back to cloud providers.

  | Field           | Type                               | Meaning                                 |
  |-----------------|------------------------------------|-----------------------------------------|
  | `primary`       | `String.t()`                       | GGUF model name or absolute path        |
  | `fallback`      | `String.t() \\| nil`                | Cloud model name (e.g. `"claude-sonnet"`) |
  | `fallback_mode` | `:auto \\| :manual \\| :disabled`   | When to use the fallback                |
  | `recommended`   | `String.t() \\| nil`               | Best model for this task (optional hint)|
  | `minimum`       | `String.t() \\| nil`               | Smallest acceptable model               |

  ### fallback_mode semantics

  - `:auto`     — fall back when local VRAM is full, model load fails, or
                  3 consecutive inference errors occur
  - `:manual`   — fall back only when the pod code explicitly requests it
  - `:disabled` — always use local; error rather than going to cloud

  ## Examples

      iex> %DesignatorInator.Types.ModelPreference{
      ...>   primary: "mistral-7b-instruct-v0.3.Q4_K_M",
      ...>   fallback: "claude-sonnet",
      ...>   fallback_mode: :auto
      ...> }
  """

  @type fallback_mode :: :auto | :manual | :disabled

  @type t :: %__MODULE__{
          primary: String.t(),
          fallback: String.t() | nil,
          fallback_mode: fallback_mode(),
          recommended: String.t() | nil,
          minimum: String.t() | nil
        }

  defstruct [
    :primary,
    fallback: nil,
    fallback_mode: :disabled,
    recommended: nil,
    minimum: nil
  ]
end

defmodule DesignatorInator.Types.ToolDefinition do
  @moduledoc """
  ## Data Definition

  A `ToolDefinition` describes one tool that a pod exposes to the outside world
  (declared in `manifest.yaml` under `exposed_tools`).  It becomes an MCP tool
  definition and is registered in `DesignatorInator.ToolRegistry`.

  | Field         | Type                           | Meaning                              |
  |---------------|--------------------------------|--------------------------------------|
  | `name`        | `String.t()`                   | Snake-case tool name                 |
  | `description` | `String.t()`                   | Human-readable description           |
  | `parameters`  | `%{String.t() => param_schema()}`  | JSON Schema for each parameter   |

  ### param_schema keys

  - `type`        — `:string | :integer | :number | :boolean | :array | :object`
  - `required`    — `boolean()`
  - `description` — `String.t() | nil`
  - `enum`        — `[String.t()] | nil` (allowed values)
  - `default`     — `term() | nil`

  ## Examples

      iex> %DesignatorInator.Types.ToolDefinition{
      ...>   name: "review_code",
      ...>   description: "Reviews code for bugs, style, and security issues.",
      ...>   parameters: %{
      ...>     "code"     => %{type: :string,  required: true,  description: "Source code to review"},
      ...>     "language" => %{type: :string,  required: false, description: "Programming language"},
      ...>     "focus"    => %{type: :string,  required: false, enum: ["bugs","style","security","all"],
      ...>                     default: "all"}
      ...>   }
      ...> }
  """

  @type param_type :: :string | :integer | :number | :boolean | :array | :object

  @type param_schema :: %{
          required(:type) => param_type(),
          required(:required) => boolean(),
          optional(:description) => String.t(),
          optional(:enum) => [String.t()],
          optional(:default) => term()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: %{String.t() => param_schema()}
        }

  defstruct [:name, :description, parameters: %{}]
end

defmodule DesignatorInator.Types.PodManifest do
  @moduledoc """
  ## Data Definition

  The parsed contents of a pod's `manifest.yaml`.  This is the "package.json"
  of a pod — it declares identity, hardware requirements, and what tools the
  pod exposes.

  | Field            | Type                         | Meaning                                    |
  |------------------|------------------------------|--------------------------------------------|
  | `name`           | `String.t()`                 | Unique pod identifier (snake_case)         |
  | `version`        | `String.t()`                 | SemVer string                              |
  | `description`    | `String.t()`                 | One-line summary                           |
  | `requires`       | `ResourceRequirements.t()`   | Minimum hardware                           |
  | `model`          | `ModelPreference.t()`        | Inference preferences                      |
  | `exposed_tools`  | `[ToolDefinition.t()]`       | Tools this pod publishes                   |
  | `internal_tools` | `[String.t()]`               | Built-in tool names this pod uses          |
  | `isolation`      | `:beam \\| :container`        | Process isolation mode                     |

  ## Examples

      iex> %DesignatorInator.Types.PodManifest{
      ...>   name: "code-reviewer",
      ...>   version: "1.0.0",
      ...>   description: "Reviews code for bugs, style issues, and security concerns",
      ...>   requires: %DesignatorInator.Types.ResourceRequirements{min_ram_mb: 4096, min_context: 8192},
      ...>   model: %DesignatorInator.Types.ModelPreference{primary: "codellama-13b-instruct.Q4_K_M"},
      ...>   exposed_tools: [%DesignatorInator.Types.ToolDefinition{name: "review_code", ...}],
      ...>   internal_tools: ["filesystem", "shell"],
      ...>   isolation: :beam
      ...> }
  """

  alias DesignatorInator.Types.{ResourceRequirements, ModelPreference, ToolDefinition}

  @type isolation :: :beam | :container

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          requires: ResourceRequirements.t(),
          model: ModelPreference.t(),
          exposed_tools: [ToolDefinition.t()],
          internal_tools: [String.t()],
          isolation: isolation()
        }

  defstruct [
    :name,
    :version,
    :description,
    requires: %ResourceRequirements{},
    model: %ModelPreference{},
    exposed_tools: [],
    internal_tools: [],
    isolation: :beam
  ]
end

defmodule DesignatorInator.Types.PodState do
  @moduledoc """
  ## Data Definition

  Runtime state of a running pod process.  Held in the `Pod` GenServer's state
  and surfaced via `Pod.get_status/1`.

  | Field              | Type                | Meaning                                            |
  |--------------------|---------------------|----------------------------------------------------|
  | `name`             | `String.t()`        | Pod name (from manifest)                           |
  | `path`             | `Path.t()`          | Absolute path to the pod directory                 |
  | `manifest`         | `PodManifest.t()`   | Parsed manifest                                    |
  | `soul`             | `String.t()`        | Contents of `soul.md` (system prompt)              |
  | `status`           | `pod_status()`      | Current lifecycle status                           |
  | `model`            | `String.t()`        | Resolved model name in use                         |
  | `workspace`        | `Path.t()`          | Absolute path to this pod's workspace dir          |
  | `config`           | `Config.t()`        | Pod runtime configuration                         |
  | `started_at`       | `DateTime.t()`      | When the pod was started                           |
  | `current_task_id`  | `String.t() \| nil` | ID of the task currently being worked on          |
  | `consecutive_errors`| `non_neg_integer()` | Consecutive inference failures (triggers fallback)|

  ### pod_status values

  - `:loading`  — starting up, loading model
  - `:idle`     — ready to accept requests
  - `:running`  — currently processing a request
  - `:error`    — in error state, waiting for supervisor restart
  - `:stopping` — graceful shutdown in progress

  ## Examples

      iex> %DesignatorInator.Types.PodState{
      ...>   name: "assistant",
      ...>   status: :idle,
      ...>   model: "mistral-7b-instruct-v0.3.Q4_K_M",
      ...>   started_at: ~U[2025-01-01 12:00:00Z]
      ...> }
  """

  alias DesignatorInator.Types.PodManifest

  @type pod_status :: :loading | :idle | :running | :error | :stopping

  @type t :: %__MODULE__{
          name: String.t(),
          path: Path.t(),
          manifest: PodManifest.t(),
          soul: String.t(),
          status: pod_status(),
          model: String.t(),
          workspace: Path.t(),
          config: DesignatorInator.Pod.Config.t() | nil,
          started_at: DateTime.t(),
          current_task_id: String.t() | nil,
          consecutive_errors: non_neg_integer()
        }

  defstruct [
    :name,
    :path,
    :manifest,
    :soul,
    :model,
    :workspace,
    :config,
    :started_at,
    status: :loading,
    current_task_id: nil,
    consecutive_errors: 0
  ]
end

# ─────────────────────────────────────────────────────────────────────────────
# ReAct loop
# ─────────────────────────────────────────────────────────────────────────────

defmodule DesignatorInator.Types.ReActState do
  @moduledoc """
  ## Data Definition

  The state machine state for a single ReAct loop execution.

  | Field            | Type               | Meaning                                         |
  |------------------|--------------------|--------------------------------------------------|
  | `pod_name`       | `String.t()`       | Which pod is running this loop                  |
  | `session_id`     | `String.t()`       | Conversation session UUID                       |
  | `messages`       | `[Message.t()]`    | Full conversation history including tool results|
  | `status`         | `loop_status()`    | Current state of the loop                       |
  | `iterations`     | `non_neg_integer()`| Number of model calls made so far               |
  | `max_iterations` | `pos_integer()`    | Safety cap — stop if exceeded                   |
  | `result`         | `String.t() \\| nil`| Final answer (set when status is `:done`)       |
  | `error`          | `String.t() \\| nil`| Error message (set when status is `:error`)     |

  ### loop_status values

  - `:thinking`      — waiting for model response
  - `:tool_calling`  — executing one or more tool calls from the last response
  - `:done`          — model produced a final answer; `result` is set
  - `:error`         — unrecoverable error; `error` is set
  - `:max_iterations`— safety limit hit; treat as `:error` at the caller

  ## Examples

      iex> %DesignatorInator.Types.ReActState{
      ...>   pod_name: "assistant",
      ...>   session_id: "550e8400-e29b-41d4-a716-446655440000",
      ...>   messages: [%DesignatorInator.Types.Message{role: :system, content: "..."}],
      ...>   status: :thinking,
      ...>   iterations: 0,
      ...>   max_iterations: 20
      ...> }
  """

  alias DesignatorInator.Types.Message

  @type loop_status :: :thinking | :tool_calling | :done | :error | :max_iterations

  @type t :: %__MODULE__{
          pod_name: String.t(),
          session_id: String.t(),
          messages: [Message.t()],
          status: loop_status(),
          iterations: non_neg_integer(),
          max_iterations: pos_integer(),
          result: String.t() | nil,
          error: String.t() | nil
        }

  defstruct [
    :pod_name,
    :session_id,
    messages: [],
    status: :thinking,
    iterations: 0,
    max_iterations: 20,
    result: nil,
    error: nil
  ]
end

# ─────────────────────────────────────────────────────────────────────────────
# MCP layer
# ─────────────────────────────────────────────────────────────────────────────

defmodule DesignatorInator.Types.MCPError do
  @moduledoc """
  ## Data Definition

  A JSON-RPC error object as defined by the MCP spec.

  Standard error codes:
  - `-32700` — Parse error
  - `-32600` — Invalid request
  - `-32601` — Method not found
  - `-32602` — Invalid params
  - `-32603` — Internal error

  ## Examples

      iex> %DesignatorInator.Types.MCPError{
      ...>   code: -32601,
      ...>   message: "Method not found",
      ...>   data: %{"method" => "unknown/method"}
      ...> }
  """

  @type error_code :: -32700 | -32600 | -32601 | -32602 | -32603 | integer()

  @type t :: %__MODULE__{
          code: error_code(),
          message: String.t(),
          data: term()
        }

  defstruct [:code, :message, data: nil]
end

defmodule DesignatorInator.Types.MCPMessage do
  @moduledoc """
  ## Data Definition

  A single JSON-RPC 2.0 message, used for all MCP communication.

  A message is one of:
  - **Request** — has `id`, `method`, `params`; no `result` or `error`
  - **Response** — has `id`, `result`; no `method` or `error`
  - **Error response** — has `id`, `error`; no `method` or `result`
  - **Notification** — has `method`, `params`; no `id` (fire-and-forget)

  | Field      | Type                   | Meaning                              |
  |------------|------------------------|--------------------------------------|
  | `jsonrpc`  | `"2.0"`                | Always `"2.0"`                       |
  | `id`       | `String.t() \\| integer() \\| nil` | Request ID; nil for notifications |
  | `method`   | `String.t() \\| nil`    | RPC method name                      |
  | `params`   | `map() \\| nil`          | Method parameters                    |
  | `result`   | `term() \\| nil`         | Successful response payload          |
  | `error`    | `MCPError.t() \\| nil`  | Error payload                        |

  ## Examples

      # Request
      iex> %DesignatorInator.Types.MCPMessage{
      ...>   jsonrpc: "2.0", id: 1, method: "tools/call",
      ...>   params: %{"name" => "review_code", "arguments" => %{"code" => "..."}},
      ...>   result: nil, error: nil
      ...> }

      # Response
      iex> %DesignatorInator.Types.MCPMessage{
      ...>   jsonrpc: "2.0", id: 1, method: nil, params: nil,
      ...>   result: %{"content" => [%{"type" => "text", "text" => "LGTM"}]},
      ...>   error: nil
      ...> }
  """

  alias DesignatorInator.Types.MCPError

  @type id :: String.t() | integer() | nil

  @type t :: %__MODULE__{
          jsonrpc: String.t(),
          id: id(),
          method: String.t() | nil,
          params: map() | nil,
          result: term(),
          error: MCPError.t() | nil
        }

  defstruct jsonrpc: "2.0", id: nil, method: nil, params: nil, result: nil, error: nil
end

# ─────────────────────────────────────────────────────────────────────────────
# Swarm layer
# ─────────────────────────────────────────────────────────────────────────────

defmodule DesignatorInator.Types.NodeInfo do
  @moduledoc """
  ## Data Definition

  Resource snapshot for a connected DesignatorInator node.  Each node's `ModelManager`
  broadcasts this periodically so the orchestrator can make informed routing
  decisions.

  | Field            | Type                | Meaning                                     |
  |------------------|---------------------|---------------------------------------------|
  | `node`           | `node()`            | Erlang node name, e.g. `:"designator_inator@pi4"`   |
  | `hostname`       | `String.t()`        | Human-readable hostname                     |
  | `vram_total_mb`  | `non_neg_integer()` | Total VRAM budget (from config)             |
  | `vram_used_mb`   | `non_neg_integer()` | Currently used VRAM                         |
  | `ram_free_mb`    | `non_neg_integer()` | Free system RAM                             |
  | `loaded_models`  | `[String.t()]`      | Names of currently loaded models            |
  | `updated_at`     | `DateTime.t()`      | When this info was last refreshed           |

  ## Examples

      iex> %DesignatorInator.Types.NodeInfo{
      ...>   node: :"designator_inator@pi4.local",
      ...>   hostname: "pi4.local",
      ...>   vram_total_mb: 8192,
      ...>   vram_used_mb: 4096,
      ...>   ram_free_mb: 2048,
      ...>   loaded_models: ["mistral-7b-instruct-v0.3.Q4_K_M"],
      ...>   updated_at: ~U[2025-01-01 12:00:00Z]
      ...> }
  """

  @type t :: %__MODULE__{
          node: node(),
          hostname: String.t(),
          vram_total_mb: non_neg_integer(),
          vram_used_mb: non_neg_integer(),
          ram_free_mb: non_neg_integer(),
          loaded_models: [String.t()],
          updated_at: DateTime.t()
        }

  defstruct [
    :node,
    :hostname,
    :updated_at,
    vram_total_mb: 0,
    vram_used_mb: 0,
    ram_free_mb: 0,
    loaded_models: []
  ]
end
