defmodule ForgeClaw.ModelManager do
  @moduledoc """
  Manages all inference backends: local llama-server instances and cloud providers.

  ## Responsibilities

  1. **VRAM/RAM budget** — tracks how much memory is in use and refuses to load
     new models when the budget would be exceeded.
  2. **LRU eviction** — when the budget is full and a new model is needed, evicts
     the least-recently-used loaded model.
  3. **Provider routing** — dispatches inference requests to the right backend
     based on the model name prefix.
  4. **Shared loading** — multiple pods requesting the same model share one
     `llama-server` instance rather than loading duplicate copies.
  5. **Fallback** — when local inference fails or a model requires cloud,
     delegates to the appropriate cloud provider.

  ## State (HTDP step 1)

      %{
        loaded: %{model_name => LoadedModel.t()},   # currently running servers
        vram_budget_mb: pos_integer(),               # from config
        llama_server_base_port: pos_integer(),       # next port to assign
        node_info: NodeInfo.t()                      # broadcast to swarm
      }

  ## Provider routing rules

  | Model name prefix | Provider module                  |
  |-------------------|----------------------------------|
  | `"claude-*"`      | `ForgeClaw.Providers.Anthropic`  |
  | `"gpt-*"`         | `ForgeClaw.Providers.OpenAI`     |
  | anything else     | `ForgeClaw.Providers.LlamaCpp`   |

  ## Concurrency model

  All state mutations go through the GenServer.  Inference calls are handled
  asynchronously via `Task` so one slow model call does not block others from
  loading new models.
  """

  use GenServer
  require Logger

  alias ForgeClaw.Types.{Model, LoadedModel, Message, NodeInfo}

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The primary entry point for all inference.  Sends `messages` to the model
  specified in `opts` and returns the full text response.

  This function handles provider routing, model loading (including downloading
  if the model is not present), and fallback logic transparently.

  ## Options

  - `:model` — `String.t()` (required) — model name or cloud model ID
  - `:fallback` — `String.t() | nil` — cloud model to use if local fails
  - `:fallback_mode` — `:auto | :manual | :disabled` (default `:disabled`)
  - `:temperature` — `float()` (default `0.7`)
  - `:max_tokens` — `pos_integer()` (default `4096`)
  - `:timeout_ms` — `pos_integer()` override

  ## Examples

      # Local model
      iex> ForgeClaw.ModelManager.complete(
      ...>   [%Message{role: :user, content: "Hello"}],
      ...>   model: "mistral-7b-instruct-v0.3.Q4_K_M"
      ...> )
      {:ok, "Hello! How can I help you today?"}

      # Cloud model
      iex> ForgeClaw.ModelManager.complete(
      ...>   [%Message{role: :user, content: "Hello"}],
      ...>   model: "claude-sonnet"
      ...> )
      {:ok, "Hello! I'm Claude. How can I help?"}

      # Local with auto-fallback to cloud
      iex> ForgeClaw.ModelManager.complete(
      ...>   [%Message{role: :user, content: "Hello"}],
      ...>   model: "mistral-7b",
      ...>   fallback: "claude-haiku",
      ...>   fallback_mode: :auto
      ...> )
      {:ok, "Hello!"}
  """
  @spec complete([Message.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts) do
    GenServer.call(__MODULE__, {:complete, messages, opts},
      Keyword.get(opts, :timeout_ms, 120_000) + 5_000)
  end

  @doc """
  Explicitly loads a model into memory, waiting until ready.

  Usually you do not need to call this directly — `complete/2` handles loading
  automatically.  Useful for pre-warming a model before the first request.

  ## Examples

      iex> ForgeClaw.ModelManager.load_model("mistral-7b-instruct-v0.3.Q4_K_M")
      :ok

      iex> ForgeClaw.ModelManager.load_model("nonexistent-model")
      {:error, :model_not_found}
  """
  @spec load_model(String.t()) :: :ok | {:error, term()}
  def load_model(model_name) do
    GenServer.call(__MODULE__, {:load_model, model_name}, 60_000)
  end

  @doc """
  Unloads a model, stopping its llama-server process and freeing VRAM.

  Returns `:ok` even if the model was not loaded.

  ## Examples

      iex> ForgeClaw.ModelManager.unload_model("mistral-7b-instruct-v0.3.Q4_K_M")
      :ok
  """
  @spec unload_model(String.t()) :: :ok
  def unload_model(model_name) do
    GenServer.call(__MODULE__, {:unload_model, model_name})
  end

  @doc """
  Returns the list of currently loaded models.

  ## Examples

      iex> ForgeClaw.ModelManager.list_loaded()
      [%ForgeClaw.Types.LoadedModel{
        model: %ForgeClaw.Types.Model{name: "mistral-7b-instruct-v0.3.Q4_K_M"},
        vram_mb: 4096,
        ...
      }]
  """
  @spec list_loaded() :: [LoadedModel.t()]
  def list_loaded do
    GenServer.call(__MODULE__, :list_loaded)
  end

  @doc """
  Returns available VRAM/RAM budget in MB (budget - currently used).

  ## Examples

      iex> ForgeClaw.ModelManager.available_vram_mb()
      4096
  """
  @spec available_vram_mb() :: non_neg_integer()
  def available_vram_mb do
    GenServer.call(__MODULE__, :available_vram_mb)
  end

  @doc """
  Returns the `NodeInfo` snapshot for this node — used by `SwarmRegistry` to
  broadcast resource availability to the cluster.

  ## Examples

      iex> ForgeClaw.ModelManager.node_info()
      %ForgeClaw.Types.NodeInfo{
        node: :"forgeclaw@localhost",
        vram_total_mb: 8192,
        vram_used_mb: 4096,
        loaded_models: ["mistral-7b-instruct-v0.3.Q4_K_M"]
      }
  """
  @spec node_info() :: NodeInfo.t()
  def node_info do
    GenServer.call(__MODULE__, :node_info)
  end

  # ── Private helpers (pure, testable independently) ───────────────────────────

  @doc false
  @spec provider_for(String.t()) :: module()
  def provider_for("claude-" <> _), do: ForgeClaw.Providers.Anthropic
  def provider_for("gpt-" <> _), do: ForgeClaw.Providers.OpenAI
  def provider_for(_), do: ForgeClaw.Providers.LlamaCpp

  @doc false
  @spec estimate_vram_mb(Model.t()) :: non_neg_integer()
  def estimate_vram_mb(%Model{size_params_b: params_b, quantization: quant}) do
    # Template:
    # Rough formula: params * bytes_per_param + KV cache overhead
    # bytes_per_param depends on quantization:
    #   :f32 -> 4, :f16/:bf16 -> 2, :q8_0 -> 1, :q4_k_m/:q4_k_s -> 0.5,
    #   :q5_k_m -> 0.625, :q3_k_m -> 0.375, :q2_k -> 0.25
    # Add ~15% overhead for KV cache and runtime
    # Multiply params_b * 1e9 * bytes_per_param / (1024*1024) for MB
    raise "not implemented"
  end

  @doc false
  @spec lru_model(%{String.t() => LoadedModel.t()}) :: String.t() | nil
  def lru_model(loaded) when map_size(loaded) == 0, do: nil

  def lru_model(loaded) do
    # Template:
    # Find the model with the oldest last_used_at timestamp
    # Return its name (key in the map)
    raise "not implemented"
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # Template:
    # 1. Read vram_budget_mb and llama_server_base_port from Application config
    # 2. Build initial NodeInfo
    # 3. Return {:ok, %{loaded: %{}, vram_budget_mb: ..., next_port: ..., node_info: ...}}
    raise "not implemented"
  end

  @impl GenServer
  def handle_call({:complete, messages, opts}, _from, state) do
    # Template:
    # 1. Determine provider: provider_for(opts[:model])
    # 2. If provider is LlamaCpp:
    #    a. Call ensure_loaded(model_name, state) → {:ok, loaded_model, new_state} | {:error, ...}
    #    b. On success: dispatch to LlamaCpp.complete/2 with the server's port
    #    c. On failure with fallback_mode :auto: route to cloud fallback
    # 3. If provider is cloud: call provider.complete(messages, opts) directly
    # 4. Update last_used_at for the loaded model
    # 5. Update consecutive_errors tracking (reset on success, increment on failure)
    # 6. Return {:reply, result, new_state}
    raise "not implemented"
  end

  @impl GenServer
  def handle_call({:load_model, model_name}, _from, state) do
    # Template:
    # 1. Check if already loaded — return {:reply, :ok, state} if yes
    # 2. Look up model in ModelInventory
    # 3. Estimate VRAM needed via estimate_vram_mb/1
    # 4. Check budget; if full, evict LRU via evict_lru/1
    # 5. Start LlamaCpp GenServer, await_ready/1
    # 6. Add to state.loaded map
    # 7. Return {:reply, :ok, new_state}
    raise "not implemented"
  end

  @impl GenServer
  def handle_call({:unload_model, model_name}, _from, state) do
    # Template:
    # 1. Look up model in state.loaded
    # 2. If found: call LlamaCpp.stop(pid), remove from map
    # 3. Return {:reply, :ok, new_state}
    raise "not implemented"
  end

  @impl GenServer
  def handle_call(:list_loaded, _from, state) do
    {:reply, Map.values(state.loaded), state}
  end

  @impl GenServer
  def handle_call(:available_vram_mb, _from, state) do
    # Template:
    # Sum vram_mb across state.loaded values, subtract from budget
    raise "not implemented"
  end

  @impl GenServer
  def handle_call(:node_info, _from, state) do
    # Template: rebuild NodeInfo from current state and return
    raise "not implemented"
  end
end
