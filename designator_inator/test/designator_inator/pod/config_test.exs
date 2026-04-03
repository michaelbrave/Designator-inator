defmodule DesignatorInator.Pod.ConfigTest do
  use ExUnit.Case, async: false

  alias DesignatorInator.Pod.Config
  alias DesignatorInator.Types.ModelPreference

  describe "parse/1" do
    test "parses config with nested sections" do
      raw = %{
        "model" => %{
          "primary" => "mistral-7b-instruct-v0.3.Q4_K_M",
          "fallback_mode" => "disabled"
        },
        "inference" => %{
          "temperature" => 0.5,
          "max_tokens" => 1024,
          "tool_call_format" => "chatml"
        },
        "memory" => %{"max_history_turns" => 12},
        "providers" => %{
          "anthropic" => %{"api_key_env" => "MY_ANTHROPIC_KEY"}
        }
      }

      assert {:ok, %Config{} = config} = Config.parse(raw)
      assert %ModelPreference{primary: "mistral-7b-instruct-v0.3.Q4_K_M", fallback_mode: :disabled} = config.model
      assert config.temperature == 0.5
      assert config.max_tokens == 1024
      assert config.max_history == 12
      assert config.tool_call_format == :chatml
      assert config.providers[:anthropic].api_key_env == "MY_ANTHROPIC_KEY"
    end
  end

  describe "load/1" do
    test "loads pod config and applies defaults when file is missing" do
      assert {:ok, %Config{} = config} = Config.load("/nonexistent/config.yaml")
      assert config.temperature == 0.7
      assert config.max_tokens == 4096
      assert config.max_history == 20
      assert config.tool_call_format == :llama3
    end

    test "loads config.yaml from disk" do
      dir = Path.join(System.tmp_dir!(), "fc_config_test_#{:rand.uniform(99999)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "config.yaml"), """
      inference:
        temperature: 0.9
        max_tokens: 777
      """)

      assert {:ok, %Config{} = config} = Config.load(Path.join(dir, "config.yaml"))
      assert config.temperature == 0.9
      assert config.max_tokens == 777
    end
  end

  describe "resolve_api_key/2" do
    test "uses configured api_key_env first" do
      System.put_env("MY_ANTHROPIC_KEY", "sk-test")

      config = %Config{providers: %{anthropic: %{api_key_env: "MY_ANTHROPIC_KEY"}}}
      assert {:ok, "sk-test"} = Config.resolve_api_key(:anthropic, config)
    after
      System.delete_env("MY_ANTHROPIC_KEY")
    end

    test "falls back to conventional env var" do
      System.put_env("OPENAI_API_KEY", "sk-openai")

      config = %Config{providers: %{}}
      assert {:ok, "sk-openai"} = Config.resolve_api_key(:openai, config)
    after
      System.delete_env("OPENAI_API_KEY")
    end

    test "returns error when no key exists" do
      assert {:error, :no_api_key} = Config.resolve_api_key(:anthropic, %Config{providers: %{}})
    end
  end
end
