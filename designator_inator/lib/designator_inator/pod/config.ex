defmodule DesignatorInator.Pod.Config do
  @moduledoc """
  Parses a pod's `config.yaml` and the global `~/.designator_inator/config.yaml`.

  ## Data definitions (HTDP step 1)

  Pod config controls runtime inference behavior and overrides global defaults.

      %DesignatorInator.Pod.Config{
        model:         ModelPreference.t(),     # from config.yaml model: section
        temperature:   float(),                 # default 0.7
        max_tokens:    pos_integer(),           # default 4096
        max_history:   pos_integer(),           # conversation turns to keep in context
        tool_call_format: atom(),               # :llama3 | :chatml
        providers:     %{atom() => provider_config()}  # API key env var names
      }

  ## Configuration hierarchy

  Values are resolved in order (later wins):

  1. Hard-coded defaults (defined in `defaults/0`)
  2. Global config: `~/.designator_inator/config.yaml`
  3. Pod config: `<pod_path>/config.yaml`
  4. Environment variables: `DESIGNATOR_INATOR_*` prefixed vars

  API keys are NEVER stored in config files.  Config files only store the
  name of the environment variable to read the key from.

  ## Examples

      iex> DesignatorInator.Pod.Config.load("/pods/assistant/config.yaml")
      {:ok, %DesignatorInator.Pod.Config{temperature: 0.7, max_tokens: 4096, ...}}
  """

  alias DesignatorInator.Types.ModelPreference

  @type provider_config :: %{
          api_key_env: String.t()
        }

  @type t :: %__MODULE__{
          model: ModelPreference.t() | nil,
          temperature: float(),
          max_tokens: pos_integer(),
          max_history: pos_integer(),
          tool_call_format: atom(),
          providers: %{atom() => provider_config()}
        }

  defstruct [
    model: nil,
    temperature: 0.7,
    max_tokens: 4096,
    max_history: 20,
    tool_call_format: :llama3,
    providers: %{}
  ]

  @doc """
  Loads and merges pod config from `path` with global defaults.

  If the file does not exist, returns defaults without error — a pod is not
  required to have a `config.yaml`.

  ## Examples

      iex> DesignatorInator.Pod.Config.load("/pods/assistant/config.yaml")
      {:ok, %DesignatorInator.Pod.Config{temperature: 0.8, max_tokens: 8192, ...}}

      # Missing file is fine — returns defaults
      iex> DesignatorInator.Pod.Config.load("/pods/minimal/config.yaml")
      {:ok, %DesignatorInator.Pod.Config{temperature: 0.7, max_tokens: 4096, ...}}
  """
  @spec load(Path.t()) :: {:ok, t()}
  def load(path) do
    global_path = Path.expand("~/.designator_inator/config.yaml")

    {:ok, global_raw} = load_file_or_empty(global_path)
    {:ok, pod_raw} = load_file_or_empty(path)

    merged = deep_merge(global_raw, pod_raw)

    parse(merged)
  end

  @doc """
  Resolves the API key for a given provider.

  Resolution order:
  1. `opts[:api_key_env]` — from pod config providers section
  2. Global config providers section
  3. Conventional env var name (e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`)

  Returns `{:ok, key}` if found, `{:error, :no_api_key}` if not.

  ## Examples

      iex> DesignatorInator.Pod.Config.resolve_api_key(:anthropic, %Config{
      ...>   providers: %{anthropic: %{api_key_env: "MY_ANTHROPIC_KEY"}}
      ...> })
      {:ok, "sk-ant-..."}

      iex> DesignatorInator.Pod.Config.resolve_api_key(:anthropic, %Config{providers: %{}})
      {:error, :no_api_key}
  """
  @spec resolve_api_key(atom(), t()) :: {:ok, String.t()} | {:error, :no_api_key}
  def resolve_api_key(provider, %__MODULE__{} = config) do
    configured_env = get_in(config.providers, [provider, :api_key_env])

    configured_env
    |> List.wrap()
    |> Enum.concat([conventional_env_var(provider)])
    |> Enum.find_value(fn env_var ->
      case System.get_env(env_var) do
        value when is_binary(value) and value != "" -> {:ok, value}
        _ -> nil
      end
    end) || {:error, :no_api_key}
  end

  @doc false
  @spec parse(map()) :: {:ok, t()}
  def parse(raw) when is_map(raw) do
    model =
      case Map.get(raw, "model") do
        nil -> nil
        value -> parse_model(value)
      end

    inference = Map.get(raw, "inference", %{})
    memory = Map.get(raw, "memory", %{})
    providers = parse_providers(Map.get(raw, "providers", %{}))

    {:ok,
     %__MODULE__{
       model: model,
       temperature: fetch_float(inference, "temperature", 0.7),
       max_tokens: fetch_integer(inference, "max_tokens", 4096),
       max_history: fetch_integer(memory, "max_history_turns", 20),
       tool_call_format: parse_tool_call_format(Map.get(inference, "tool_call_format", "llama3")),
       providers: providers
     }}
  end

  defp load_file_or_empty(path) do
    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, raw} when is_map(raw) -> {:ok, raw}
          {:ok, _} -> {:error, {:yaml_parse, :not_a_map}}
          {:error, reason} -> {:error, {:yaml_parse, reason}}
        end

      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, left_val, right_val ->
      if is_map(left_val) and is_map(right_val) do
        deep_merge(left_val, right_val)
      else
        right_val
      end
    end)
  end

  defp deep_merge(_left, right), do: right

  defp parse_model(raw) when is_map(raw) do
    %ModelPreference{
      primary: fetch_string(raw, "primary", nil),
      fallback: fetch_string(raw, "fallback", nil),
      fallback_mode: parse_fallback_mode(Map.get(raw, "fallback_mode", "disabled")),
      recommended: fetch_string(raw, "recommended", nil),
      minimum: fetch_string(raw, "minimum", nil)
    }
  end

  defp parse_providers(raw) when is_map(raw) do
    Enum.reduce(raw, %{}, fn {provider, value}, acc ->
      provider_atom = normalize_provider(provider)
      env =
        case value do
          %{"api_key_env" => env} when is_binary(env) -> env
          %{api_key_env: env} when is_binary(env) -> env
          _ -> nil
        end

      Map.put(acc, provider_atom, %{api_key_env: env})
    end)
  end

  defp parse_providers(_), do: %{}

  defp fetch_integer(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> default
        end

      _ -> default
    end
  end

  defp fetch_float(map, key, default) do
    case Map.get(map, key, default) do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ -> default
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

  defp parse_fallback_mode("auto"), do: :auto
  defp parse_fallback_mode("manual"), do: :manual
  defp parse_fallback_mode("disabled"), do: :disabled
  defp parse_fallback_mode(_), do: :disabled

  defp parse_tool_call_format("chatml"), do: :chatml
  defp parse_tool_call_format("llama3"), do: :llama3
  defp parse_tool_call_format(_), do: :llama3

  defp conventional_env_var(:anthropic), do: "ANTHROPIC_API_KEY"
  defp conventional_env_var(:openai), do: "OPENAI_API_KEY"
  defp conventional_env_var(provider), do: "#{provider |> to_string() |> String.upcase()}_API_KEY"

  defp normalize_provider(provider) when is_atom(provider), do: provider
  defp normalize_provider(provider), do: provider |> to_string() |> String.to_existing_atom()
end
