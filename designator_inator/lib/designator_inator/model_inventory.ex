defmodule DesignatorInator.ModelInventory do
  @moduledoc """
  Scans a directory for GGUF model files and maintains an in-memory catalog.

  ## Data definitions (HTDP step 1)

  The inventory maps model names to `DesignatorInator.Types.Model` structs.
  See `DesignatorInator.Types.Model` for the full field definition.

  ## Responsibilities

  - Scan `Application.get_env(:designator_inator, :models_dir)` for `.gguf` files
    at startup.
  - Parse model metadata (parameter count, quantization) from the filename
    convention used by HuggingFace/Ollama: `<name>-<params>B-<variant>.<quant>.gguf`
  - Expose the catalog via `list/0` and `get/1`.
  - Future: watch the directory for new files without restarting.
  """

  use GenServer
  require Logger

  alias DesignatorInator.Types.Model

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts the inventory GenServer and runs an initial scan.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns all models found in the models directory.

  ## Examples

      iex> DesignatorInator.ModelInventory.list()
      {:ok, [%DesignatorInator.Types.Model{name: "mistral-7b-instruct-v0.3.Q4_K_M", ...}]}

      # When models directory is empty or doesn't exist
      iex> DesignatorInator.ModelInventory.list()
      {:ok, []}
  """
  @spec list() :: {:ok, [Model.t()]}
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Looks up a single model by name.

  Returns `{:error, :not_found}` if no model with that name exists.

  ## Examples

      iex> DesignatorInator.ModelInventory.get("mistral-7b-instruct-v0.3.Q4_K_M")
      {:ok, %DesignatorInator.Types.Model{name: "mistral-7b-instruct-v0.3.Q4_K_M", ...}}

      iex> DesignatorInator.ModelInventory.get("nonexistent-model")
      {:error, :not_found}
  """
  @spec get(String.t()) :: {:ok, Model.t()} | {:error, :not_found}
  def get(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @doc """
  Re-scans the models directory and updates the catalog.
  Useful after a model download completes.

  ## Examples

      iex> DesignatorInator.ModelInventory.rescan()
      {:ok, 3}  # number of models found
  """
  @spec rescan() :: {:ok, non_neg_integer()}
  def rescan do
    GenServer.call(__MODULE__, :rescan)
  end

  # ── Pure functions (testable without starting the GenServer) ─────────────────

  @doc """
  Scans `dir` for `.gguf` files and returns a list of parsed `Model` structs.

  Files that cannot be parsed are logged and skipped — they do not cause an error.

  ## Examples

      iex> DesignatorInator.ModelInventory.scan_directory("/path/with/ggufs")
      {:ok, [%DesignatorInator.Types.Model{...}, ...]}

      iex> DesignatorInator.ModelInventory.scan_directory("/nonexistent")
      {:error, :enoent}
  """
  @spec scan_directory(Path.t()) :: {:ok, [Model.t()]} | {:error, atom()}
  def scan_directory(dir) do
    with {:ok, filenames} <- File.ls(dir) do
      models =
        dir
        |> build_gguf_paths(filenames)
        |> Enum.flat_map(&parse_model_file/1)

      {:ok, models}
    end

    # Was:
    # Template (HTDP step 4):
    # 1. Check that `dir` exists and is readable — return {:error, reason} if not
    # 2. List all files matching *.gguf in `dir` (non-recursive for now)
    # 3. For each file:
    #    a. Call parse_gguf_filename/1 on the basename
    #    b. If {:ok, model}: fill in `path` and `size_bytes` from the filesystem
    #    c. If {:error, _}: log a warning and skip
    # 4. Return {:ok, list_of_models}
  end

  @doc """
  Parses a GGUF filename into a partial `Model` struct (no `path` or `size_bytes`).

  The filename convention is:
      <name>[-<params>B]-[<variant>.]<quant>.gguf

  Examples of valid filenames:
  - `mistral-7b-instruct-v0.3.Q4_K_M.gguf`   → params=7.0, quant=:q4_k_m
  - `codellama-13b-instruct.Q5_K_M.gguf`       → params=13.0, quant=:q5_k_m
  - `llama-3.1-8b-instruct.Q8_0.gguf`          → params=8.0, quant=:q8_0
  - `phi-3-mini-4k-instruct-fp16.gguf`          → quant=:f16

  Returns `{:error, :unrecognized_format}` only if the file doesn't end in
  `.gguf` at all.  Unknown quantization strings become `{:unknown, str}`.

  ## Examples

      iex> DesignatorInator.ModelInventory.parse_gguf_filename("mistral-7b-instruct-v0.3.Q4_K_M.gguf")
      {:ok, %DesignatorInator.Types.Model{
        name: "mistral-7b-instruct-v0.3.Q4_K_M",
        size_params_b: 7.0,
        quantization: :q4_k_m
      }}

      iex> DesignatorInator.ModelInventory.parse_gguf_filename("not-a-model.txt")
      {:error, :unrecognized_format}

      iex> DesignatorInator.ModelInventory.parse_gguf_filename("custom-model.NEWQUANT.gguf")
      {:ok, %DesignatorInator.Types.Model{
        name: "custom-model.NEWQUANT",
        size_params_b: 0.0,
        quantization: {:unknown, "NEWQUANT"}
      }}
  """
  @spec parse_gguf_filename(String.t()) :: {:ok, Model.t()} | {:error, :unrecognized_format}
  def parse_gguf_filename(filename) do
    if String.ends_with?(filename, ".gguf") do
      stem = Path.rootname(filename, ".gguf")
      quantization = extract_quantization(stem)
      size_params_b = extract_param_count(stem)

      {:ok,
       %Model{
         name: stem,
         path: "",
         size_params_b: size_params_b,
         quantization: quantization,
         context_length: 0,
         size_bytes: 0
       }}
    else
      {:error, :unrecognized_format}
    end

    # Was:
    # Template (HTDP step 4):
    # 1. Confirm the filename ends in ".gguf" — return {:error, :unrecognized_format} if not
    # 2. Strip the ".gguf" extension to get the stem
    # 3. Use a regex to extract the last dot-separated segment as the quantization string
    # 4. Map the quantization string to an atom using parse_quantization/1
    # 5. Use a regex to find a "<N>b" pattern in the remaining stem for params
    # 6. The full stem (minus extension) is the model name
    # 7. Return {:ok, %Model{name: ..., size_params_b: ..., quantization: ...}}
  end

  @doc """
  Converts a quantization string (e.g. `"Q4_K_M"`) to its atom representation.

  Unknown strings are wrapped in `{:unknown, str}` rather than raising.

  ## Examples

      iex> DesignatorInator.ModelInventory.parse_quantization("Q4_K_M")
      :q4_k_m

      iex> DesignatorInator.ModelInventory.parse_quantization("F16")
      :f16

      iex> DesignatorInator.ModelInventory.parse_quantization("NEWFORMAT")
      {:unknown, "NEWFORMAT"}
  """
  @spec parse_quantization(String.t()) :: Model.quantization()
  def parse_quantization(str) do
    case String.upcase(str) do
      "Q2_K" -> :q2_k
      "Q3_K_S" -> :q3_k_s
      "Q3_K_M" -> :q3_k_m
      "Q3_K_L" -> :q3_k_l
      "Q4_0" -> :q4_0
      "Q4_K_S" -> :q4_k_s
      "Q4_K_M" -> :q4_k_m
      "Q5_K_S" -> :q5_k_s
      "Q5_K_M" -> :q5_k_m
      "Q6_K" -> :q6_k
      "Q8_0" -> :q8_0
      "F16" -> :f16
      "FP16" -> :f16
      "F32" -> :f32
      "BF16" -> :bf16
      _ -> {:unknown, str}
    end

    # Was:
    # Template (HTDP step 4):
    # Map known uppercase quantization strings to their atom equivalents.
    # Fallback to {:unknown, str} for unrecognized values.
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    models_dir = Application.get_env(:designator_inator, :models_dir, Path.expand("~/.designator_inator/models"))

    case scan_directory(models_dir) do
      {:ok, models} ->
        Logger.info("ModelInventory loaded #{length(models)} model(s) from #{models_dir}")
        {:ok, %{models: models_by_name(models), models_dir: models_dir}}

      {:error, reason} ->
        Logger.warning("ModelInventory scan failed for #{models_dir}: #{inspect(reason)}")
        {:ok, %{models: %{}, models_dir: models_dir}}
    end

    # Was:
    # Template:
    # 1. Read models_dir from application config
    # 2. Call scan_directory/1 to build initial catalog
    # 3. Log how many models were found
    # 4. Return {:ok, %{models: map_of_name_to_model, models_dir: dir}}
  end

  @impl GenServer
  def handle_call(:list, _from, state) do
    {:reply, {:ok, Map.values(state.models)}, state}

    # Was:
    # Template:
    # Reply with {:ok, Map.values(state.models)}
  end

  @impl GenServer
  def handle_call({:get, name}, _from, state) do
    reply =
      case Map.fetch(state.models, name) do
        {:ok, model} -> {:ok, model}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}

    # Was:
    # Template:
    # Look up name in state.models, reply {:ok, model} or {:error, :not_found}
  end

  @impl GenServer
  def handle_call(:rescan, _from, state) do
    case scan_directory(state.models_dir) do
      {:ok, models} ->
        new_state = %{state | models: models_by_name(models)}
        {:reply, {:ok, length(models)}, new_state}

      {:error, reason} ->
        Logger.warning("ModelInventory rescan failed for #{state.models_dir}: #{inspect(reason)}")
        {:reply, {:ok, map_size(state.models)}, state}
    end

    # Was:
    # Template:
    # 1. Re-run scan_directory(state.models_dir)
    # 2. Rebuild the models map
    # 3. Return {:reply, {:ok, count}, new_state}
  end

  defp build_gguf_paths(dir, filenames) do
    Enum.filter(filenames, &String.ends_with?(&1, ".gguf"))
    |> Enum.map(&Path.join(dir, &1))
  end

  defp parse_model_file(path) do
    filename = Path.basename(path)

    case parse_gguf_filename(filename) do
      {:ok, model} ->
        case File.stat(path) do
          {:ok, %File.Stat{size: size, type: :regular}} ->
            [%{model | path: Path.expand(path), size_bytes: size}]

          {:ok, %File.Stat{type: type}} ->
            Logger.warning("Skipping non-regular GGUF path #{path}: #{inspect(type)}")
            []

          {:error, reason} ->
            Logger.warning("Skipping unreadable GGUF file #{path}: #{inspect(reason)}")
            []
        end

      {:error, :unrecognized_format} ->
        Logger.warning("Skipping unrecognized GGUF filename #{filename}")
        []
    end
  end

  defp extract_quantization(stem) do
    quantization_string =
      case Regex.run(~r/(?:\.|-)([A-Za-z0-9_]+)$/u, stem, capture: :all_but_first) do
        [suffix] -> suffix
        _ -> stem
      end

    parse_quantization(quantization_string)
  end

  defp extract_param_count(stem) do
    case Regex.run(~r/(?:^|-)(\d+(?:\.\d+)?)b(?:-|\.|$)/i, stem, capture: :all_but_first) do
      [param_count] ->
        case Float.parse(param_count) do
          {value, ""} -> value
          _ -> 0.0
        end

      _ ->
        0.0
    end
  end

  defp models_by_name(models) do
    Map.new(models, &{&1.name, &1})
  end
end
