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

  alias DesignatorInator.Types.{ModelPreference, PodManifest, ResourceRequirements, ToolDefinition}

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
    with {:ok, content} <- File.read(path),
         {:ok, raw} <- YamlElixir.read_from_string(content),
         {:ok, manifest} <- parse(raw) do
      {:ok, manifest}
    else
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
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
    errors =
      []
      |> validate_required(raw, "name")
      |> validate_required(raw, "version")
      |> validate_required(raw, "description")
      |> validate_exposed_tools(raw)

    if errors == [] do
      manifest = %PodManifest{
        name: fetch_string!(raw, "name"),
        version: fetch_string!(raw, "version"),
        description: fetch_string!(raw, "description"),
        requires: parse_requires(Map.get(raw, "requires")),
        model: parse_model(Map.get(raw, "model")),
        exposed_tools: parse_tools(Map.get(raw, "exposed_tools", [])),
        internal_tools: parse_string_list(Map.get(raw, "internal_tools", [])),
        isolation: parse_isolation(Map.get(raw, "isolation", "beam"))
      }

      {:ok, manifest}
    else
      {:error, Enum.reverse(errors)}
    end
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
    available_ram_mb = available_ram_mb()

    cond do
      manifest.requires.min_ram_mb > available_ram_mb ->
        {:error, "Insufficient RAM: need #{manifest.requires.min_ram_mb} MB, have ~#{available_ram_mb} MB"}

      manifest.requires.gpu == :required and not gpu_present?() ->
        {:error, "GPU required but none detected"}

      true ->
        :ok
    end
  end

  # ── Private parsers ──────────────────────────────────────────────────────────

  @doc false
  @spec parse_requires(map() | nil) :: ResourceRequirements.t()
  def parse_requires(nil), do: %ResourceRequirements{}

  def parse_requires(raw) when is_map(raw) do
    %ResourceRequirements{
      min_ram_mb: fetch_integer(raw, "min_ram_mb", 0),
      min_context: fetch_integer(raw, "min_context", 2048),
      gpu: parse_gpu(Map.get(raw, "gpu", "optional"))
    }
  end

  @doc false
  @spec parse_model(map() | nil) :: ModelPreference.t()
  def parse_model(nil), do: %ModelPreference{}

  def parse_model(raw) when is_map(raw) do
    %ModelPreference{
      primary: fetch_string(raw, "primary", nil),
      fallback: fetch_string(raw, "fallback", nil),
      fallback_mode: parse_fallback_mode(Map.get(raw, "fallback_mode", "disabled")),
      recommended: fetch_string(raw, "recommended", nil),
      minimum: fetch_string(raw, "minimum", nil)
    }
  end

  @doc false
  @spec parse_tools([map()]) :: [ToolDefinition.t()]
  def parse_tools(tools) when is_list(tools) do
    Enum.map(tools, fn tool ->
      %ToolDefinition{
        name: fetch_string!(tool, "name"),
        description: fetch_string!(tool, "description"),
        parameters: parse_parameters(Map.get(tool, "parameters", %{}))
      }
    end)
  end

  defp validate_required(errors, raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: ["#{key} is required" | errors], else: errors

      _ ->
        ["#{key} is required" | errors]
    end
  end

  defp validate_exposed_tools(errors, raw) do
    case Map.get(raw, "exposed_tools") do
      list when is_list(list) and list != [] -> errors
      _ -> ["exposed_tools must not be empty" | errors]
    end
  end

  defp fetch_string!(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      other -> raise ArgumentError, "expected #{key} to be a string, got #{inspect(other)}"
    end
  end

  defp fetch_string(map, key, default) do
    case Map.get(map, key, default) do
      nil -> nil
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      other -> to_string(other)
    end
  end

  defp fetch_integer(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> default
    end
  end

  defp parse_string_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parse_string_list(_), do: []

  defp parse_parameters(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      schema =
        value
        |> normalize_keys()
        |> Map.put_new(:required, false)
        |> Map.update(:type, :string, &normalize_type/1)
        |> Map.update(:description, nil, &normalize_optional_string/1)
        |> Map.update(:enum, nil, &parse_enum/1)

      Map.put(acc, to_string(key), schema)
    end)
  end

  defp parse_parameters(_), do: %{}

  defp normalize_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {normalize_key(k), v} end)
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key), do: String.to_atom(to_string(key))

  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type(type), do: String.to_atom(to_string(type))

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp parse_enum(nil), do: nil
  defp parse_enum(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parse_enum(value), do: [to_string(value)]

  defp parse_gpu("required"), do: :required
  defp parse_gpu("none"), do: :none
  defp parse_gpu(_), do: :optional

  defp parse_fallback_mode("auto"), do: :auto
  defp parse_fallback_mode("manual"), do: :manual
  defp parse_fallback_mode("disabled"), do: :disabled
  defp parse_fallback_mode(_), do: :disabled

  defp parse_isolation("container"), do: :container
  defp parse_isolation(_), do: :beam

  defp available_ram_mb do
    if function_exported?(:memsup, :get_system_memory_data, 0) do
      case apply(:memsup, :get_system_memory_data, []) do
        {:ok, data} ->
          case Keyword.get(data, :total_memory) || Keyword.get(data, :memory_total) do
            bytes when is_integer(bytes) and bytes > 0 -> div(bytes, 1024 * 1024)
            _ -> 8_192
          end

        _ ->
          8_192
      end
    else
      8_192
    end
  end

  defp gpu_present? do
    case System.get_env("CUDA_VISIBLE_DEVICES") do
      nil -> false
      "" -> false
      "-1" -> false
      _ -> true
    end
  end
end
