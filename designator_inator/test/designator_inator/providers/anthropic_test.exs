defmodule DesignatorInator.Providers.AnthropicTest do
  use ExUnit.Case, async: false

  alias DesignatorInator.Providers.Anthropic
  alias DesignatorInator.Test.Fixtures

  defmodule FakeReq do
    def post(opts) do
      Agent.get_and_update(__MODULE__, fn %{post: [response | rest]} = state ->
        {response, %{state | post: rest, last_post: opts}}
      end)
    end
  end

  setup do
    start_supervised!(%{
      id: FakeReq,
      start: {Agent, :start_link, [fn -> %{post: [], last_post: nil} end, [name: FakeReq]]}
    })

    old_http_client = Application.get_env(:designator_inator, :http_client)
    Application.put_env(:designator_inator, :http_client, FakeReq)

    on_exit(fn ->
      restore_env(:http_client, old_http_client)
      System.delete_env("ANTHROPIC_API_KEY")
    end)

    :ok
  end

  describe "model_id/1" do
    test "maps short names to current API model IDs" do
      assert Anthropic.model_id("claude-opus") == "claude-opus-4-5"
      assert Anthropic.model_id("claude-sonnet") == "claude-sonnet-4-5"
      assert Anthropic.model_id("claude-haiku") == "claude-haiku-4-5-20251001"
      assert Anthropic.model_id("claude-opus-4-5") == "claude-opus-4-5"
    end
  end

  describe "messages_to_anthropic/1" do
    test "filters system messages and converts tool results and tool uses" do
      messages = [
        Fixtures.system_message("ignored"),
        Fixtures.user_message("List files"),
        Fixtures.assistant_message_with_tool_call(),
        Fixtures.tool_message("notes.md", "call_001")
      ]

      assert [
               %{"role" => "user", "content" => "List files"},
               %{"role" => "assistant", "content" => [%{"type" => "tool_use", "id" => "call_001", "name" => "workspace", "input" => %{"action" => "list"}}]},
               %{"role" => "user", "content" => [%{"type" => "tool_result", "tool_use_id" => "call_001", "content" => "notes.md"}]}
             ] = Anthropic.messages_to_anthropic(messages)
    end
  end

  describe "complete/2" do
    test "posts Anthropic-format messages and extracts the completion text" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-test")

      Agent.update(FakeReq, fn state ->
        %{
          state
          | post: [
              {:ok,
               %{
                 status: 200,
                 body: %{"content" => [%{"type" => "text", "text" => "Paris"}]}
               }}
            ]
        }
      end)

      assert {:ok, "Paris"} =
               Anthropic.complete(
                 [Fixtures.system_message("You are helpful."), Fixtures.user_message("What is the capital of France?")],
                 model: "claude-sonnet",
                 max_tokens: 64,
                 temperature: 0.2
               )

      assert call = Agent.get(FakeReq, & &1.last_post)
      assert Keyword.get(call, :url) == "https://api.anthropic.com/v1/messages"
      assert body = Keyword.get(call, :json)
      assert headers = Keyword.get(call, :headers)
      assert Keyword.get(call, :receive_timeout) > 0

      assert body["model"] == "claude-sonnet-4-5"
      assert body["system"] == "You are helpful."
      assert body["max_tokens"] == 64
      assert body["temperature"] == 0.2
      assert body["messages"] == [%{"role" => "user", "content" => "What is the capital of France?"}]
      assert Enum.any?(headers, fn {k, _v} -> k == "x-api-key" end)
      assert Enum.any?(headers, fn {k, v} -> k == "x-api-key" and String.starts_with?(v, "sk-ant-") end)
      assert {"anthropic-version", "2023-06-01"} in headers
    end

    test "returns rate_limited on HTTP 429" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-test")

      Agent.update(FakeReq, fn state -> %{state | post: [{:ok, %{status: 429}}]} end)

      assert {:error, :rate_limited} =
               Anthropic.complete([Fixtures.user_message("Hello")], model: "claude-sonnet")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:designator_inator, key)
  defp restore_env(key, value), do: Application.put_env(:designator_inator, key, value)
end
