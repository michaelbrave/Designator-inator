defmodule ForgeClaw.Test.Fixtures do
  @moduledoc """
  Shared test data for ForgeClaw unit and integration tests.

  All fixtures are pure data — no filesystem or network access.
  Tests that need real files should use `Briefly` or write to `tmp_dir/0`.
  """

  alias ForgeClaw.Types.{
    Model, LoadedModel, Message, ToolCall, ToolResult,
    ToolDefinition, PodManifest, PodState,
    ResourceRequirements, ModelPreference
  }

  # ── Models ───────────────────────────────────────────────────────────────────

  def model_mistral do
    %Model{
      name: "mistral-7b-instruct-v0.3.Q4_K_M",
      path: "/tmp/models/mistral-7b-instruct-v0.3.Q4_K_M.gguf",
      size_params_b: 7.0,
      quantization: :q4_k_m,
      context_length: 32768,
      size_bytes: 4_368_438_272
    }
  end

  def model_tinyllama do
    %Model{
      name: "tinyllama-1.1b-chat-v1.0.Q4_K_M",
      path: "/tmp/models/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
      size_params_b: 1.1,
      quantization: :q4_k_m,
      context_length: 2048,
      size_bytes: 669_000_000
    }
  end

  # ── Messages ─────────────────────────────────────────────────────────────────

  def system_message(content \\ "You are a helpful assistant.") do
    %Message{role: :system, content: content}
  end

  def user_message(content) do
    %Message{role: :user, content: content}
  end

  def assistant_message(content) do
    %Message{role: :assistant, content: content}
  end

  def tool_message(content, tool_call_id) do
    %Message{role: :tool, content: content, tool_call_id: tool_call_id}
  end

  def assistant_message_with_tool_call do
    %Message{
      role: :assistant,
      content: nil,
      tool_calls: [
        %ToolCall{id: "call_001", name: "workspace", arguments: %{"action" => "list"}}
      ]
    }
  end

  # ── Tool definitions ──────────────────────────────────────────────────────────

  def chat_tool_definition do
    %ToolDefinition{
      name: "chat",
      description: "Have a conversation with the assistant.",
      parameters: %{
        "message" => %{type: :string, required: true, description: "The user's message"}
      }
    }
  end

  def workspace_tool_definition do
    %ToolDefinition{
      name: "workspace",
      description: "Read, write, and list files in the agent's workspace.",
      parameters: %{
        "action"  => %{type: :string, required: true, enum: ["read", "write", "list", "delete"]},
        "path"    => %{type: :string, required: false},
        "content" => %{type: :string, required: false}
      }
    }
  end

  # ── Manifests ─────────────────────────────────────────────────────────────────

  def assistant_manifest do
    %PodManifest{
      name: "assistant",
      version: "1.0.0",
      description: "A general-purpose helpful assistant.",
      requires: %ResourceRequirements{min_ram_mb: 4096, gpu: :optional},
      model: %ModelPreference{
        primary: "mistral-7b-instruct-v0.3.Q4_K_M",
        fallback: nil,
        fallback_mode: :disabled
      },
      exposed_tools: [chat_tool_definition()],
      internal_tools: ["workspace"],
      isolation: :beam
    }
  end

  def minimal_manifest_yaml do
    """
    name: test-pod
    version: 0.1.0
    description: A minimal test pod
    exposed_tools:
      - name: ping
        description: Returns pong
        parameters: {}
    """
  end

  def invalid_manifest_yaml do
    """
    version: 0.1.0
    # missing name, description, exposed_tools
    """
  end

  # ── Pod state ─────────────────────────────────────────────────────────────────

  def idle_pod_state do
    %PodState{
      name: "assistant",
      path: "/tmp/pods/assistant",
      manifest: assistant_manifest(),
      soul: "You are a helpful assistant.",
      status: :idle,
      model: "mistral-7b-instruct-v0.3.Q4_K_M",
      workspace: "/tmp/workspaces/assistant",
      started_at: ~U[2025-01-01 12:00:00Z]
    }
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  @doc "Returns the path to the test fixtures directory."
  def fixtures_dir do
    Path.expand("../fixtures", __DIR__)
  end

  @doc "Creates a temporary directory for the test, cleaned up on exit."
  def tmp_dir(context) do
    dir = Path.join(System.tmp_dir!(), "forgeclaw_test_#{context.test}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
