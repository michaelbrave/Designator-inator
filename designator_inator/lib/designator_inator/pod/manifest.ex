defmodule DesignatorInator.Pod.Manifest do
  @moduledoc """
  Parses and validates a pod's `manifest.yaml`.

  ## Data flow (HTDP step 1)

      file path (String.t())
           │
           ▼
      raw YAML (map with string keys)
           │
           ▼  parse/1
      PodManifest.t()   or   {:error, [String.t()]}  (validation errors)

  ## Validation rules

  Required fields that cause `{:error, errors}` if missing:
  - `name` — must be a non-empty string, snake_case recommended
  - `version` — must be a non-empty string
  - `description` — must be a non-empty string
  - `exposed_tools` — must be a non-empty list with at least one tool

  Optional fields have defaults (see `PodManifest` struct defaults).

  Hardware requirements check (`check_hardware/1`) is a separate step so the
  caller can decide whether to abort or warn.

  ## Examples

  Given a valid `manifest.yaml`:

      iex> DesignatorInator.Pod.Manifest.load("./my-pod/manifest.yaml")
      {:ok, %DesignatorInator.Types.PodManifest{name: "code-reviewer", ...}}

  Given an invalid manifest:

      iex> DesignatorInator.Pod.Manifest.load("./bad-pod/manifest.yaml")
      {:error, ["name is required", "exposed_tools must not be empty"]}
  """

  alias DesignatorInator.Types.{PodManifest, ResourceRequirements, ModelPreference, ToolDefinition}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Reads and parses `path` as a pod manifest.

  Returns `{:ok, manifest}` on success or `{:error, reason}` on any failure
  (file not found, bad YAML, validation errors).

  ## Examples

      iex> DesignatorInator.Pod.Manifest.load("/pods/assistant/manifest.yaml")
      {:ok, %DesignatorInator.Types.PodManifest{name: "assistant", version: "1.0.0", ...}}

      iex> DesignatorInator.Pod.Manifest.load("/pods/bad/manifest.yaml")
      {:error, ["name is required"]}

      iex> DesignatorInator.Pod.Manifest.load("/nonexistent/manifest.yaml")
      {:error, :enoent}
  """
  @spec load(Path.t()) :: {:ok, PodManifest.t()} | {:error, term()}
  def load(path) do
    # Template (HTDP step 4):
    # 1. File.read(path) — return {:error, :enoent} etc. on failure
    # 2. YamlElixir.read_from_string(content) — return {:error, {:yaml_parse, reason}} on failure
    # 3. Call parse(raw_map)
    raise "not implemented"
  end

  @doc """
  Parses a raw YAML map (with string keys) into a `PodManifest` struct.

  Separate from `load/1` so it can be tested without the filesystem.

  ## Examples

      iex> DesignatorInator.Pod.Manifest.parse(%{
      ...>   "name" => "assistant",
      ...>   "version" => "1.0.0",
      ...>   "description" => "A helpful assistant",
      ...>   "exposed_tools" => [%{"name" => "chat", "description" => "Chat with the assistant", "parameters" => %{}}]
      ...> })
      {:ok, %DesignatorInator.Types.PodManifest{name: "assistant", version: "1.0.0", ...}}

      iex> DesignatorInator.Pod.Manifest.parse(%{"version" => "1.0.0"})
      {:error, ["name is required", "description is required", "exposed_tools must not be empty"]}
  """
  @spec parse(map()) :: {:ok, PodManifest.t()} | {:error, [String.t()]}
  def parse(raw) when is_map(raw) do
    # Template (HTDP step 4):
    # 1. Collect all validation errors by calling validate_required/2 for each required field
    # 2. If errors non-empty: return {:error, errors}
    # 3. Parse each sub-section:
    #    - parse_requires(raw["requires"])   → ResourceRequirements.t()
    #    - parse_model(raw["model"])         → ModelPreference.t()
    #    - parse_tools(raw["exposed_tools"]) → [ToolDefinition.t()]
    # 4. Build %PodManifest{} struct and return {:ok, manifest}
    raise "not implemented"
  end

  @doc """
  Checks that the current system meets the pod's hardware requirements.

  Returns `:ok` if requirements are satisfied, `{:error, reason}` otherwise.
  This is a best-effort check — actual VRAM/RAM availability is verified by
  `ModelManager` when the model is loaded.

  ## Examples

      iex> DesignatorInator.Pod.Manifest.check_hardware(%PodManifest{
      ...>   requires: %ResourceRequirements{min_ram_mb: 8192, gpu: :optional}
      ...> })
      :ok

      iex> DesignatorInator.Pod.Manifest.check_hardware(%PodManifest{
      ...>   requires: %ResourceRequirements{min_ram_mb: 65536, gpu: :required}
      ...> })
      {:error, "Insufficient RAM: need 65536 MB, have ~8192 MB"}
  """
  @spec check_hardware(PodManifest.t()) :: :ok | {:error, String.t()}
  def check_hardware(%PodManifest{} = manifest) do
    # Template (HTDP step 4):
    # 1. Read available RAM via :memsup.get_memory_data() or parse /proc/meminfo
    # 2. If manifest.requires.min_ram_mb > available_ram_mb:
    #    return {:error, "Insufficient RAM: need #{req} MB, have ~#{avail} MB"}
    # 3. If manifest.requires.gpu == :required and no GPU detected:
    #    return {:error, "GPU required but none detected"}
    # 4. Return :ok
    raise "not implemented"
  end

  # ── Private parsers ──────────────────────────────────────────────────────────

  @doc false
  @spec parse_requires(map() | nil) :: ResourceRequirements.t()
  def parse_requires(nil), do: %ResourceRequirements{}

  def parse_requires(raw) when is_map(raw) do
    # Template:
    # Build %ResourceRequirements{} from raw map, applying defaults for missing fields
    # Parse gpu: "required" | "optional" | "none" string → atom
    raise "not implemented"
  end

  @doc false
  @spec parse_model(map() | nil) :: ModelPreference.t()
  def parse_model(nil), do: %ModelPreference{}

  def parse_model(raw) when is_map(raw) do
    # Template:
    # Build %ModelPreference{} from raw map
    # Parse fallback_mode: "auto" | "manual" | "disabled" string → atom
    raise "not implemented"
  end

  @doc false
  @spec parse_tools([map()]) :: [ToolDefinition.t()]
  def parse_tools(tools) when is_list(tools) do
    # Template:
    # Map each map to a %ToolDefinition{}, parsing parameters sub-map
    raise "not implemented"
  end
end
