defmodule DesignatorInator.ModelManager do
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
  | `"claude-*"`      | `DesignatorInator.Providers.Anthropic`  |
  | `"gpt-*"`         | `DesignatorInator.Providers.OpenAI`     |
  | anything else     | `DesignatorInator.Providers.LlamaCpp`   |

  ## Concurrency model

  All state mutations go through the GenServer.  Inference calls are handled
  asynchronously via `Task` so one slow model call does not block others from
  loading new models.
  """

  use GenServer
  require Logger

  alias DesignatorInator.Types.{Model, LoadedModel, Message, NodeInfo}

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
      iex> DesignatorInator.ModelManager.complete(
      ...>   [%Message{role: :user, content: "Hello"}],
      ...>   model: "mistral-7b-instruct-v0.3.Q4_K_M"
      ...> )
      {:ok, "Hello! How can I help you today?"}

      # Cloud model
      iex> DesignatorInator.ModelManager.complete(
      ...>   [%Message{role: :user, content: "Hello"}],
      ...>   model: "claude-sonnet"
      ...> )
      {:ok, "Hello! I'm Claude. How can I help?"}

      # Local with auto-fallback to cloud
      iex> DesignatorInator.ModelManager.complete(
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

      iex> DesignatorInator.ModelManager.load_model("mistral-7b-instruct-v0.3.Q4_K_M")
      :ok

      iex> DesignatorInator.ModelManager.load_model("nonexistent-model")
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

      iex> DesignatorInator.ModelManager.unload_model("mistral-7b-instruct-v0.3.Q4_K_M")
      :ok
  """
  @spec unload_model(String.t()) :: :ok
  def unload_model(model_name) do
    GenServer.call(__MODULE__, {:unload_model, model_name})
  end

  @doc """
  Returns the list of currently loaded models.

  ## Examples

      iex> DesignatorInator.ModelManager.list_loaded()
      [%DesignatorInator.Types.LoadedModel{
        model: %DesignatorInator.Types.Model{name: "mistral-7b-instruct-v0.3.Q4_K_M"},
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

      iex> DesignatorInator.ModelManager.available_vram_mb()
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

      iex> DesignatorInator.ModelManager.node_info()
      %DesignatorInator.Types.NodeInfo{
        node: :"designator_inator@localhost",
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
  def provider_for("claude-" <> _), do: DesignatorInator.Providers.Anthropic
  def provider_for("gpt-" <> _), do: DesignatorInator.Providers.OpenAI
  def provider_for(_), do: DesignatorInator.Providers.LlamaCpp

  @doc false
  @spec estimate_vram_mb(Model.t()) :: non_neg_integer()
  def estimate_vram_mb(%Model{size_params_b: params_b, quantization: quant}) do
    bytes_per_param =
      case quant do
        :f32 -> 4.0
        :f16 -> 2.0
        :bf16 -> 2.0
        :q8_0 -> 1.0
        :q6_k -> 0.75
        :q5_k_m -> 0.625
        :q5_k_s -> 0.625
        :q4_0 -> 0.5
        :q4_k_m -> 0.5
        :q4_k_s -> 0.5
        :q3_k_l -> 0.375
        :q3_k_m -> 0.375
        :q3_k_s -> 0.375
        :q2_k -> 0.25
        {:unknown, _} -> 1.0
      end

    params_count = params_b * 1_000_000_000
    base_mb = params_count * bytes_per_param / (1024 * 1024)
    Float.ceil(base_mb * 1.15) |> trunc()

    # Was:
    # Template:
    # Rough formula: params * bytes_per_param + KV cache overhead
    # bytes_per_param depends on quantization:
    #   :f32 -> 4, :f16/:bf16 -> 2, :q8_0 -> 1, :q4_k_m/:q4_k_s -> 0.5,
    #   :q5_k_m -> 0.625, :q3_k_m -> 0.375, :q2_k -> 0.25
    # Add ~15% overhead for KV cache and runtime
    # Multiply params_b * 1e9 * bytes_per_param / (1024*1024) for MB
  end

  @doc false
  @spec lru_model(%{String.t() => LoadedModel.t()}) :: String.t() | nil
  def lru_model(loaded) when map_size(loaded) == 0, do: nil

  def lru_model(loaded) do
    loaded
    |> Enum.min_by(fn {_name, loaded_model} -> DateTime.to_unix(loaded_model.last_used_at, :microsecond) end)
    |> elem(0)

    # Was:
    # Template:
    # Find the model with the oldest last_used_at timestamp
    # Return its name (key in the map)
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    vram_budget_mb = Application.get_env(:designator_inator, :vram_budget_mb, 8192)
    next_port = Application.get_env(:designator_inator, :llama_server_base_port, 8080)

    state = %{
      loaded: %{},
      vram_budget_mb: vram_budget_mb,
      next_port: next_port,
      node_info: nil,
      consecutive_errors: 0
    }

    {:ok, refresh_node_info(state)}

    # Was:
    # Template:
    # 1. Read vram_budget_mb and llama_server_base_port from Application config
    # 2. Build initial NodeInfo
    # 3. Return {:ok, %{loaded: %{}, vram_budget_mb: ..., next_port: ..., node_info: ...}}
  end

  @impl GenServer
  def handle_call({:complete, messages, opts}, _from, state) do
    model_name = Keyword.get(opts, :model)

    cond do
      is_nil(model_name) ->
        {:reply, {:error, :missing_model}, state}

      provider_for(model_name) == DesignatorInator.Providers.LlamaCpp ->
        case ensure_loaded(model_name, state) do
          {:ok, loaded_model, loaded_state} ->
            completion_opts =
              opts
              |> Keyword.put(:port, loaded_model.port_number)
              |> Keyword.put_new(:model, model_name)

            case llama_provider().complete(messages, completion_opts) do
              {:ok, _text} = ok ->
                next_state =
                  loaded_state
                  |> mark_model_used(model_name)
                  |> Map.put(:consecutive_errors, 0)
                  |> refresh_node_info()

                {:reply, ok, next_state}

              {:error, reason} = local_error ->
                handle_local_failure(messages, opts, loaded_state, reason, local_error)
            end

          {:error, reason} = load_error ->
            handle_local_failure(messages, opts, state, reason, load_error)
        end

      true ->
        cloud_provider = provider_module(provider_for(model_name))
        result = cloud_provider.complete(messages, opts)

        next_state =
          case result do
            {:ok, _} -> Map.put(state, :consecutive_errors, 0)
            {:error, _} -> Map.update(state, :consecutive_errors, 1, &(&1 + 1))
          end

        {:reply, result, refresh_node_info(next_state)}
    end

    # Was:
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
  end

  @impl GenServer
  def handle_call({:load_model, model_name}, _from, state) do
    case do_load_model(model_name, state) do
      {:ok, new_state} -> {:reply, :ok, refresh_node_info(new_state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end

    # Was:
    # Template:
    # 1. Check if already loaded — return {:reply, :ok, state} if yes
    # 2. Look up model in ModelInventory
    # 3. Estimate VRAM needed via estimate_vram_mb/1
    # 4. Check budget; if full, evict LRU via evict_lru/1
    # 5. Start LlamaCpp GenServer, await_ready/1
    # 6. Add to state.loaded map
    # 7. Return {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:unload_model, model_name}, _from, state) do
    new_state =
      state
      |> do_unload_model(model_name)
      |> refresh_node_info()

    {:reply, :ok, new_state}

    # Was:
    # Template:
    # 1. Look up model in state.loaded
    # 2. If found: call LlamaCpp.stop(pid), remove from map
    # 3. Return {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:list_loaded, _from, state) do
    {:reply, Map.values(state.loaded), state}
  end

  @impl GenServer
  def handle_call(:available_vram_mb, _from, state) do
    used_mb = used_vram_mb(state.loaded)
    {:reply, max(state.vram_budget_mb - used_mb, 0), state}

    # Was:
    # Template:
    # Sum vram_mb across state.loaded values, subtract from budget
  end

  @impl GenServer
  def handle_call(:node_info, _from, state) do
    new_state = refresh_node_info(state)
    {:reply, new_state.node_info, new_state}

    # Was:
    # Template: rebuild NodeInfo from current state and return
  end

  defp ensure_loaded(model_name, state) do
    case Map.fetch(state.loaded, model_name) do
      {:ok, loaded_model} ->
        {:ok, loaded_model, state}

      :error ->
        case do_load_model(model_name, state) do
          {:ok, new_state} -> {:ok, Map.fetch!(new_state.loaded, model_name), new_state}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp do_load_model(model_name, state) do
    case Map.fetch(state.loaded, model_name) do
      {:ok, _loaded} ->
        {:ok, state}

      :error ->
        with {:ok, model} <- lookup_model(model_name),
             vram_needed = estimate_vram_mb(model),
             {:ok, capacity_state} <- ensure_capacity(vram_needed, state),
             {:ok, provider_pid} <- llama_provider().start_link(model: model, port: capacity_state.next_port),
             {:ok, port_number} <- llama_provider().await_ready(provider_pid) do
          loaded_model = %LoadedModel{
            model: model,
            server_pid: provider_pid,
            port_number: port_number,
            vram_mb: vram_needed,
            last_used_at: DateTime.utc_now(),
            request_count: 0
          }

          {:ok,
           %{capacity_state |
             loaded: Map.put(capacity_state.loaded, model_name, loaded_model),
             next_port: capacity_state.next_port + 1}}
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp lookup_model(model_name) do
    case DesignatorInator.ModelInventory.get(model_name) do
      {:ok, model} -> {:ok, model}
      {:error, :not_found} -> {:error, :model_not_found}
    end
  end

  defp ensure_capacity(required_mb, state) when required_mb > state.vram_budget_mb do
    {:error, :insufficient_vram}
  end

  defp ensure_capacity(required_mb, state) do
    if used_vram_mb(state.loaded) + required_mb <= state.vram_budget_mb do
      {:ok, state}
    else
      case lru_model(state.loaded) do
        nil ->
          {:error, :insufficient_vram}

        model_name ->
          state
          |> do_unload_model(model_name)
          |> ensure_capacity(required_mb)
      end
    end
  end

  defp do_unload_model(state, model_name) do
    case Map.pop(state.loaded, model_name) do
      {nil, _loaded} ->
        state

      {%LoadedModel{server_pid: pid}, remaining_loaded} ->
        _ = llama_provider().stop(pid)
        %{state | loaded: remaining_loaded}
    end
  end

  defp mark_model_used(state, model_name) do
    now = DateTime.utc_now()

    update_in(state.loaded, fn loaded ->
      Map.update(loaded, model_name, nil, fn loaded_model ->
        %{loaded_model | last_used_at: now, request_count: loaded_model.request_count + 1}
      end)
      |> Map.reject(fn {_name, value} -> is_nil(value) end)
    end)
  end

  defp used_vram_mb(loaded_map) do
    loaded_map
    |> Map.values()
    |> Enum.reduce(0, fn loaded_model, acc -> acc + loaded_model.vram_mb end)
  end

  defp refresh_node_info(state) do
    %{state | node_info: build_node_info(state)}
  end

  defp build_node_info(state) do
    %NodeInfo{
      node: Node.self(),
      hostname: hostname(),
      vram_total_mb: state.vram_budget_mb,
      vram_used_mb: used_vram_mb(state.loaded),
      ram_free_mb: 0,
      loaded_models: Map.keys(state.loaded),
      updated_at: DateTime.utc_now()
    }
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end

  defp handle_local_failure(messages, opts, state, reason, local_error) do
    fallback_mode = Keyword.get(opts, :fallback_mode, :disabled)
    fallback_model = Keyword.get(opts, :fallback)

    if fallback_mode == :auto and is_binary(fallback_model) do
      cloud_provider = provider_module(provider_for(fallback_model))
      fallback_opts = opts |> Keyword.put(:model, fallback_model)
      fallback_result = cloud_provider.complete(messages, fallback_opts)

      next_state =
        case fallback_result do
          {:ok, _} -> Map.put(state, :consecutive_errors, 0)
          {:error, _} -> Map.update(state, :consecutive_errors, 1, &(&1 + 1))
        end

      {:reply, fallback_result, refresh_node_info(next_state)}
    else
      next_state = Map.update(state, :consecutive_errors, 1, &(&1 + 1)) |> refresh_node_info()
      Logger.warning("Local completion failed for model #{inspect(Keyword.get(opts, :model))}: #{inspect(reason)}")
      {:reply, local_error, next_state}
    end
  end

  defp provider_module(DesignatorInator.Providers.LlamaCpp), do: llama_provider()
  defp provider_module(DesignatorInator.Providers.OpenAI), do: openai_provider()
  defp provider_module(DesignatorInator.Providers.Anthropic), do: anthropic_provider()

  defp llama_provider do
    Application.get_env(:designator_inator, :model_manager_llama_provider, DesignatorInator.Providers.LlamaCpp)
  end

  defp openai_provider do
    Application.get_env(:designator_inator, :model_manager_openai_provider, DesignatorInator.Providers.OpenAI)
  end

  defp anthropic_provider do
    Application.get_env(:designator_inator, :model_manager_anthropic_provider, DesignatorInator.Providers.Anthropic)
  end
end
