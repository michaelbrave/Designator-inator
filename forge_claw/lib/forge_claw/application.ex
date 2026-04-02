defmodule ForgeClaw.Application do
  @moduledoc """
  Root OTP application and supervision tree for ForgeClaw.

  ## Supervision Tree

  The tree is arranged so that lower-level infrastructure starts first and
  higher-level components that depend on it start afterward.  If any supervisor
  or worker crashes beyond its restart budget, the crash propagates upward and
  the entire relevant subtree restarts cleanly.

      ForgeClaw.Application
      ├── ForgeClaw.Memory.Repo          (Ecto SQLite repo)
      ├── ForgeClaw.ModelInventory       (scans model directory)
      ├── ForgeClaw.ModelManager         (manages llama-server instances + cloud)
      ├── ForgeClaw.ToolRegistry         (ETS-backed tool catalog)
      ├── ForgeClaw.SwarmRegistry        (cross-node pod discovery via :pg)
      ├── ForgeClaw.PodSupervisor        (DynamicSupervisor for agent pods)
      └── ForgeClaw.MCPGateway           (MCP JSON-RPC gateway — stdio + SSE)

  Components deliberately NOT in this tree:
  - Individual `ForgeClaw.Pod` processes — they are children of `PodSupervisor`.
  - `ForgeClaw.Providers.LlamaCpp` server processes — they are children of
    `ModelManager`.
  """

  use Application
  require Logger

  @impl Application
  def start(_type, _args) do
    Logger.info("ForgeClaw starting up")

    children = [
      # 0. Pod name registry — must be first; Pod processes register here on init
      {Registry, keys: :unique, name: ForgeClaw.PodRegistry},

      # 1. Persistence — must be first; everything else may write on startup
      ForgeClaw.Memory.Repo,

      # 2. Model inventory — reads disk, no side effects, no deps
      ForgeClaw.ModelInventory,

      # 3. Model manager — depends on inventory being readable
      ForgeClaw.ModelManager,

      # 4. Tool and swarm registries — pure ETS / :pg, no deps
      ForgeClaw.ToolRegistry,
      ForgeClaw.SwarmRegistry,

      # 5. Pod supervisor — depends on ModelManager and ToolRegistry being up
      ForgeClaw.PodSupervisor,

      # 6. MCP gateway — depends on PodSupervisor and ToolRegistry
      ForgeClaw.MCPGateway
    ]

    opts = [strategy: :one_for_one, name: ForgeClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
