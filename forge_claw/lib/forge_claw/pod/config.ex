defmodule ForgeClaw.Pod.Config do
  @moduledoc """
  Parses a pod's `config.yaml` and the global `~/.forgeclaw/config.yaml`.

  ## Data definitions (HTDP step 1)

  Pod config controls runtime inference behavior and overrides global defaults.

      %ForgeClaw.Pod.Config{
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
  2. Global config: `~/.forgeclaw/config.yaml`
  3. Pod config: `<pod_path>/config.yaml`
  4. Environment variables: `FORGECLAW_*` prefixed vars

  API keys are NEVER stored in config files.  Config files only store the
  name of the environment variable to read the key from.

  ## Examples

      iex> ForgeClaw.Pod.Config.load("/pods/assistant/config.yaml")
      {:ok, %ForgeClaw.Pod.Config{temperature: 0.7, max_tokens: 4096, ...}}
  """

  alias ForgeClaw.Types.ModelPreference

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

      iex> ForgeClaw.Pod.Config.load("/pods/assistant/config.yaml")
      {:ok, %ForgeClaw.Pod.Config{temperature: 0.8, max_tokens: 8192, ...}}

      # Missing file is fine — returns defaults
      iex> ForgeClaw.Pod.Config.load("/pods/minimal/config.yaml")
      {:ok, %ForgeClaw.Pod.Config{temperature: 0.7, max_tokens: 4096, ...}}
  """
  @spec load(Path.t()) :: {:ok, t()}
  def load(path) do
    # Template (HTDP step 4):
    # 1. Load global config from ~/.forgeclaw/config.yaml via load_file/1 (defaults to %{} if missing)
    # 2. Load pod config from path via load_file/1 (defaults to %{} if missing)
    # 3. Deep-merge: global_raw |> Map.merge(pod_raw)
    # 4. Parse merged map into %Config{} via parse/1
    raise "not implemented"
  end

  @doc """
  Resolves the API key for a given provider.

  Resolution order:
  1. `opts[:api_key_env]` — from pod config providers section
  2. Global config providers section
  3. Conventional env var name (e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`)

  Returns `{:ok, key}` if found, `{:error, :no_api_key}` if not.

  ## Examples

      iex> ForgeClaw.Pod.Config.resolve_api_key(:anthropic, %Config{
      ...>   providers: %{anthropic: %{api_key_env: "MY_ANTHROPIC_KEY"}}
      ...> })
      {:ok, "sk-ant-..."}

      iex> ForgeClaw.Pod.Config.resolve_api_key(:anthropic, %Config{providers: %{}})
      {:error, :no_api_key}
  """
  @spec resolve_api_key(atom(), t()) :: {:ok, String.t()} | {:error, :no_api_key}
  def resolve_api_key(provider, %__MODULE__{} = config) do
    # Template (HTDP step 4):
    # 1. Check config.providers[provider][:api_key_env] → System.get_env(env_var_name)
    # 2. Fall back to conventional env var name:
    #    :anthropic → "ANTHROPIC_API_KEY"
    #    :openai    → "OPENAI_API_KEY"
    # 3. If env var found and non-empty: {:ok, value}
    # 4. Otherwise: {:error, :no_api_key}
    raise "not implemented"
  end

  @doc false
  @spec parse(map()) :: {:ok, t()}
  def parse(raw) when is_map(raw) do
    # Template: Build %Config{} from raw map, applying defaults for missing fields
    raise "not implemented"
  end
end
