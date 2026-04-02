defmodule DesignatorInator.Providers.LlamaCppTest do
  @moduledoc """
  Tests for `DesignatorInator.Providers.LlamaCpp`.
  """

  use ExUnit.Case, async: false

  alias DesignatorInator.Providers.LlamaCpp
  alias DesignatorInator.Test.Fixtures

  defmodule FakeReq do
    def get(_opts) do
      Agent.get_and_update(__MODULE__, fn %{get: [response | rest]} = state ->
        {response, %{state | get: rest}}
      end)
    end

    def post(_opts) do
      Agent.get_and_update(__MODULE__, fn %{post: [response | rest]} = state ->
        {response, %{state | post: rest}}
      end)
    end
  end

  setup do
    start_supervised!(%{
      id: FakeReq,
      start: {Agent, :start_link, [fn -> %{get: [], post: []} end, [name: FakeReq]]}
    })

    old_http_client = Application.get_env(:designator_inator, :http_client)
    old_kill_runner = Application.get_env(:designator_inator, :llama_kill_runner)

    Application.put_env(:designator_inator, :http_client, FakeReq)

    on_exit(fn ->
      restore_env(:http_client, old_http_client)
      restore_env(:llama_kill_runner, old_kill_runner)
    end)

    :ok
  end

  describe "messages_to_openai/1" do
    test "converts regular, tool-call, and tool-result messages" do
      messages = [
        Fixtures.system_message("You are precise."),
        Fixtures.user_message("List files"),
        Fixtures.assistant_message_with_tool_call(),
        Fixtures.tool_message("notes.md", "call_001")
      ]

      assert [
               %{"role" => "system", "content" => "You are precise."},
               %{"role" => "user", "content" => "List files"},
               %{
                 "role" => "assistant",
                 "content" => nil,
                 "tool_calls" => [
                   %{
                     "id" => "call_001",
                     "type" => "function",
                     "function" => %{
                       "name" => "workspace",
                       "arguments" => "{\"action\":\"list\"}"
                     }
                   }
                 ]
               },
               %{"role" => "tool", "content" => "notes.md", "tool_call_id" => "call_001"}
             ] = LlamaCpp.messages_to_openai(messages)
    end
  end

  describe "health_check/1" do
    test "returns :ok for HTTP 200" do
      Agent.update(FakeReq, &%{&1 | get: [{:ok, %{status: 200}}]})
      assert :ok = LlamaCpp.health_check(8080)
    end

    test "returns http error for non-200 responses" do
      Agent.update(FakeReq, &%{&1 | get: [{:ok, %{status: 503}}]})
      assert {:error, {:http_error, 503}} = LlamaCpp.health_check(8080)
    end
  end

  describe "complete/2" do
    test "posts OpenAI-format messages and extracts completion content" do
      Agent.update(FakeReq, fn state ->
        %{state | post: [{:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "4"}}]}}}]}
      end)

      assert {:ok, "4"} =
               LlamaCpp.complete(
                 [Fixtures.user_message("What is 2+2?")],
                 port: 8080,
                 temperature: 0.1,
                 max_tokens: 32
               )
    end

    test "returns timeout when the HTTP client times out" do
      Agent.update(FakeReq, fn state ->
        %{state | post: [{:error, %Req.TransportError{reason: :timeout}}]}
      end)

      assert {:error, :timeout} =
               LlamaCpp.complete([Fixtures.user_message("Hello")], port: 8080)
    end
  end

  describe "GenServer lifecycle" do
    test "await_ready/1 returns the port after a successful health check" do
      script_path = make_fake_llama_script()
      Agent.update(FakeReq, &%{&1 | get: [{:ok, %{status: 200}}]})

      {:ok, pid} =
        start_supervised(
          {LlamaCpp, model: Fixtures.model_tinyllama(), port: 8091, bin: script_path}
        )

      assert {:ok, 8091} = LlamaCpp.await_ready(pid)
    end

    test "stop/1 transitions to stopping and exits after the port closes" do
      script_path = make_fake_llama_script()
      parent = self()

      Application.put_env(:designator_inator, :llama_kill_runner, fn signal, os_pid ->
        send(parent, {:kill_called, signal, os_pid})
        System.cmd("kill", [signal, Integer.to_string(os_pid)])
      end)

      Agent.update(FakeReq, &%{&1 | get: [{:ok, %{status: 200}}]})

      {:ok, pid} =
        start_supervised(
          {LlamaCpp, model: Fixtures.model_tinyllama(), port: 8092, bin: script_path}
        )

      assert {:ok, 8092} = LlamaCpp.await_ready(pid)
      ref = Process.monitor(pid)

      assert :ok = LlamaCpp.stop(pid)
      assert_receive {:kill_called, "-TERM", _os_pid}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:designator_inator, key)
  defp restore_env(key, value), do: Application.put_env(:designator_inator, key, value)

  defp make_fake_llama_script do
    path = Path.join(System.tmp_dir!(), "fake_llama_server_#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(path, 0o755)
    path
  end
end
