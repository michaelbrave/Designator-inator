defmodule DesignatorInator.Providers.OpenRouterTest do
  use ExUnit.Case, async: false

  alias DesignatorInator.Providers.OpenRouter
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
      System.delete_env("OPENROUTER_API_KEY")
    end)

    :ok
  end

  describe "complete/2" do
    test "strips openrouter/ prefix and posts to OpenRouter API" do
      System.put_env("OPENROUTER_API_KEY", "sk-or-test")

      Agent.update(FakeReq, fn state ->
        %{
          state
          | post: [
              {:ok,
               %{
                 status: 200,
                 body: %{"choices" => [%{"message" => %{"content" => "4"}}]}
               }}
            ]
        }
      end)

      assert {:ok, "4"} =
               OpenRouter.complete(
                 [Fixtures.user_message("What is 2+2?")],
                 model: "openrouter/meta-llama/llama-3.1-8b-instruct",
                 max_tokens: 32,
                 temperature: 0.1
               )

      assert call = Agent.get(FakeReq, & &1.last_post)
      assert Keyword.get(call, :url) == "https://openrouter.ai/api/v1/chat/completions"
      assert body = Keyword.get(call, :json)
      assert headers = Keyword.get(call, :headers)

      # prefix stripped — only the bare model ID goes to OpenRouter
      assert body["model"] == "meta-llama/llama-3.1-8b-instruct"
      assert body["messages"] == [%{"role" => "user", "content" => "What is 2+2?"}]
      assert body["max_tokens"] == 32
      assert body["temperature"] == 0.1
      assert body["stream"] == false
      assert Enum.any?(headers, fn {k, v} -> k == "authorization" and String.starts_with?(v, "Bearer ") end)
      assert {"content-type", "application/json"} in headers
    end

    test "works with model ID that has no openrouter/ prefix" do
      System.put_env("OPENROUTER_API_KEY", "sk-or-test")

      Agent.update(FakeReq, fn state ->
        %{state | post: [{:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "hi"}}]}}}]}
      end)

      assert {:ok, "hi"} =
               OpenRouter.complete(
                 [Fixtures.user_message("Hello")],
                 model: "mistralai/mistral-7b-instruct"
               )

      assert call = Agent.get(FakeReq, & &1.last_post)
      assert Keyword.get(call, :json)["model"] == "mistralai/mistral-7b-instruct"
    end

    test "returns rate_limited on HTTP 429" do
      System.put_env("OPENROUTER_API_KEY", "sk-or-test")

      Agent.update(FakeReq, fn state -> %{state | post: [{:ok, %{status: 429}}]} end)

      assert {:error, :rate_limited} =
               OpenRouter.complete(
                 [Fixtures.user_message("Hello")],
                 model: "openrouter/meta-llama/llama-3.1-8b-instruct"
               )
    end

    test "returns no_api_key when env var is not set" do
      System.delete_env("OPENROUTER_API_KEY")

      assert {:error, :no_api_key} =
               OpenRouter.complete(
                 [Fixtures.user_message("Hello")],
                 model: "openrouter/meta-llama/llama-3.1-8b-instruct"
               )
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:designator_inator, key)
  defp restore_env(key, value), do: Application.put_env(:designator_inator, key, value)
end
