defmodule DesignatorInator.PodSupervisor do
  @moduledoc """
  DynamicSupervisor that manages the lifecycle of all agent pods.

  ## Responsibilities

  - Start pods on demand from a directory path
  - Provide fault isolation: one pod crashing does not affect others
  - Track running pods by name (via `DesignatorInator.PodRegistry`)
  - Gracefully stop pods (allow in-flight requests to complete)

  ## Process structure

  When a pod is started, the supervisor adds a child spec for `DesignatorInator.Pod`.
  Each pod registers itself in `DesignatorInator.PodRegistry` under its name on init.

      DesignatorInator.PodSupervisor (DynamicSupervisor)
          │
          ├── DesignatorInator.Pod (name: "assistant")
          ├── DesignatorInator.Pod (name: "code-reviewer")
          └── DesignatorInator.Pod (name: "orchestrator")

  ## Starting pods

  `start_pod/1` is the primary entry point:

  1. Load and validate `manifest.yaml` from the pod directory
  2. Check hardware requirements
  3. Spawn a `DesignatorInator.Pod` GenServer under this supervisor

  ## State checkpoint

  Pods persist conversation state to SQLite (via `DesignatorInator.Memory`).  When a
  pod crashes and restarts, it picks up where it left off using the existing
  session data.
  """

  use DynamicSupervisor
  require Logger

  alias DesignatorInator.Pod.Manifest
  alias DesignatorInator.Types.PodManifest

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Loads a pod from `path` and starts it under this supervisor.

  Steps:
  1. Load and validate `<path>/manifest.yaml`
  2. Check hardware requirements (warn but don't abort on :optional failures)
  3. Start `DesignatorInator.Pod` as a supervised child
  4. Return `{:ok, pid}` when the pod is successfully started (not necessarily ready)

  ## Examples

      iex> DesignatorInator.PodSupervisor.start_pod("./examples/assistant/")
      {:ok, #PID<0.456.0>}

      iex> DesignatorInator.PodSupervisor.start_pod("./nonexistent/")
      {:error, :enoent}

      iex> DesignatorInator.PodSupervisor.start_pod("./bad-pod/")
      {:error, ["name is required"]}

      # Pod already running
      iex> DesignatorInator.PodSupervisor.start_pod("./examples/assistant/")
      {:error, :already_started}
  """
  @spec start_pod(Path.t()) :: {:ok, pid()} | {:error, term()}
  def start_pod(path) do
    # Template (HTDP step 4):
    # 1. path = Path.expand(path)
    # 2. manifest_path = Path.join(path, "manifest.yaml")
    # 3. Manifest.load(manifest_path) → {:ok, manifest} | {:error, reason}
    # 4. Manifest.check_hardware(manifest) — log warning on failure, don't abort
    # 5. Check if pod already running: Pod.lookup(manifest.name) → {:ok, _} = already started
    # 6. child_spec = {DesignatorInator.Pod, path: path, manifest: manifest}
    # 7. DynamicSupervisor.start_child(__MODULE__, child_spec)
    raise "not implemented"
  end

  @doc """
  Gracefully stops a running pod.

  Sends a shutdown signal that allows in-flight requests to complete, then
  terminates the process.

  ## Examples

      iex> DesignatorInator.PodSupervisor.stop_pod("assistant")
      :ok

      iex> DesignatorInator.PodSupervisor.stop_pod("nonexistent")
      {:error, :not_found}
  """
  @spec stop_pod(String.t()) :: :ok | {:error, :not_found}
  def stop_pod(pod_name) do
    # Template (HTDP step 4):
    # 1. Pod.lookup(pod_name) → {:ok, pid} | {:error, :not_found}
    # 2. DynamicSupervisor.terminate_child(__MODULE__, pid)
    raise "not implemented"
  end

  @doc """
  Returns a list of all currently running pods with their status.

  ## Examples

      iex> DesignatorInator.PodSupervisor.list_pods()
      [
        %{name: "assistant", status: :idle,    pid: #PID<...>},
        %{name: "code-reviewer", status: :running, pid: #PID<...>}
      ]
  """
  @spec list_pods() :: [%{name: String.t(), status: atom(), pid: pid()}]
  def list_pods do
    # Template (HTDP step 4):
    # 1. Registry.select(DesignatorInator.PodRegistry, [{:"$1", [], [:"$1"]}]) → list of {name, pid, _}
    # 2. For each: call Pod.get_status(name) to get current status
    # 3. Return list of maps
    raise "not implemented"
  end

  # ── DynamicSupervisor callbacks ──────────────────────────────────────────────

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
