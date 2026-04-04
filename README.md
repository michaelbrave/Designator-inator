# Designator-inator

Local-first AI agent orchestration on Elixir/BEAM. Every agent is an MCP
server. Runs local GGUF models via llama.cpp, falls back to Anthropic/OpenAI
when needed, and scales to a distributed swarm over Erlang distribution.

---

## The idea

Most AI tooling assumes your work happens in the cloud. You send your code,
documents, and conversations to a remote API, get a response back, and trust
that your data is handled responsibly. That works for many cases — but not all.

Designator-inator is built around a different assumption: **the AI runs where
your data already lives.** A local model on your workstation or home lab reads
your files directly, remembers your conversations in a local database, and
never phones home unless you explicitly configure a cloud fallback.

The second idea is that **agents should be composable**. Rather than one
monolithic assistant that tries to do everything, you build a collection of
specialist pods — a code reviewer, a note-taker, a researcher — each with its
own persona, model, and workspace. An orchestrator pod can delegate tasks
across them. Claude Desktop or Cursor can call all of them through a single
MCP interface, as if they were tools.

The third idea is **the protocol is the interface**. MCP (Model Context
Protocol) is used at every layer: between your IDE and Designator-inator,
between the orchestrator and its sub-agents, and between nodes in a
distributed swarm. This means any MCP-capable client — Claude Desktop, Cursor,
your own scripts — can talk to any pod without extra glue code.

---

## What you can build with it

### A private research assistant

Point a pod at your documents folder. Ask it to summarise meeting notes, find
contradictions across reports, or draft a response based on prior emails. No
document ever leaves your machine. Works completely offline.

```
designator-inator run ./pods/researcher/
You: Summarise everything in workspace/meeting-notes/ from the last two weeks
```

### Specialist agents behind a single MCP interface

Run a `code-reviewer` pod and a `documentation-writer` pod. Connect Claude
Desktop to Designator-inator's `serve` command. Both pods appear as tools in
Claude's interface — you can ask Claude to review a file with one and then
write its docs with the other, all in one conversation.

```json
{
  "mcpServers": {
    "dev-agents": {
      "command": "designator-inator",
      "args": ["serve", "./pods/orchestrator/"]
    }
  }
}
```

### A home lab swarm

You have a desktop with a 3090 and a Raspberry Pi 5 sitting idle. Run
Designator-inator on both. Connect them:

```bash
designator-inator connect 192.168.1.50
```

The orchestrator now sees pods on both machines. It routes tasks to whichever
node has the right model already loaded, avoiding reload latency. If the Pi
goes down, the swarm keeps working. Erlang distribution handles the
fault-tolerance automatically.

### An air-gapped coding environment

Some environments cannot reach the internet. Drop a GGUF model and a
Designator-inator pod onto a machine with no outbound access. Set
`fallback_mode: disabled` in the pod config. The agent runs entirely
offline — useful for secure development environments, regulated industries, or
simply not wanting inference costs.

### An orchestrator that delegates complex tasks

Give the orchestrator pod a high-capability model and a `soul.md` that
describes how to decompose work. When you ask it something multi-step, it
breaks the task down and dispatches subtasks to specialist pods in parallel —
one researches, one writes, one reviews — then synthesises the results. The
orchestrator's strategy lives in `soul.md`, not in code, so you can change it
without touching the application.

---

## Getting Started

### Prerequisites

**Required**

- [Elixir](https://elixir-lang.org/install.html) 1.14 or later (with Erlang/OTP)
- [llama.cpp](https://github.com/ggerganov/llama.cpp) — specifically the
  `llama-server` binary on your `PATH`

  To check if it is installed:
  ```bash
  which llama-cli
  which llama-server
  ```

  To install on macOS:
  ```bash
  brew install llama.cpp
  ```

  On Linux, download a pre-built release from
  [github.com/ggerganov/llama.cpp/releases](https://github.com/ggerganov/llama.cpp/releases)
  or build from source. GPU builds require the CUDA toolkit to be installed
  first — llama.cpp is not itself a prerequisite of Designator-inator, but
  without it local inference will not work.

**Optional**

- An Anthropic or OpenAI API key if you want cloud fallback when local VRAM
  is full or no local model is configured.

---

### Step 1 — Clone and build

```bash
git clone https://github.com/michaelbrave/Designator-inator.git
cd Designator-inator/designator_inator
mix deps.get
mix ecto.setup
```

`mix ecto.setup` creates the SQLite database used for conversation memory.
You only need to run it once.

> **Note:** The CLI is a shell script wrapper (`designator-inator`) rather
> than a compiled escript. This is because the SQLite dependency (exqlite)
> uses a native NIF library that cannot be embedded in an escript archive.
> `mix run` handles NIF loading correctly.

---

### Step 2 — Add the CLI to your PATH

The `designator-inator` script lives in `designator_inator/`. Symlink it to
any directory already on your `PATH`. If llama.cpp installed to
`~/.local/bin`, that directory is likely already on your `PATH`:

```bash
ln -sf ~/projects/Designator-inator/designator_inator/designator-inator \
       ~/.local/bin/designator-inator
```

Verify it is accessible:

```bash
designator-inator
```

You should see the usage summary.

---

### Step 3 — Run the setup wizard

```bash
designator-inator quickstart
```

The wizard walks you through six steps:

| Step | What it does |
|------|-------------|
| 1 | Detects or prompts for the `llama-server` binary path |
| 2 | Sets the directory to scan for GGUF model files |
| 3 | Sets the VRAM/RAM budget for local inference |
| 4 | Optionally enables Anthropic or OpenAI cloud fallback |
| 5 | Creates `~/.designator_inator/` directory structure |
| 6 | Writes `~/.designator_inator/config.yaml` and sets up the database |

Press **Enter** to accept any default shown in brackets. You can re-run
`quickstart` at any time to change settings.

**Suggested VRAM budget:** leave roughly 4 GB headroom below your total VRAM
for the OS, CUDA overhead, and KV cache. For a 24 GB card, `20480` is a good
starting value.

---

### Step 4 — Add GGUF models

Designator-inator scans the models directory you configured in Step 3
(default: `~/.designator_inator/models/`). It searches subdirectories
recursively, so LM Studio's per-model folder layout works out of the box.

Download a model if you do not have one. A 4-bit quantised 7–9B model is a
good starting point — it fits in 6 GB of VRAM and responds quickly:

```bash
# Example: Qwen 3.5 9B (5.6 GB)
curl -L -o ~/.designator_inator/models/Qwen3.5-9B-Q4_K_M.gguf \
  "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf"
```

Or point the models directory at an existing LM Studio models folder during
`quickstart` — the path `/media/<user>/storage/models/lmstudio/lmstudio-community`
is automatically scanned recursively.

Check what models are found:

```bash
designator-inator models
```

---

### Step 5 — Start a pod

Update the example assistant pod to use a model you have. Open
`examples/assistant/config.yaml` and set `primary` to the exact model name
shown by `designator-inator models`:

```yaml
model:
  primary: Qwen3.5-9B-Q4_K_M
  fallback_mode: disabled
```

Then start the pod:

```bash
designator-inator run ~/projects/Designator-inator/examples/assistant/
```

Designator-inator will start `llama-server`, load the model into GPU memory,
and drop you into an interactive chat prompt:

```
[DesignatorInator] Starting pod: assistant
You:
```

The first message takes a few seconds while the model warms up. Subsequent
messages are faster.

Type `/quit` or press **Ctrl-D** to exit.

---

### Step 6 — Connect to Claude Desktop or Cursor

Any MCP client can talk to a Designator-inator pod. Start a pod as an MCP
server over stdio:

```bash
designator-inator serve ~/projects/Designator-inator/examples/assistant/
```

Then add it to your MCP client config. For Claude Desktop, edit
`claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "assistant": {
      "command": "designator-inator",
      "args": ["serve", "/absolute/path/to/examples/assistant/"]
    }
  }
}
```

---

## CLI reference

```
designator-inator quickstart                         First-time setup wizard
designator-inator run <pod-path> [--detach]          Start a pod, enter chat
designator-inator serve <pod-path>                   Expose pod as MCP server
designator-inator list                               List running pods
designator-inator stop <name>                        Stop a pod
designator-inator models                             List available GGUF models
designator-inator connect <ip>                       Join a remote swarm node
```

---

## Pod structure

```
my-agent/
├── manifest.yaml   # identity, hardware requirements, exposed MCP tools
├── soul.md         # persona and system prompt
├── config.yaml     # model selection, inference parameters
└── workspace/      # agent's persistent working directory
```

See `examples/assistant/` for a working example.

---

## Architecture

See [plan.md](plan.md) for the full build plan and milestone status.

| Layer | Choice |
|-------|--------|
| Runtime | Elixir + BEAM |
| Local inference | llama.cpp (`llama-server`) via OS Port |
| Model format | GGUF |
| Protocol | MCP (JSON-RPC over stdio/SSE) |
| Persistence | SQLite via Ecto |
| Distribution | Erlang distribution (`:pg`, `Node.connect/1`) |
