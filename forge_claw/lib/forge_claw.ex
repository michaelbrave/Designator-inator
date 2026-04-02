defmodule ForgeClaw do
  @moduledoc """
  ForgeClaw — local-first AI agent orchestration on Elixir/BEAM.

  ## Core Concepts

  - **Pod** — a self-contained, portable agent package (a directory with
    `manifest.yaml`, `soul.md`, `config.yaml`, and a `workspace/`).  Each pod
    runs as an isolated BEAM process tree supervised by `ForgeClaw.PodSupervisor`.

  - **MCP everywhere** — every pod is simultaneously an MCP *client* (it calls
    tools) and an MCP *server* (it exposes tools to the orchestrator and to
    external clients such as Claude Desktop).  The protocol is the same at
    every layer.

  - **ModelManager** — routes inference requests to the right backend: a local
    `llama-server` process (via OS Port), the Anthropic API, or OpenAI.  It
    tracks VRAM/RAM usage and evicts least-recently-used models when the budget
    is exceeded.

  - **Orchestrator** — a special pod whose internal "tools" are the other pods.
    It decomposes tasks and delegates using its own ReAct loop.  Delegation
    strategy lives in `soul.md`, not in code.

  - **Swarm** — multiple ForgeClaw nodes connect over a LAN via Erlang
    distribution.  No extra infrastructure required.

  ## Quick start

      # Start a pod interactively
      $ forge run ./examples/assistant/

      # Expose a pod as an MCP server (for Claude Desktop)
      $ forge serve ./examples/assistant/

      # List running pods
      $ forge list

  See `ForgeClaw.PodSupervisor`, `ForgeClaw.ModelManager`, and
  `ForgeClaw.MCPGateway` for the main entry points.
  """
end
