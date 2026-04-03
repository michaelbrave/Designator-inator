# DesignatorInator — Build Plan

**Project:** Local-first AI agent orchestration on Elixir/BEAM
**Core insight:** Every agent is an MCP server. MCP is the protocol at every layer.

> **For agents:** Read `agents.md` before touching any code. It has the rules,
> the HTDP method, and instructions for updating this file when you finish work.

---

## Overall Status

| Phase | Status |
|-------|--------|
| HTDP scaffolding (steps 1–4) — all modules | **DONE** |
| Implementation (step 5) — all stubs | **IN PROGRESS** |
| Tests passing (step 6) | **PARTIAL** |

**What exists now:** Every module has been created with full data definitions
(`@type`, `defstruct`), signatures (`@spec`), purpose statements and examples
(`@doc`), and algorithm templates (`# Template:` comments). There are 93 stubs
to fill in. The test files exist with assertions but will fail until the stubs
are implemented.

**Naming note:** The project was originally named ForgeClaw. It has been renamed
to Designator-inator. Historical references may remain in older notes, but new
code, config, docs, and commands should use `DesignatorInator`,
`designator_inator`, and `designator-inator` as appropriate.

**What to do next:** See "Next Steps" at the bottom of this file.

---

## Milestones at a Glance

| # | Milestone | Deliverable |
|---|-----------|-------------|
| 1 | Foundation | llama.cpp managed, inference works |
| 2 | Single Agent | One agent with ReAct loop + tools + memory |
| 3 | Pod Packaging | Agents as portable directories, CLI to run them |
| 4 | MCP Interface | Claude Desktop / Cursor can talk to a pod |
| 5 | Cloud Fallback | Anthropic/OpenAI as inference backends |
| 6 | Orchestration | Orchestrator pod delegates to other pods |
| 7 | Distributed Swarm | Multi-machine, Erlang distribution |

Each milestone produces something testable before the next begins.

---

## Tech Stack

| Layer | Choice | Reason |
|-------|--------|--------|
| Language | Elixir + BEAM | Fault isolation, native distributed clustering, lightweight processes |
| Local inference | llama.cpp (`llama-server`) via OS Port | Safe crash boundary; full control over context/VRAM/quantization |
| Model format | GGUF | Supported by llama.cpp; same as LM Studio |
| Protocol | MCP (JSON-RPC over stdio/SSE) | Universal — IDE integrations, pod-to-pod, external clients, all the same |
| Persistence | SQLite via Ecto | Minimal dependency, embedded, works offline |
| Container isolation | Podman (opt-in) | Zero dep on first run; opt-in for shell/code execution pods |
| Build tooling | Mix + mix release | Single binary release, no runtime dependencies |

---

## Milestone 1 — Foundation

**Goal:** llama.cpp running and answering inference requests through Elixir.

**Scaffolding status: DONE** — All modules created with full HTDP steps 1–4.
**Implementation status: IN PROGRESS** — `ModelInventory`, `Providers.LlamaCpp`, and `ModelManager` are implemented; cloud providers and later milestones remain stubbed.
**Status: DONE** — `ModelInventory` scanning, GGUF filename parsing, quantization parsing, GenServer callbacks, `Providers.LlamaCpp` port wrapper/completion path, and `ModelManager` VRAM/LRU/provider-routing logic are implemented and verified with targeted tests.

### Checklist

- [x] Project created (`designator_inator/` directory, `mix.exs`, `config/`)
- [x] Supervisor tree skeleton (`application.ex` — `DesignatorInator.PodRegistry`, `Memory.Repo`, `ModelInventory`, `ModelManager`, `ToolRegistry`, `SwarmRegistry`, `PodSupervisor`, `MCPGateway`)
- [x] All data types defined (`types.ex` — `Model`, `LoadedModel`, `Message`, `ToolCall`, `ToolResult`, etc.)
- [x] `ModelInventory` scaffolded (`model_inventory.ex` — 7 stubs)
- [x] `InferenceProvider` behaviour defined (`inference_provider.ex` — behaviour + default `stream/3`)
- [x] `Providers.LlamaCpp` scaffolded (`providers/llama_cpp.ex` — 8 stubs)
- [x] `Providers.Anthropic` scaffolded (`providers/anthropic.ex` — 3 stubs)
- [x] `Providers.OpenAI` scaffolded (`providers/open_ai.ex` — 1 stub)
- [x] `ModelManager` scaffolded (`model_manager.ex` — 8 stubs, `provider_for/1` implemented)
- [x] `ModelInventory.scan_directory/1` implemented
- [x] `ModelInventory.parse_gguf_filename/1` implemented
- [x] `ModelInventory.parse_quantization/1` implemented
- [x] `ModelInventory` GenServer callbacks implemented
- [x] `Providers.LlamaCpp` Port wrapper implemented (spawn, health check, shutdown)
- [x] `Providers.LlamaCpp.complete/2` implemented
- [x] `ModelManager` VRAM budget + LRU eviction implemented
- [x] `ModelManager.complete/2` with provider routing implemented
- [x] **Milestone 1 test passing:** `ModelManager.complete/2` returns a real response from a local GGUF

### Project bootstrap
- GenServer that spawns `llama-server` as an OS process via `Port`
- Passes a GGUF path and port number at startup
- Health-checks via HTTP GET to `/health`
- Handles clean shutdown (sends SIGTERM, waits, SIGKILL if needed)
- If the process dies unexpectedly: GenServer detects via `{:EXIT, port, reason}`, logs it, raises for the supervisor to restart
- **Do NOT use NIFs** — a NIF segfault kills the entire BEAM

### Model inventory
- Scan a configurable directory (e.g. `~/.designator_inator/models/`) for `.gguf` files
- Parse filename convention for model name, parameter size, quantization (e.g. `mistral-7b-instruct-v0.3.Q4_K_M.gguf`)
- Expose as `ModelManager.list_models/0` → list of `%Model{}` structs

### Inference GenServer
- Wraps the llama-server HTTP API (`/v1/chat/completions` — OpenAI-compatible)
- Clean Elixir call: `ModelManager.complete(messages, opts)` → `{:ok, response}` or `{:error, reason}`
- Handles: request queuing (serialize calls to the same server), configurable timeouts, basic retry on transient errors
- Streaming: buffer tokens, return full response for now (add streaming later)

### VRAM/RAM budget tracking
- `ModelManager` maintains a map of `model_id → %LoadedModel{pid, vram_mb, last_used_at}`
- On `request_model(name)`: check if already loaded → return pid. If not: check budget. If budget full: evict LRU model (send shutdown to its Port GenServer), then load new one
- Budget is read from config (e.g. `config :designator_inator, :vram_budget_mb, 8192`)

**Milestone 1 test:** `ModelManager.complete([%{role: "user", content: "Hello"}], model: "mistral-7b")` returns a real response from a locally running GGUF.

---

## Milestone 2 — Single Agent

**Goal:** One agent that can reason, use tools, and remember conversations.

**Status: DONE** — Workspace file operations, conversation memory persistence, tool-call parsing, and the ReAct loop are implemented and their targeted tests pass.

**Scaffolding status: DONE**
**Implementation status: DONE**

### Checklist

- [x] `Tool` behaviour defined (`tool.ex`)
- [x] `Tools.Workspace` scaffolded (`tools/workspace.ex` — 6 stubs, security model documented)
- [x] `Memory` + `Memory.Repo` + `ConversationMessage` schema scaffolded (`memory.ex`)
- [x] SQLite migration created (`priv/repo/migrations/...create_conversation_messages.exs`)
- [x] `ToolCallParser` behaviour + `Llama3` parser + `ChatML` parser scaffolded (`tool_call_parser.ex`)
- [x] `ReActLoop` scaffolded (`react_loop.ex` — 3 stubs, `tool_result_to_message/1` implemented)
- [x] `Tools.Workspace.safe_path/2` implemented
- [x] `Tools.Workspace` file operations implemented (`read_file`, `write_file`, `list_files`, `delete_file`)
- [x] `Tools.Workspace.call/1` dispatch implemented
- [x] `Memory.save_message/3` implemented
- [x] `Memory.load_history/3` implemented
- [x] `Memory.list_sessions/1`, `clear_session/2` implemented
- [x] `ToolCallParser.Llama3.parse/2` implemented
- [x] `ToolCallParser.ChatML.parse/2` implemented
- [x] `ReActLoop.run/5` implemented
- [x] `ReActLoop.step/4` implemented
- [x] `ReActLoop.format_tools_prompt/2` implemented
- [x] **Milestone 2 test passing:** Agent calls workspace tool, remembers prior turns

### ReAct loop
- The core loop: prompt model → parse tool calls from response → execute tool → feed result back → repeat until final answer
- State machine: `:thinking | :tool_calling | :done | :error`
- A single GenServer manages the loop for one agent session
- **Tool call parsing:** start with ChatML / Llama3 format. Build the parser as a pluggable module from day one so formats can be added (see Open Questions)

### soul.md loading
- On pod startup, read `soul.md` from pod directory
- Prepend as system message in every `ModelManager.complete/2` call
- Hot-reload support: watch for file changes with `:fs` library, reload without restarting the pod

### Internal tool interface
- Define `DesignatorInator.Tool` behaviour: `name/0`, `description/0`, `parameters_schema/0`, `call(params)` → `{:ok, result}` or `{:error, reason}`
- First built-in tool: `DesignatorInator.Tools.Workspace` — read/write/list files scoped to the pod's workspace directory. Path traversal prevention: resolve and assert path starts with workspace root before any file operation.

### Conversation memory
- Add `ecto` + `ecto_sqlite3` deps
- Schema: `ConversationMessage(pod_id, session_id, role, content, tool_calls, timestamp)`
- Agent always loads recent history into context window (configurable `max_history_turns`)
- Sessions are identified by a UUID the client provides (or DesignatorInator generates)

**Milestone 2 test:** Start a single agent process. Ask it a question that requires reading a file in its workspace. Verify it calls the workspace tool and incorporates the result. Ask a follow-up that requires remembering the first exchange. Verify it does.

---

## Milestone 3 — Agent Pod Packaging

**Goal:** Agents are portable directory packages you can start, stop, and list via CLI.

**Status: IN PROGRESS** — pod manifest/config parsing, pod GenServer lifecycle, pod supervision, workspace tools, tool registry, and CLI `run/list/stop/models` wiring are implemented; MCP `serve` is still pending.
**Scaffolding status: DONE**
**Implementation status: IN PROGRESS**

### Checklist

- [x] `Pod.Manifest` scaffolded (`pod/manifest.ex` — 6 stubs)
- [x] `Pod.Config` scaffolded (`pod/config.ex` — 3 stubs, `Config` struct defined)
- [x] `Pod` GenServer scaffolded (`pod.ex` — 5 stubs, `via/1`, `lookup/1`, public API stubs)
- [x] `PodSupervisor` scaffolded (`pod_supervisor.ex` — 3 stubs)
- [x] `DesignatorInator.PodRegistry` added to `Application` supervisor tree
- [x] Example assistant pod created (`examples/assistant/` — `manifest.yaml`, `soul.md`, `config.yaml`, `workspace/`)
- [x] `Pod.Manifest.parse/1` implemented (all sub-parsers: `parse_requires`, `parse_model`, `parse_tools`)
- [x] `Pod.Manifest.load/1` implemented
- [x] `Pod.Manifest.check_hardware/1` implemented
- [x] `Pod.Config.load/1` implemented (with config hierarchy merge)
- [x] `Pod.Config.resolve_api_key/2` implemented
- [x] `Pod.init/1` implemented (soul.md load, file watcher, workspace setup, ToolRegistry registration)
- [x] `Pod.handle_call {:chat, ...}` implemented
- [x] `Pod.handle_call {:call_tool, ...}` implemented
- [x] `Pod.handle_info :load_model` implemented
- [x] `Pod.handle_info {:file_event, ...}` (soul.md hot-reload) implemented
- [x] `PodSupervisor.start_pod/1` implemented
- [x] `PodSupervisor.stop_pod/1` implemented
- [x] `PodSupervisor.list_pods/0` implemented
- [x] `CLI.cmd_run/2` implemented
- [x] `CLI.chat_loop/2` implemented
- [x] `CLI.cmd_list/0`, `cmd_stop/1`, `cmd_models/0` implemented
- [ ] **Milestone 3 test passing:** `designator-inator run ./examples/assistant/` works end-to-end

### Directory structure (canonical)
```
my-agent/
├── manifest.yaml      # identity, requirements, exposed tools
├── soul.md            # persona and instructions
├── config.yaml        # model preferences, inference params
├── tools/             # MCP servers + skill files + scripts the agent uses internally
│   └── <tool-name>/
└── workspace/         # agent's persistent working directory
```

### manifest.yaml parser
- Required fields: `name`, `version`, `description`, `exposed_tools` (at least one)
- Optional: `requires` (RAM/VRAM/GPU), `model`, `internal_tools`, `isolation`
- Validate with JSON Schema or manual struct validation — return descriptive errors on bad manifests
- Hardware requirements check: compare against current system before starting

### Pod lifecycle manager (`DesignatorInator.PodSupervisor`)
- `DynamicSupervisor` that spawns pod process trees
- `start_pod(path)` → loads manifest + soul.md + config → requests model from `ModelManager` → initializes internal tools → registers in `ToolRegistry`
- `stop_pod(name)` → graceful shutdown (finish in-flight requests, then terminate)
- `list_pods()` → map of name → status
- Pods checkpoint their state periodically to SQLite so restart preserves conversation history

### CLI interface
```
designator-inator run ./my-agent/          # start pod, enter interactive chat
designator-inator run ./my-agent/ --detach # start pod in background
designator-inator list                     # list running pods with status
designator-inator stop <name>              # graceful stop
designator-inator logs <name>              # tail pod logs
designator-inator models                   # list available GGUFs
```
- Build with `escript` or as part of `mix release`
- Interactive chat uses `IO.gets/1` loop with readline-like editing (`:edlin` or `ExReadline`)

### Auto-pull models
- When a pod's manifest requests a model not in the local model dir:
  1. Check HuggingFace API for the model (configurable registry URL)
  2. Show download progress via a `:telemetry` event → logged to console
  3. Verify SHA256 checksum after download
  4. Store in `~/.designator_inator/models/`
- Make this opt-in with `--no-pull` flag for air-gapped setups

### Workspace isolation
- Each pod's workspace is `~/.designator_inator/workspaces/<pod-name>/`
- Workspace tool resolves all paths relative to this root
- Asserts resolved path starts with workspace root (prevents `../../etc/passwd` style attacks)
- Two pods cannot access each other's workspaces through any built-in tool

**Milestone 3 test:** `designator-inator run ./examples/code-reviewer/` starts a working agent from the example pod directory. `designator-inator list` shows it running. `designator-inator stop code-reviewer` shuts it down cleanly.

---

## Milestone 4 — MCP Server Interface

**Goal:** Claude Desktop, Cursor, or any MCP client can talk to DesignatorInator pods.

**Status: DONE** — MCP JSON-RPC parsing/encoding, MCPGateway tool routing, CLI stdio serve wiring, SSE auth/POST dispatch, and a real `designator-inator serve` smoke test are implemented and tested.
**Scaffolding status: DONE**
**Implementation status: DONE**

### Checklist

- [x] `MCP.Protocol` scaffolded (`mcp/protocol.ex` — 3 stubs, constructors implemented)
- [x] `MCP.Transport.Stdio` scaffolded (`mcp/transport/stdio.ex` — 4 stubs)
- [x] `MCP.Transport.SSE` scaffolded (`mcp/transport/sse.ex` — Plug router + 3 stubs)
- [x] `MCPGateway` scaffolded (`mcp_gateway.ex` — 2 stubs, routing for `initialize`, `initialized`, unknown methods implemented)
- [x] `MCP.Protocol.parse_message/1` implemented
- [x] `MCP.Protocol.encode_message/1` implemented
- [x] `MCP.Protocol.tools_to_mcp/1` implemented
- [x] `MCP.Transport.Stdio.read_message/0` implemented
- [x] `MCP.Transport.Stdio.read_loop/1` implemented
- [x] `MCP.Transport.Stdio` GenServer callbacks implemented
- [x] `MCPGateway.handle_call {:handle_request, tools/list}` implemented
- [x] `MCPGateway.handle_call {:handle_request, tools/call}` implemented
- [x] `CLI.cmd_serve/2` implemented
- [x] **Claude Desktop integration test:** `designator-inator serve ./examples/assistant/` works with Claude Desktop
- [x] `MCP.Transport.SSE` implemented (SSE stream, POST endpoint, auth)
- [x] `MCPGateway` multi-pod namespace routing implemented

### MCP JSON-RPC over stdio
- Implement MCP spec endpoints:
  - `initialize` — handshake, return server capabilities
  - `tools/list` — return all exposed tools for this pod
  - `tools/call` — execute a tool, return result
  - `resources/list`, `resources/read` — expose workspace files as resources (optional, add later)
- Parse newline-delimited JSON on stdin, write to stdout
- Run as a separate process: `designator-inator serve ./my-agent/` (or auto-start when run in MCP mode)

### Pod-to-MCP bridge
- Each pod's `exposed_tools` from manifest.yaml become MCP tool definitions
- When `tools/call` arrives for `review_code`: route to the pod's ReAct loop, wait for completion, return result
- Error mapping: Elixir error tuples → MCP error codes

### Claude Desktop integration test (first major milestone)
- Configure Claude Desktop: add DesignatorInator pod as MCP server in `claude_desktop_config.json`
- Run `designator-inator serve ./examples/code-reviewer/`
- Send a code review request from Claude Desktop
- Verify Claude Desktop receives the result
- **This validates the entire stack end-to-end**

### SSE transport
- Add HTTP server (Bandit + Plug) listening on a configurable port
- `/sse` endpoint: send MCP messages as Server-Sent Events
- `/message` endpoint: receive MCP calls via POST
- Allows browser-based clients and remote connections
- Config: `config :designator_inator, :mcp_http_port, 4000`

### MCPGateway multi-pod routing
- The gateway aggregates tools from ALL running pods under a single MCP interface
- Tool names are namespaced: `<pod-name>__<tool-name>` (e.g. `code_reviewer__review_code`)
- When a call arrives, parse the namespace, route to the correct pod
- Pods registering/deregistering update the gateway's tool list in real-time (no restart needed)

**Milestone 4 test:** Start two pods. Connect Claude Desktop to `designator-inator serve` (multi-pod mode). Verify both pods' tools appear in Claude's tool list. Call each one successfully.

---

## Milestone 5 — Cloud Provider Integration

**Goal:** Pods can fall back to Anthropic/OpenAI when local resources are insufficient.

**Scaffolding status: DONE**
**Status: DONE** — Anthropic/OpenAI provider request paths and ModelManager auto-fallback routing are implemented and verified with targeted tests.

### Checklist

- [x] `InferenceProvider` behaviour defined with default `stream/3`
- [x] `Providers.Anthropic` scaffolded
- [x] `Providers.OpenAI` scaffolded
- [x] `ModelManager.provider_for/1` implemented (model name prefix routing)
- [x] Config struct supports `providers:` section with `api_key_env` fields
- [x] `Providers.Anthropic.complete/2` implemented
- [x] `Providers.Anthropic.model_id/1` implemented (short name → API model ID)
- [x] `Providers.Anthropic.messages_to_anthropic/1` implemented
- [x] `Providers.OpenAI.complete/2` implemented
- [x] `Pod.Config.resolve_api_key/2` implemented
- [x] `ModelManager` fallback logic implemented (`fallback_mode: auto` triggers on 3 consecutive errors or VRAM full)
- [x] **Milestone 5 test passing:** VRAM full → auto-fallback routes to cloud provider

### Provider abstraction
- Define `DesignatorInator.InferenceProvider` behaviour: `complete(messages, opts)` → `{:ok, response}` | `{:error, reason}`
- Implementations: `DesignatorInator.Providers.LlamaCpp`, `DesignatorInator.Providers.Anthropic`, `DesignatorInator.Providers.OpenAI`
- `ModelManager.complete/2` selects provider based on the model name prefix (e.g. `claude-*` → Anthropic, `gpt-*` → OpenAI, else local)

### API key management
- Keys are **never stored in pod directories**
- Resolution order:
  1. Pod's `config.yaml` can reference an env var name: `api_key_env: ANTHROPIC_API_KEY`
  2. Falls back to central config: `~/.designator_inator/config.yaml`
  3. Falls back to environment variable of the same name
- Keys are read at runtime, never written to disk by DesignatorInator

### config.yaml model spec
```yaml
model:
  primary: mistral-7b-instruct      # local GGUF (name or path)
  fallback: claude-sonnet           # cloud model
  fallback_mode: auto               # auto | manual | disabled
  providers:
    anthropic:
      api_key_env: ANTHROPIC_API_KEY
    openai:
      api_key_env: OPENAI_API_KEY
```

### Fallback logic
- `fallback_mode: auto` — triggers when: local VRAM is full, model load fails, local inference returns an error 3x in a row
- `fallback_mode: manual` — only when pod explicitly requests cloud (e.g. for tasks that need frontier model capability)
- `fallback_mode: disabled` — strict local-only, error instead of cloud fallback
- Log clearly when fallback triggers and why

**Milestone 5 test:** Fill local VRAM. Send a request to a pod configured with `fallback: claude-sonnet` and `fallback_mode: auto`. Verify it routes to Anthropic and returns a valid response.

---

## Milestone 6 — Orchestration

**Goal:** A meta-agent that decomposes tasks and delegates to other pods.

**Status: DONE** — SwarmRegistry, node monitoring, model-aware pod selection, and cross-node pod lookup are implemented and verified.
**Scaffolding status: DONE**
**Implementation status: DONE**

### Checklist

- [x] `SwarmRegistry` scaffolded (`swarm_registry.ex` — 8 stubs, `:pg` design documented)
- [x] `NodeInfo` data type defined (`types.ex`)
- [x] `ModelManager.node_info/0` stub scaffolded
- [x] `SwarmRegistry.init/1` implemented (`:pg` scope start, node monitoring)
- [x] `SwarmRegistry.find_pod/1` implemented (local preference)
- [x] `SwarmRegistry.list_all/0`, `list_on_node/1` implemented
- [x] `SwarmRegistry.connect/1` implemented
- [x] `SwarmRegistry.handle_info {:nodeup, ...}` implemented
- [x] `SwarmRegistry.handle_info {:nodedown, ...}` implemented (cleanup + notify MCPGateway)
- [x] `SwarmRegistry.node_infos/0` implemented
- [x] `ModelManager.node_info/0` implemented (builds `NodeInfo` from current state)
- [x] Cross-node routing in orchestrator (prefer node with model already loaded)
- [x] `CLI.cmd_connect/1` implemented
- [x] **Milestone 7 test passing:** registry lookups, node monitoring, and CLI connect tests green

### ToolRegistry
- ETS-backed registry (fast reads, in-memory)
- Maps `tool_name → {pod_pid, pod_name, tool_schema}`
- GenServer wrapper handles concurrent updates safely
- API: `register(pod_name, tools)`, `deregister(pod_name)`, `lookup(tool_name)`, `list_all()`
- Updated automatically when `PodSupervisor` starts/stops pods

### Orchestrator pod
- A regular pod directory (`./pods/orchestrator/`) with:
  - `soul.md` describing how to decompose tasks and delegate
  - Internal tools that are the other pods (fetched from ToolRegistry at runtime)
  - Configured to use a high-capability model (or cloud model)
- When given a task, its ReAct loop calls other pods' exposed tools as if they were regular tools
- The orchestrator doesn't have hardcoded routing — the LLM decides delegation based on available tools and soul.md instructions
- Swap `soul.md` to change orchestration strategy without touching code

### Async task delegation
- Pods can be called in parallel — the orchestrator dispatches multiple subtasks simultaneously via `Task.async_stream`
- Each delegated call gets a task ID tracked in the orchestrator's state
- Result aggregation: wait for all parallel tasks before synthesizing final response (configurable timeout per subtask)
- Sequential fallback: if memory is constrained (detected via ModelManager), queue tasks instead of parallelizing

### Task tracking
- Orchestrator maintains a task graph in its GenServer state: `%{task_id => %Task{status, pod, result, started_at}}`
- `get_status` exposed tool returns the current task graph as JSON
- Persisted to SQLite periodically (survives orchestrator restart)

### Error recovery
- When a delegated subtask fails (pod crash, timeout, bad output):
  1. Check if another pod can handle the same tool (ToolRegistry may have duplicates)
  2. If yes: retry with alternate pod
  3. If no: attempt the subtask directly with the orchestrator's own model
  4. If still failing: return partial result with error annotation, don't block other subtasks

**Milestone 6 test:** Send the orchestrator a multi-step task ("research X, write a summary, review the summary for accuracy"). Verify it delegates to three different pods in parallel where possible. Kill one pod mid-task. Verify the orchestrator recovers gracefully.

---

## Milestone 7 — Distributed Swarm

**Goal:** DesignatorInator nodes on different machines form a single logical swarm.

**Scaffolding status: DONE**
**Implementation status: NOT STARTED**

### Checklist

- [x] `SwarmRegistry` scaffolded (`swarm_registry.ex` — 8 stubs, `:pg` design documented)
- [x] `NodeInfo` data type defined (`types.ex`)
- [x] `ModelManager.node_info/0` stub scaffolded
- [ ] `SwarmRegistry.init/1` implemented (`:pg` scope start, `Node.monitor_nodes/1`)
- [ ] `SwarmRegistry.find_pod/1` implemented (local preference)
- [ ] `SwarmRegistry.list_all/0`, `list_on_node/1` implemented
- [ ] `SwarmRegistry.connect/1` implemented
- [ ] `SwarmRegistry.handle_info {:nodeup, ...}` implemented
- [ ] `SwarmRegistry.handle_info {:nodedown, ...}` implemented (cleanup + notify MCPGateway)
- [ ] `SwarmRegistry.node_infos/0` implemented
- [ ] `ModelManager.node_info/0` implemented (builds `NodeInfo` from current state)
- [ ] Cross-node routing in orchestrator (prefer node with model already loaded)
- [ ] `CLI.cmd_connect/1` implemented
- [ ] **Milestone 7 test:** two-node LAN swarm, cross-node task delegation, node failure recovery

### Node connection
- Each DesignatorInator instance is an Erlang node named `designator_inator@<hostname>`
- Erlang cookie configured in `~/.designator_inator/config.yaml` — must match across all nodes in the swarm
- `designator-inator connect <ip>` CLI command: calls `Node.connect(:"designator_inator@<ip>")` and reports success/failure
- Auto-reconnect: monitor node connections, attempt reconnect on disconnect with exponential backoff

### SwarmRegistry (cross-node pod discovery)
- Uses Erlang's `:pg` (process groups) module — built into OTP, zero extra dependencies
- When any pod starts anywhere in the swarm, it joins a `:pg` group named `{:pods, pod_name}`
- `SwarmRegistry.find_pod(name)` → finds the process regardless of which node it's on
- `SwarmRegistry.list_all()` → aggregates pods across all connected nodes

### Cross-node model awareness
- Each node's `ModelManager` registers its state (available VRAM, loaded models, RAM) in a distributed ETS table (via `:global` or a custom `GenServer` with `Node.list/0` fanout)
- Orchestrator can query: "which node has `codellama-13b` already loaded?" and route there to avoid reload latency
- Updates broadcast on model load/unload events

### Cross-node task delegation
- The orchestrator calls pod tools via the Elixir message-passing interface — `GenServer.call(pod_pid, request)` works the same whether `pod_pid` is local or on another node
- No special code needed for cross-node calls; Erlang distribution handles serialization and transport transparently
- Timeout values account for network latency (configurable, default higher than local timeouts)

### Node failure handling
- Monitor connected nodes with `Node.monitor_nodes(true)` — get `:nodedown` messages on disconnect
- On `:nodedown`: `SwarmRegistry` removes all pods from that node
- Orchestrator's task tracker marks tasks assigned to that node as `:failed`
- Error recovery (from Milestone 6) kicks in: retry on remaining nodes or handle locally
- If the failed node was hosting a model the orchestrator needs: trigger model load on an available node

**Milestone 7 test:** Two machines on LAN, both running DesignatorInator. Connect them. Start a code-reviewer pod on Machine B. From Machine A's orchestrator, send a task that requires code review. Verify it routes to Machine B's pod and returns the result. Power off Machine B mid-task. Verify Machine A's orchestrator recovers.

---

## Open Questions — Resolved

### Tool call parsing format
Build a pluggable parser from day one. Start with two formats: ChatML and Llama3 (they cover most current GGUFs). The parser module is selected per-model based on the GGUF's metadata or config override. Adding a new format = adding one module.

### Async orchestration
Default: orchestrator dispatches subtasks in parallel via `Task.async_stream`, collects results. Falls back to serial if memory is constrained. The pod doesn't need to know — it just answers calls.

### MCP gateway authentication
Generate per-client API tokens stored in `~/.designator_inator/tokens.yaml`. HTTP clients include `Authorization: Bearer <token>` header. Stdio connections (Claude Desktop) are trusted by default (they're local processes). Add this in Milestone 4 SSE work.

### Pod sharing / marketplace
Pods are just directories. Initially: share via git repos. Keep `manifest.yaml` schema stable. A registry (like a curated GitHub org) comes later once the format is proven. Don't build registry infrastructure now.

---

## Cross-Cutting Concerns

### Logging
- Use Elixir's built-in `Logger` with structured metadata: `Logger.info("inference complete", pod: name, model: model, duration_ms: ms)`
- `designator-inator logs <pod-name>` tails the pod's log stream
- Log rotation handled by the OS (systemd journal or logrotate)

### Configuration hierarchy
```
~/.designator_inator/config.yaml      # user-level defaults
./my-agent/config.yaml        # pod-level overrides
environment variables          # override everything (12-factor)
```

### Testing strategy
- Unit test each GenServer in isolation with mocked dependencies
- Integration test llama-server interaction against a real small GGUF (e.g. `tinyllama-1.1b`)
- MCP protocol tests: write raw JSON-RPC to stdio, assert responses
- A small example pod lives in `./examples/` and serves as the end-to-end test fixture

### First example pod to build
`examples/assistant/` — a simple general-purpose assistant with workspace read/write. Used as the integration test target for every milestone.

---

## Build Order (first sprint)

1. `mix new designator_inator --sup` + supervisor skeleton — **DONE (scaffolded)**
2. llama-server Port GenServer — **TODO**
3. `ModelManager.complete/2` (one model, no VRAM management yet) — **TODO**
4. ReAct loop (no tools, just model → response) — **TODO**
5. Workspace tool — **TODO**
6. soul.md loading — **TODO**
7. `manifest.yaml` parser + `start_pod/1` — **TODO**
8. `designator-inator run` CLI — **TODO**
9. MCP stdio server — **TODO**
10. Claude Desktop integration test ← **first real milestone worth demoing** — **TODO**

Everything after step 10 builds on a proven, working foundation.

---

## Next Steps

> This section is maintained by agents. Update it when you finish work.
> Remove items you complete. Add items you discover during implementation.

### Immediate — continue Milestone 6 implementation

Milestones 2, 4, and 5 are complete and verified. Milestone 3's core pod lifecycle and CLI commands are wired. Milestone 6 is now underway.

**Immediate next steps:**

1. Implement async parallel task delegation in the orchestrator chat handler
2. Add task-graph persistence to SQLite
3. Add recovery logic for alternate-pod retry and fallback-to-self behavior

Proceed in the same HTDP unit-test-by-module fashion.

### After Milestone 2 — first end-to-end smoke test

After Milestone 2 is done, you can run a real (manual) end-to-end test before writing any more code:

```elixir
# In iex -S mix:
{:ok, _} = DesignatorInator.PodSupervisor.start_pod("examples/assistant")
DesignatorInator.Pod.chat("assistant", "List my workspace files", nil)
```

This exercises the entire stack: pod startup → soul.md load → ModelManager → ReActLoop → Workspace tool → Memory.

### After Milestone 3 — first CLI demo

```bash
designator-inator run ./examples/assistant/
```

Should start, prompt for input, and respond.

### After Milestone 4 — first Claude Desktop integration

Run `designator-inator serve ./examples/assistant/` and add it to Claude Desktop's MCP config. This is the first milestone worth showing to someone outside the project.

---

## Decisions Made

> Record design decisions here so future agents don't relitigate them.

| Decision | Rationale | Date |
|----------|-----------|------|
| Port over NIFs for llama-server | NIF crash kills the VM; Port crash is just a process exit | Scaffolding phase |
| BEAM isolation by default, Podman opt-in | Zero deps on first run; container support added per-pod when needed | Scaffolding phase |
| MCP as universal protocol | IDE integrations free; no proprietary protocol to maintain | Scaffolding phase |
| Orchestrator is a Pod with soul.md, not hardcoded routing | Strategy is prompt-configurable without code changes | Scaffolding phase |
| `:pg` for swarm discovery, no Redis/Kafka | Built into OTP; works on LAN with zero infrastructure | Scaffolding phase |
| ETS for ToolRegistry reads | O(1) concurrent reads; GenServer only serializes writes | Scaffolding phase |
| `_workspace_root` injected via params map into Tool.call | Avoids module state; tools remain stateless and testable | Scaffolding phase |
| Tool namespacing with `__` separator in MCPGateway | Avoids collisions when multiple pods expose same tool name | Scaffolding phase |
| `Pod` uses a configurable `:tool_registry_module` seam and skips default registry writes when the registry isn't started | Keeps pod unit tests deterministic without booting the whole app | 2026-04-03 |
| `internal_tools: ["pods"]` exposes namespaced pod tools from `ToolRegistry` | Lets the orchestrator see other pods as ordinary tools without hardcoded routing | 2026-04-03 |
| Hardware validation falls back to a soft 8GB check when `:memsup` is unavailable | Keeps pod startup/test runs working in minimal OTP environments | 2026-04-02 |
| Rename ForgeClaw to Designator-inator | Repo, OTP app, module namespace, config paths, and CLI naming should converge on the new product name | 2026-04-02 |

| `ModelInventory.rescan/0` preserves the last known catalog on scan failure | Matches the documented `{:ok, count}` contract and avoids dropping the in-memory inventory due to a transient filesystem error | 2026-04-02 |
| `Providers.LlamaCpp` uses app-configured seams for HTTP, Port opening, and kill commands in tests | Keeps the production code direct while allowing unit tests without a real llama-server process or live HTTP server | 2026-04-02 |
| `ModelManager` uses app-configured provider module seams (`:model_manager_llama_provider`, `:model_manager_openai_provider`, `:model_manager_anthropic_provider`) | Enables deterministic unit tests for load/routing/fallback behavior without launching real provider backends | 2026-04-02 |
| `parse_quantization/1` preserves original casing for unknown strings | `{:unknown, str}` uses the caller's original string, not the uppercased form used for matching | 2026-04-02 |
| Auto-fallback (`:auto`) triggers immediately for load/capacity errors, after 3 consecutive errors for inference failures | Load errors are always fatal for that attempt; transient inference errors may self-correct, so 3 strikes avoids over-routing to cloud on flaky local hardware | 2026-04-02 |
