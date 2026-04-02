defmodule DesignatorInator.Application do
  @moduledoc """
  Root OTP application and supervision tree for DesignatorInator.

  ## Supervision Tree

  The tree is arranged so that lower-level infrastructure starts first and
  higher-level components that depend on it start afterward.  If any supervisor
  or worker crashes beyond its restart budget, the crash propagates upward and
  the entire relevant subtree restarts cleanly.

      DesignatorInator.Application
      ├── DesignatorInator.Memory.Repo          (Ecto SQLite repo)
      ├── DesignatorInator.ModelInventory       (scans model directory)
      ├── DesignatorInator.ModelManager         (manages llama-server instances + cloud)
      ├── DesignatorInator.ToolRegistry         (ETS-backed tool catalog)
      ├── DesignatorInator.SwarmRegistry        (cross-node pod discovery via :pg)
      ├── DesignatorInator.PodSupervisor        (DynamicSupervisor for agent pods)
      └── DesignatorInator.MCPGateway           (MCP JSON-RPC gateway — stdio + SSE)

  Components deliberately NOT in this tree:
  - Individual `DesignatorInator.Pod` processes — they are children of `PodSupervisor`.
  - `DesignatorInator.Providers.LlamaCpp` server processes — they are children of
    `ModelManager`.
  """

  use Application
  require Logger

  @impl Application
  def start(_type, _args) do
    Logger.info("DesignatorInator starting up")

    children = [
      # 0. Pod name registry — must be first; Pod processes register here on init
      {Registry, keys: :unique, name: DesignatorInator.PodRegistry},

      # 1. Persistence — must be first; everything else may write on startup
      DesignatorInator.Memory.Repo,

      # 2. Model inventory — reads disk, no side effects, no deps
      DesignatorInator.ModelInventory,

      # 3. Model manager — depends on inventory being readable
      DesignatorInator.ModelManager,

      # 4. Tool and swarm registries — pure ETS / :pg, no deps
      DesignatorInator.ToolRegistry,
      DesignatorInator.SwarmRegistry,

      # 5. Pod supervisor — depends on ModelManager and ToolRegistry being up
      DesignatorInator.PodSupervisor,

      # 6. MCP gateway — depends on PodSupervisor and ToolRegistry
      DesignatorInator.MCPGateway
    ]

    opts = [strategy: :one_for_one, name: DesignatorInator.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
