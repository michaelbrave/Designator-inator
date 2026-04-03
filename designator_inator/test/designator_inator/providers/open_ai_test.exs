defmodule DesignatorInator.Providers.OpenAITest do
  use ExUnit.Case, async: false

  alias DesignatorInator.Providers.OpenAI
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
      System.delete_env("OPENAI_API_KEY")
    end)

    :ok
  end

  describe "complete/2" do
    test "posts OpenAI-format messages and extracts the completion text" do
      System.put_env("OPENAI_API_KEY", "sk-openai-test")

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
               OpenAI.complete(
                 [Fixtures.user_message("What is 2+2?")],
                 model: "gpt-4o-mini",
                 base_url: "http://localhost:1234/v1",
                 max_tokens: 32,
                 temperature: 0.1
               )

      assert call = Agent.get(FakeReq, & &1.last_post)
      assert Keyword.get(call, :url) == "http://localhost:1234/v1"
      assert body = Keyword.get(call, :json)
      assert headers = Keyword.get(call, :headers)

      assert body["model"] == "gpt-4o-mini"
      assert body["messages"] == [%{"role" => "user", "content" => "What is 2+2?"}]
      assert body["max_tokens"] == 32
      assert body["temperature"] == 0.1
      assert body["stream"] == false
      assert Enum.any?(headers, fn {k, v} -> k == "authorization" and String.starts_with?(v, "Bearer ") end)
      assert {"content-type", "application/json"} in headers
    end

    test "returns rate_limited on HTTP 429" do
      System.put_env("OPENAI_API_KEY", "sk-openai-test")

      Agent.update(FakeReq, fn state -> %{state | post: [{:ok, %{status: 429}}]} end)

      assert {:error, :rate_limited} =
               OpenAI.complete([Fixtures.user_message("Hello")], model: "gpt-4o-mini")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:designator_inator, key)
  defp restore_env(key, value), do: Application.put_env(:designator_inator, key, value)
end
