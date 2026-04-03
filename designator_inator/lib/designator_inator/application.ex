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

    # Ensure base directory exists before starting Repo (SQLite needs the directory)
    File.mkdir_p!(Path.expand("~/.designator_inator"))

    # Apply user settings from global config before children start
    load_global_config()

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

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        run_startup_migrations()
        {:ok, pid}

      error ->
        error
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Reads the [system] section from ~/.designator_inator/config.yaml and applies
  # settings as application env so they override the compiled-in defaults.
  defp load_global_config do
    path = Path.expand("~/.designator_inator/config.yaml")

    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, %{"system" => system}} when is_map(system) ->
            apply_system_config(system)

          _ ->
            :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not read global config at #{path}: #{inspect(reason)}")
        :ok
    end
  end

  defp apply_system_config(system) do
    if dir = Map.get(system, "models_dir") do
      Application.put_env(:designator_inator, :models_dir, Path.expand(dir))
    end

    case Map.get(system, "vram_budget_mb") do
      mb when is_integer(mb) -> Application.put_env(:designator_inator, :vram_budget_mb, mb)
      _ -> :ok
    end

    if bin = Map.get(system, "llama_server") do
      Application.put_env(:designator_inator, :llama_server_bin, bin)
    end

    if dir = Map.get(system, "workspaces_dir") do
      Application.put_env(:designator_inator, :workspaces_dir, Path.expand(dir))
    end
  end

  # Runs pending Ecto migrations on startup so the app is always schema-current.
  # Idempotent — migrations that have already run are skipped.
  # Silently skips if the migrations path is not accessible (e.g. compiled escript).
  defp run_startup_migrations do
    priv_path = :code.priv_dir(:designator_inator)
    migrations_path = Path.join(priv_path, "repo/migrations")

    if File.dir?(migrations_path) do
      Ecto.Migrator.run(DesignatorInator.Memory.Repo, migrations_path, :up, all: true)
    end
  rescue
    e -> Logger.warning("Auto-migration failed: #{inspect(e)}")
  end
end
