defmodule DesignatorInator.ModelManagerTest do
  @moduledoc """
  Tests for `DesignatorInator.ModelManager`.
  """

  use ExUnit.Case, async: false

  alias DesignatorInator.ModelInventory
  alias DesignatorInator.ModelManager
  alias DesignatorInator.Types.{LoadedModel, Model, NodeInfo}

  defmodule State do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{local_result: {:ok, "local ok"}, cloud_result: {:ok, "cloud ok"}, calls: []} end,
        name: __MODULE__
      )
    end

    def set_local_result(result), do: Agent.update(__MODULE__, &Map.put(&1, :local_result, result))
    def set_cloud_result(result), do: Agent.update(__MODULE__, &Map.put(&1, :cloud_result, result))
    def record(call), do: Agent.update(__MODULE__, &Map.update!(&1, :calls, fn calls -> [call | calls] end))
    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def local_result, do: Agent.get(__MODULE__, & &1.local_result)
    def cloud_result, do: Agent.get(__MODULE__, & &1.cloud_result)
  end

  defmodule FakeLlamaProvider do
    def start_link(opts), do: Agent.start_link(fn -> opts end)

    def await_ready(pid), do: {:ok, Agent.get(pid, &Keyword.fetch!(&1, :port))}

    def stop(pid) do
      Agent.stop(pid)
      :ok
    catch
      :exit, _ -> :ok
    end

    def complete(messages, opts) do
      State.record({:local_complete, messages, opts})
      State.local_result()
    end
  end

  defmodule FakeOpenAIProvider do
    def complete(messages, opts) do
      State.record({:openai_complete, messages, opts})
      State.cloud_result()
    end
  end

  defmodule FakeAnthropicProvider do
    def complete(messages, opts) do
      State.record({:anthropic_complete, messages, opts})
      State.cloud_result()
    end
  end

  setup do
    start_supervised!(State)

    model_dir = Path.join(System.tmp_dir!(), "di_model_manager_#{System.unique_integer([:positive])}")
    File.mkdir_p!(model_dir)

    File.write!(Path.join(model_dir, "mistral-7b-instruct-v0.3.Q4_K_M.gguf"), "fake")
    File.write!(Path.join(model_dir, "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"), "fake")

    old_models_dir = Application.get_env(:designator_inator, :models_dir)
    old_budget = Application.get_env(:designator_inator, :vram_budget_mb)
    old_base_port = Application.get_env(:designator_inator, :llama_server_base_port)
    old_llama_provider = Application.get_env(:designator_inator, :model_manager_llama_provider)
    old_openai_provider = Application.get_env(:designator_inator, :model_manager_openai_provider)
    old_anthropic_provider = Application.get_env(:designator_inator, :model_manager_anthropic_provider)

    Application.put_env(:designator_inator, :models_dir, model_dir)
    Application.put_env(:designator_inator, :vram_budget_mb, 1_000)
    Application.put_env(:designator_inator, :llama_server_base_port, 9000)
    Application.put_env(:designator_inator, :model_manager_llama_provider, FakeLlamaProvider)
    Application.put_env(:designator_inator, :model_manager_openai_provider, FakeOpenAIProvider)
    Application.put_env(:designator_inator, :model_manager_anthropic_provider, FakeAnthropicProvider)

    start_supervised!(ModelInventory)
    start_supervised!(ModelManager)

    on_exit(fn ->
      restore_env(:models_dir, old_models_dir)
      restore_env(:vram_budget_mb, old_budget)
      restore_env(:llama_server_base_port, old_base_port)
      restore_env(:model_manager_llama_provider, old_llama_provider)
      restore_env(:model_manager_openai_provider, old_openai_provider)
      restore_env(:model_manager_anthropic_provider, old_anthropic_provider)
      File.rm_rf!(model_dir)
    end)

    :ok
  end

  describe "estimate_vram_mb/1" do
    test "estimates VRAM with quantization multiplier and overhead" do
      model = %Model{size_params_b: 1.0, quantization: :q4_k_m}
      assert ModelManager.estimate_vram_mb(model) == 549
    end
  end

  describe "lru_model/1" do
    test "returns nil for empty map" do
      assert ModelManager.lru_model(%{}) == nil
    end

    test "returns the oldest model name" do
      old = DateTime.add(DateTime.utc_now(), -60, :second)
      new = DateTime.utc_now()

      loaded = %{
        "new-model" => %LoadedModel{model: %Model{name: "new-model"}, last_used_at: new},
        "old-model" => %LoadedModel{model: %Model{name: "old-model"}, last_used_at: old}
      }

      assert ModelManager.lru_model(loaded) == "old-model"
    end
  end

  describe "load_model/1 and unload_model/1" do
    test "loads a model and lists it" do
      assert :ok = ModelManager.load_model("tinyllama-1.1b-chat-v1.0.Q4_K_M")

      assert [%LoadedModel{model: %Model{name: "tinyllama-1.1b-chat-v1.0.Q4_K_M"}, port_number: 9000}] =
               ModelManager.list_loaded()
    end

    test "returns error for missing model" do
      assert {:error, :model_not_found} = ModelManager.load_model("missing")
    end

    test "unload_model removes model from loaded list" do
      assert :ok = ModelManager.load_model("tinyllama-1.1b-chat-v1.0.Q4_K_M")
      assert :ok = ModelManager.unload_model("tinyllama-1.1b-chat-v1.0.Q4_K_M")
      assert [] = ModelManager.list_loaded()
    end
  end

  describe "complete/2 routing" do
    test "routes local models to llama provider and updates usage counters" do
      assert {:ok, "local ok"} =
               ModelManager.complete([
                 %{role: :user, content: "hello"}
               ], model: "tinyllama-1.1b-chat-v1.0.Q4_K_M")

      assert [{:local_complete, _messages, opts}] = State.calls()
      assert opts[:port] == 9000

      [loaded] = ModelManager.list_loaded()
      assert loaded.request_count == 1
    end

    test "routes gpt-* models directly to OpenAI provider" do
      assert {:ok, "cloud ok"} =
               ModelManager.complete([
                 %{role: :user, content: "hello"}
               ], model: "gpt-4o-mini")

      assert [{:openai_complete, _messages, opts}] = State.calls()
      assert opts[:model] == "gpt-4o-mini"
      assert [] = ModelManager.list_loaded()
    end

    test "falls back to cloud in :auto mode when local inference fails" do
      State.set_local_result({:error, :timeout})

      assert {:ok, "cloud ok"} =
               ModelManager.complete([
                 %{role: :user, content: "hello"}
               ],
                 model: "tinyllama-1.1b-chat-v1.0.Q4_K_M",
                 fallback: "claude-haiku",
                 fallback_mode: :auto
               )

      assert [
               {:local_complete, _local_messages, _opts},
               {:anthropic_complete, _fallback_messages, fallback_opts}
             ] = State.calls()

      assert fallback_opts[:model] == "claude-haiku"
    end
  end

  describe "node_info/0 and available_vram_mb/0" do
    test "returns current usage snapshot" do
      assert :ok = ModelManager.load_model("tinyllama-1.1b-chat-v1.0.Q4_K_M")

      info = ModelManager.node_info()
      assert %NodeInfo{} = info
      assert info.vram_total_mb == 1_000
      assert info.loaded_models == ["tinyllama-1.1b-chat-v1.0.Q4_K_M"]
      assert info.vram_used_mb > 0
      assert ModelManager.available_vram_mb() == info.vram_total_mb - info.vram_used_mb
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:designator_inator, key)
  defp restore_env(key, value), do: Application.put_env(:designator_inator, key, value)
end
