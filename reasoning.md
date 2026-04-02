## Initial reasoning

so there are a lot of AI agent orchestration frameworks being built lately but I sort of don't like most of them, they feel like a house of cards with too much dependencies and not great defaults. For example I was trying to run paperclip \+ hermesagent \+ using local llms via lmstudio, and it just sort of didn't work even though in theory it should. So I'm thinking of making my own, but it would start with something like ollamma or llama.cpp or lmstudio and then we would build in the agent harness into it, and then build the orchestration layer into it also, maybe we borrow from a lot of projects and re-code them into a new language, maybe something like mojo or elixer that feels like tougher engineering-grade but also fast etc. I want to know your advice

part of the reason I was thinking of going down to the ollama/lmstudio level is partly to spin up multiple instances and run local swarms, I think this would work better if it was all better integrated. we could use lightweight things as a base though, picoclaw looks well done even if it is missing many features. we can't base of lmstudio but could we support lmstudio's formats the gguf etc? we might be able to use pi as a way to build this out and create orchestration layers too though? sounds like you recomend to use llama.cpp instead of rewriting it, that might be wise, it's low enough level and integrates well enough and they may add useful updates to it in the future. one other thought, I had considered this a seperate project but maybe it isn't the idea was to containerize agents and their tools and mcp servers in a kind of package that could be used to plug and play an agent setup and call on them for specific tasks, like a specialized sub agent but maybe it runs on a specific model for a specific tasks and comes with it's own soul.md and all the included tools it would need etc, this might just become an extension of this larger project, if it's all integrated it could be very good

---

# **DesignatorInator — Build Specification**

## **What This Is**

DesignatorInator is a local-first AI agent orchestration system built on Elixir/BEAM. It manages local model inference via llama.cpp, runs agents as isolated "Pods" with their own personas and tools, exposes everything through MCP (Model Context Protocol) for interoperability, and supports distributed swarms across devices on a LAN.

The core insight is **"every agent is an MCP server."** Agents don't use proprietary protocols — they expose standard MCP tools to each other and to the outside world. This means the system is natively compatible with Claude Desktop, Cursor, and anything else that speaks MCP, without building custom UIs.

---

## **Why Elixir / BEAM**

This decision deserves a clear rationale since it's unconventional for AI tooling:

**Fault isolation is the killer feature.** The BEAM VM runs each process in its own lightweight isolated context. When an agent's ReAct loop crashes because an LLM returned malformed JSON (and it will), only that process dies. The supervisor restarts it in microseconds. In Python frameworks, one bad exception in an async chain can take down the whole orchestrator.

**Native distributed clustering.** Erlang was built for telecom switches that can't go down. `Node.connect/1` gives you cross-machine process communication with zero infrastructure — no Redis, no RabbitMQ, no Kubernetes. For a solo dev wanting to run agents across a PC and some Pis, this is enormous. You'd need weeks of infrastructure work to replicate this in Python.

**Lightweight concurrency.** BEAM processes cost \~2KB each. You can run tens of thousands simultaneously. This matters when each agent pod, each tool call, each model request is its own supervised process.

**The tradeoff:** The AI/ML ecosystem is Python-heavy, so you won't have libraries like LangChain or LlamaIndex to lean on. But that's actually the point — those libraries are the "house of cards" you're replacing. llama.cpp is a C++ binary managed via HTTP API, so language doesn't matter for inference.

---

## **Architecture Overview**

The system is a single Elixir application structured as a supervisor tree. Everything is a process, everything is supervised, everything can crash and recover independently.

**Top-level supervisors and what they own:**

* **DesignatorInator.Application** — The root. Starts everything below.  
  * **DesignatorInator.ModelManager** — Manages all inference backends (local llama.cpp instances AND cloud provider connections). Monitors VRAM/RAM, loads/unloads GGUFs, routes inference requests to the right backend.  
  * **DesignatorInator.PodSupervisor** — A DynamicSupervisor that spawns and monitors Agent Pods. Each pod is a child process (or process tree). If a pod crashes, it restarts with state preserved from its last checkpoint.  
  * **DesignatorInator.SwarmRegistry** — Uses Erlang's `:pg` (process groups) to track all active pods across all connected nodes. This is what makes distributed routing work.  
  * **DesignatorInator.MCPGateway** — The bridge between internal Elixir messages and external MCP JSON-RPC over stdio/SSE. This is how Claude Desktop, Cursor, or any MCP client talks to the swarm.  
  * **DesignatorInator.ToolRegistry** — Central catalog of all available MCP tools across all pods. When the orchestrator needs to decide who can handle a task, it queries this.  
  * Note: do we need a model router or a router model too or does the model manager also do that?

---

## **The Model Manager (Inference Layer)**

This is the lowest layer — it handles actually running models.

### **Local Inference (llama.cpp)**

**How it works:** DesignatorInator spawns `llama-server` as an OS process via Elixir's `Port` module. Each running model gets its own `llama-server` process, managed by a GenServer that handles health checks, request routing, and lifecycle.

**Why Port and not NIFs:** NIFs (native bindings) crash the entire BEAM VM if they segfault. A Port is an external OS process — if llama-server crashes, the Port GenServer detects it and restarts it. This is critical for stability.

**Why not just use Ollama:** Ollama is great for end users but it's a black box. You can't control context window allocation, VRAM splitting across multiple models, or layer offloading granularity. Managing llama-server directly gives you full control over these, which matters when you're running a swarm where different pods need different models loaded simultaneously.

**Model resolution order:**

1. Pod's `config.yaml` specifies a model by name (e.g., `mistral-7b-instruct-v0.3.Q4_K_M`)  
2. ModelManager checks local model directory for a matching GGUF file  
3. If not found, auto-pulls from a configurable registry (HuggingFace by default, same URL pattern Ollama uses)  
4. Pod can also specify an absolute path override for custom fine-tunes

**VRAM/RAM management:** The ModelManager maintains a budget of available memory. When a pod requests a model, it checks whether it's already loaded (shared across pods if same model), whether there's room to load it, or whether a less-recently-used model should be evicted. This is essentially an LRU cache for loaded models.

### **Cloud Inference (Fallback/Option)**

**Provider abstraction:** The ModelManager also supports cloud backends. A pod's `config.yaml` can specify:

yaml  
model:  
  primary: mistral\-7b\-instruct    \# local GGUF  
  fallback: claude\-sonnet          \# cloud fallback  
  provider\_config:  
    claude:  
      api\_key\_env: ANTHROPIC\_API\_KEY  
    openai:  
      api\_key\_env: OPENAI\_API\_KEY  
\`\`\`  
Note: we shouldn’t store the API key here at the local model level but pull from a centralized storage of keys, likely a config file for the larger system (but it might be useful to specialize accounts to certain models too, we will explore it, likely it pulls from here first, if not here pulls from central config etc)

**\*\*The** interface is the same regardless of backend.**\*\*** The pod calls \`ModelManager.complete(prompt, opts)\` and doesn't know or care whether it's hitting a local llama\-server or the Claude API. This is important — it means pods are portable between local and cloud setups.

**\*\*When** cloud fallback triggers:**\*\*** Either explicitly (pod config says "use Claude for this"), or when local resources are exhausted and a task is waiting. This should be configurable — some users will want strict local\-only, others will want auto\-fallback.

\---

\#\# The Agent Pod Standard

A Pod is a self\-contained, portable agent package. It is a directory with a known structure:  
\`\`\`  
my\-agent/  
├── manifest.yaml          \# Identity, hardware reqs, exposed MCP tools  
├── soul.md                \# Persona, instructions, boundaries  
├── config.yaml            \# Model preferences, inference params  
├── tools/                 \# MCP servers this agent consumes internally  \- Note: not just mcp but also skill files and maybe scripts etc  
│   ├── filesystem/        \# e.g., local file access tool  
│   └── web\-search/        \# e.g., a search tool  
└── workspace/             \# Persistent working directory for this agent

### **manifest.yaml**

This is the pod's "package.json." It declares what the pod is, what it needs, and what it offers:

yaml  
name: code\-reviewer  
version: 1.0.0  
description: "Reviews code for bugs, style issues, and security concerns"

requires:  
  min\_ram\_mb: 4096  
  min\_context: 8192  
  gpu: optional

model:  
  recommended: "codellama-13b-instruct.Q4\_K\_M"  
  minimum: "codellama-7b-instruct.Q4\_K\_M"  
  fallback: "claude-sonnet"

exposed\_tools:  
  \- name: review\_code  
    description: "Submit code for review. Returns annotated feedback."  
    parameters:  
      code: { type: string, required: **true** }  
      language: { type: string, required: **false** }  
      focus: { type: string, enum: \[bugs, style, security, all\], default: all }

  \- name: get\_status  
    description: "Check if the agent is idle or working"

  \- name: halt  
    description: "Cancel current task"

internal\_tools:  
  \- filesystem    \# can read/write to its workspace  
  \- shell         \# can run commands (sandboxed)

### **soul.md**

This is the agent's persona and instruction set. It's loaded into the system prompt for every inference call the pod makes. This is where you define the agent's "personality," what it should and shouldn't do, its reasoning approach, etc.

### **The Dual-MCP Nature**

This is the key architectural concept. Every pod has two MCP roles simultaneously:

**As an MCP Client (inward-facing):** The agent's internal reasoning loop calls tools. These tools are themselves MCP servers mounted inside the pod. A code reviewer pod might have a filesystem tool (to read files), a shell tool (to run linters), and a git tool (to check diffs). The agent calls these through standard MCP tool-use protocol.

**As an MCP Server (outward-facing):** The pod exposes itself to the rest of the system (and the outside world) as an MCP server. Its `exposed_tools` from the manifest become MCP tools that the orchestrator, other pods, or external clients (Claude Desktop) can call. When someone calls `review_code(code="...")`, the pod receives the request, runs its internal reasoning loop using its internal tools, and returns the result. (Note: I’m not 100% sure this is the right framing, rather it is an agent that can use and orchestrate mcp servers while also being one, a link in the chain in a way)

This is "fractal MCP" — MCP servers calling MCP servers all the way down. The protocol is the same at every level, which keeps the system conceptually simple even as it scales.

---

## **Isolation Strategy**

**Default: BEAM process isolation.** Each pod runs as its own Elixir process tree. BEAM processes are already memory-isolated and crash-isolated. For most pods (research, writing, analysis), this is sufficient and has zero overhead.

**Elevated: Container isolation.** For pods that run untrusted code (shell tools, code execution), the pod's process tree spawns its work inside a container. The architecture supports this through a configurable `isolation` field in the manifest:

yaml  
isolation: beam          \# default — lightweight, fast  
isolation: container     \# full container sandbox  
isolation: container  
container\_runtime: podman  \# or docker, auto-detected

**The abstraction layer:** Regardless of isolation mode, the pod's MCP interface is identical. The orchestrator doesn't know or care whether a pod is running as a bare BEAM process or inside a container. This means you can start everything as BEAM processes and add container isolation for specific pods later without changing any other code.

**Why not Docker by default:** Docker requires Docker to be installed. You want zero dependencies on first run. A user should be able to `mix release`, run the binary, and have agents working. Container support is opt-in for pods that need it.

---

## **The Orchestrator**

The orchestrator is itself an Agent Pod — it runs a higher-capability model (or cloud model) and its "tools" are the other pods in the swarm. When it receives a complex request, it:

1. Queries the ToolRegistry for all available pod capabilities  
2. Decomposes the task using its own reasoning loop  
3. Delegates subtasks by calling the exposed MCP tools of specialized pods  
4. Aggregates results and either returns them or delegates further

**This is not hardcoded routing.** The orchestrator is an LLM-driven agent that decides how to use available tools, just like any ReAct agent. The difference is that its "tools" are other agents. You can swap the orchestrator's soul.md to change delegation strategy without changing code.

**Simple mode:** For single-agent use (early development), the orchestrator is optional. You can run a single pod directly and interact with it through MCP.

---

## **Swarm (Distributed Operation)**

**How Erlang distribution works (simplified):** Each machine running DesignatorInator is a "node." Nodes connect to each other with `Node.connect(:"designator_inator@192.168.1.50")`. Once connected, processes on different nodes can send messages to each other transparently — the code doesn't change whether the target process is local or remote.

**Discovery:** When a pod starts on any node, it registers itself in the `:pg` process group. The SwarmRegistry on every node sees it. When the orchestrator on Node A needs a code reviewer, it checks the registry, finds one on Node B, and calls it. The Erlang VM handles the networking.

**Requirements:** Nodes must be on the same LAN and share an Erlang cookie (a shared secret string). This is secure enough for local networks. WAN support would require adding TLS and authentication, which is a future concern.

**Model awareness across nodes:** The ModelManager on each node reports its available VRAM/RAM and currently loaded models to the swarm. The orchestrator can make informed routing decisions — send a task to the node that already has the right model loaded, or to the node with the most free VRAM.

---

## **Build Checklist**

This is ordered so each step produces something testable before moving to the next.

### **Foundation**

* **Set up Elixir project** — `mix new designator_inator --sup` with the supervisor tree skeleton. Get it compiling and running with empty supervisors.  
* **llama-server Port wrapper** — GenServer that can spawn a `llama-server` process, point it at a GGUF file, health-check it, and shut it down cleanly. Test: start the server, send a completion request via HTTP, get a response back.  
* **Model inventory** — Scan a configurable directory for GGUF files, parse their metadata (parameter count, quantization), expose as a queryable list. Test: point at a directory with GGUFs, get back a list of available models.  
* **Basic inference GenServer** — Wraps the llama-server HTTP API with a clean Elixir interface. Handles request queuing, timeouts, streaming. Test: `ModelManager.complete("Hello world", model: "mistral-7b")` returns a response.  
* **VRAM/RAM budget tracking** — Monitor available memory, track what's loaded, implement LRU eviction when a new model is requested but memory is full. Test: load two models, request a third that doesn't fit, verify the least-recently-used one is evicted.

### **Single Agent**

* **ReAct loop implementation** — The core agent reasoning loop: prompt the model, parse tool calls from the response, execute tools, feed results back, repeat until the agent produces a final answer. Start with a simple regex/JSON parser for tool calls. Test: give an agent a prompt that requires using a tool, verify it calls the tool and incorporates the result.  
* **soul.md loading** — Read a soul.md file and prepend it to every inference call as system prompt. Test: create an agent with a specific persona, verify the persona comes through in responses.  
* **Internal tool interface** — Define the MCP client interface for tools the agent consumes. Start with one built-in tool (filesystem read/write to the pod's workspace directory). Test: agent can read and write files in its workspace.  
* **Conversation memory** — SQLite-backed conversation history per pod via Ecto. The agent can reference previous turns. Test: ask the agent something, then ask a follow-up that requires remembering the first answer.

### **Agent Pod Packaging**

* **manifest.yaml parser** — Read and validate pod manifests. Check required fields, validate tool definitions, check hardware requirements against available resources. Test: parse a valid manifest, reject an invalid one.  
* **Pod lifecycle manager** — Start a pod from a directory, load its manifest and soul.md, request its model from ModelManager, initialize its tools, register it as available. Test: `DesignatorInator.start_pod("./my-agent/")` brings up a working agent.  
* **CLI interface** — `designator-inator run ./my-agent/` starts a pod and drops into an interactive chat. `designator-inator list` shows running pods. `designator-inator stop <name>` shuts one down. Test: start a pod from CLI, chat with it, stop it.  
* **Auto-pull models** — When a pod requests a model that isn't local, download it from HuggingFace (or configured registry). Show progress, verify checksum, store in model directory. Test: start a pod that requests a model you don't have, verify it downloads and loads.  
* **Workspace isolation** — Each pod gets its own workspace directory. Internal tools are scoped to this directory — a pod can't read another pod's workspace. Test: start two pods, verify they can't access each other's files.

### **MCP Server Interface**

* **JSON-RPC parser** — Implement MCP's JSON-RPC protocol over stdio. Handle `initialize`, `tools/list`, `tools/call`, and resource endpoints. Test: send raw JSON-RPC messages to stdin, get valid responses on stdout.  
* **Pod-to-MCP-server bridge** — Wrap a running pod's exposed tools as MCP tool definitions. When an MCP `tools/call` comes in, route it to the pod's reasoning loop, return the result. Test: call a pod's tool via raw MCP JSON-RPC.  
* **Claude Desktop integration test** — Configure Claude Desktop to connect to a running DesignatorInator pod as an MCP server. Have Claude send it a task and get results back. This is the first major integration milestone.  
* **SSE transport** — Add Server-Sent Events as an alternative MCP transport (for web-based clients and remote connections). Test: connect to the MCP server via HTTP SSE, call tools.  
* **MCPGateway multi-pod routing** — The gateway exposes ALL running pods' tools under a single MCP interface. External clients see one MCP server with all available tools. The gateway routes calls to the appropriate pod. Test: start two pods, connect Claude Desktop, verify both pods' tools appear.

### **Cloud Provider Integration**

* **Provider abstraction** — Define a common interface for inference backends (local llama.cpp, Anthropic API, OpenAI API). Each provider implements `complete/2` with the same signature. Test: swap a pod between local and cloud inference with only a config change.  
* **API key management** — Read API keys from environment variables (referenced in config.yaml). Never store keys in pod directories. Test: configure a cloud fallback, verify it authenticates correctly.  
* **Fallback logic** — When local inference fails or is unavailable (model too large, VRAM full), automatically route to the configured fallback provider. Make this configurable: `fallback: auto | manual | disabled`. Test: fill VRAM, send a request to a pod with cloud fallback, verify it uses the cloud provider.

### **Orchestration**

* **ToolRegistry** — Central catalog that aggregates all exposed tools from all running pods. Updated in real-time as pods start/stop. Test: start and stop pods, verify the registry reflects current state.  
* **Orchestrator pod** — A special pod whose internal tools are "delegate to other pods." Its soul.md describes how to decompose tasks and delegate. It queries the ToolRegistry to know what's available. Test: send a multi-step task to the orchestrator, verify it delegates to the right pods and assembles the result.  
* **Task tracking** — The orchestrator maintains a task graph: which subtasks are pending, running, completed, or failed. Pods report status via their `get_status` MCP tool. Test: send a complex task, query the orchestrator for status mid-execution.  
* **Error recovery** — When a delegated subtask fails (pod crashes, model gives bad output), the orchestrator can retry, reassign to a different pod, or fall back to handling it itself. Test: kill a pod mid-task, verify the orchestrator handles it gracefully.

### **Distributed Swarm**

* **Node connection** — Boot DesignatorInator on two machines on the same LAN. Connect them with `Node.connect/1`. Verify processes can communicate cross-node. Test: send a message from a process on Node A to a process on Node B.  
* **Cross-node pod discovery** — When a pod starts on any node, it registers in the `:pg` group. The SwarmRegistry on every node sees it. Test: start a pod on Node B, verify Node A's registry shows it.  
* **Cross-node model awareness** — Each node's ModelManager broadcasts its available models and resource usage. The orchestrator uses this to make routing decisions. Test: query available models from the orchestrator, see models across all nodes.  
* **Cross-node task delegation** — The orchestrator on Node A calls a pod's MCP tools on Node B. The Erlang VM handles serialization and transport. Test: delegate a task from Node A to a pod on Node B, get the result back.  
* **Node failure handling** — When a node disconnects (Pi loses power), the SwarmRegistry detects it and removes its pods. Pending tasks on that node are reassigned. Test: kill a node mid-task, verify the orchestrator recovers.

---

## **Key Design Decisions Summary**

**llama.cpp via Port, not NIFs** — Safety over performance. A NIF crash kills the BEAM. A Port crash is just a process exit that gets restarted. Since you're managing inference servers (which can segfault, OOM, etc.), Port is the right choice.

**BEAM isolation by default, containers opt-in** — Zero dependencies on first run. Most agents don't need sandboxing. The ones that do (code execution, shell access) can opt into container isolation. The interface is the same either way.

**MCP as the universal protocol** — By making every pod an MCP server, you get IDE integration for free, avoid inventing a proprietary protocol, and make the system composable. A pod doesn't know whether it's being called by the orchestrator, by Claude Desktop, or by another pod.

**Orchestrator is an agent, not code** — The orchestrator is a pod with a soul.md, not hardcoded routing logic. This means delegation strategy is configurable via prompt engineering rather than code changes. Different orchestrator personas can handle different workflows.

**Cloud as fallback, not primary** — Local inference is always attempted first. Cloud providers are there for when local resources are insufficient or when a task genuinely needs a frontier model. This keeps the system functional offline while allowing power users to leverage cloud APIs.

**Auto-pull with local override** — Pods declare model preferences, the system handles downloading. But users can always point to a specific local GGUF. This balances convenience with control.

---

## **Open Questions to Resolve During Build**

These don't need answers now but will come up:

* **Tool call parsing format** — llama.cpp models have inconsistent tool-calling formats. You'll need to decide whether to standardize on a specific prompt template (ChatML, Llama3 format) or build a parser that handles multiple formats. Recommend: start with one format, add others as needed.  
  * Note: We should make a parser that can do multiple formats  
* **Pod marketplace/sharing** — Your spec mentions "plug and play" pods. Eventually you'll want a way to share pod definitions (git repos? a registry?). Don't build this yet, but keep the manifest format stable so it's possible later.  
  * Yes we will want to share/trade these pods eventually  
* **Streaming vs batch for inter-pod communication** — When the orchestrator delegates to a pod, should it wait for the full response or stream tokens back? Streaming is better UX but more complex. Recommend: batch first, streaming later.  
  * I think we should allow multiple sub agents to be delegated to and orchestrate them in the background, waiting for completion isn’t ideal, but there may be times we have to (like if there is not enough memory  
* **Authentication for MCP gateway** — When you expose the MCPGateway to the network (for IDE access), you need auth. MCP doesn't have a standard auth mechanism yet. This will need a custom solution (API keys, mTLS, etc.).  
  * Api keys are the simplest I think, we could just generate auth tokens or something too

-   
- 

