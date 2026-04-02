defmodule DesignatorInator.CLI do
  @moduledoc """
  The `designator-inator` command-line interface.

  ## Commands

  | Command                         | Description                                      |
  |---------------------------------|--------------------------------------------------|
  | `designator-inator run <pod-path>`          | Start a pod and enter interactive chat           |
  | `designator-inator run <pod-path> --detach` | Start a pod in the background                    |
  | `designator-inator serve <pod-path>`        | Start a pod as an MCP server (stdio transport)   |
  | `designator-inator list`                    | List running pods                                |
  | `designator-inator stop <name>`             | Gracefully stop a running pod                    |
  | `designator-inator logs <name>`             | Tail a pod's log output                          |
  | `designator-inator models`                  | List available GGUF models                       |
  | `designator-inator connect <ip>`            | Connect to a remote DesignatorInator node               |

  ## Implementation note

  The CLI is built as an escript (`mix escript.build` → `./designator-inator` binary).
  It starts the full DesignatorInator OTP application and then executes the requested
  command against the running system.
  """

  alias DesignatorInator.{PodSupervisor, ModelInventory, SwarmRegistry}

  @doc """
  Escript entry point — called with command-line args as a list of strings.
  """
  @spec main([String.t()]) :: no_return()
  def main(args) do
    # Template (HTDP step 4):
    # 1. Parse args into {command, sub-args, flags} using OptionParser
    # 2. Start the OTP application: Application.ensure_all_started(:designator_inator)
    # 3. Dispatch to the appropriate command handler
    # 4. System.stop(0) on success
    raise "not implemented"
  end

  # ── Command handlers ──────────────────────────────────────────────────────────

  @doc """
  `designator-inator run <pod-path> [--detach] [--session <id>]`

  Starts a pod and either enters interactive chat mode or detaches.

  ## Examples

      $ designator-inator run ./examples/assistant/
      [DesignatorInator] Starting pod: assistant
      [DesignatorInator] Model loaded: mistral-7b-instruct-v0.3.Q4_K_M
      You: Hello!
      assistant: Hello! How can I help you today?
      You: ^C
  """
  @spec cmd_run([String.t()], keyword()) :: :ok | {:error, term()}
  def cmd_run(args, flags) do
    # Template (HTDP step 4):
    # 1. Extract pod_path from args[0], handle missing arg
    # 2. PodSupervisor.start_pod(pod_path)
    # 3. On error: print error and exit
    # 4. If --detach: print "Pod started: #{name}" and return
    # 5. If interactive: enter chat_loop(pod_name, session_id)
    raise "not implemented"
  end

  @doc """
  `designator-inator serve <pod-path> [--port <n>]`

  Starts a pod and exposes it as an MCP server.
  For Claude Desktop: uses stdio transport.
  With --port: uses SSE transport on the specified port.

  ## Examples

      $ designator-inator serve ./examples/code-reviewer/
      # (blocks, writing MCP JSON-RPC to stdout)
  """
  @spec cmd_serve([String.t()], keyword()) :: :ok | {:error, term()}
  def cmd_serve(args, flags) do
    # Template (HTDP step 4):
    # 1. Extract pod_path, optional --port flag
    # 2. PodSupervisor.start_pod(pod_path)
    # 3. If --port: configure SSE transport on that port
    # 4. If no --port: configure stdio transport (default for Claude Desktop)
    # 5. Block until transport signals done (EOF or shutdown)
    raise "not implemented"
  end

  @doc """
  `designator-inator list`

  Prints all running pods with their status.

  ## Examples

      $ designator-inator list
      NAME            STATUS    MODEL                              NODE
      assistant       idle      mistral-7b-instruct-v0.3.Q4_K_M   local
      code-reviewer   running   codellama-13b-instruct.Q4_K_M     local
  """
  @spec cmd_list :: :ok
  def cmd_list do
    # Template:
    # 1. PodSupervisor.list_pods()
    # 2. Format as a table with headers
    # 3. IO.puts the table
    raise "not implemented"
  end

  @doc """
  `designator-inator stop <name>`

  ## Examples

      $ designator-inator stop assistant
      [DesignatorInator] Pod stopped: assistant
  """
  @spec cmd_stop([String.t()]) :: :ok | {:error, term()}
  def cmd_stop(args) do
    # Template:
    # 1. Extract name from args[0]
    # 2. PodSupervisor.stop_pod(name)
    # 3. Print result
    raise "not implemented"
  end

  @doc """
  `designator-inator models`

  Lists all .gguf files in the models directory.

  ## Examples

      $ designator-inator models
      NAME                                   PARAMS   QUANT    SIZE
      mistral-7b-instruct-v0.3.Q4_K_M        7.0B    Q4_K_M   4.1 GB
      codellama-13b-instruct.Q5_K_M          13.0B   Q5_K_M   8.6 GB
  """
  @spec cmd_models :: :ok
  def cmd_models do
    # Template:
    # 1. ModelInventory.list()
    # 2. Format as table
    # 3. IO.puts
    raise "not implemented"
  end

  @doc """
  `designator-inator connect <ip>`

  ## Examples

      $ designator-inator connect 192.168.1.50
      [DesignatorInator] Connected to: designator_inator@192.168.1.50
      [DesignatorInator] Remote pods visible: code-reviewer (pi4)
  """
  @spec cmd_connect([String.t()]) :: :ok | {:error, term()}
  def cmd_connect(args) do
    # Template:
    # 1. Extract ip from args[0]
    # 2. SwarmRegistry.connect(ip)
    # 3. List newly visible pods
    raise "not implemented"
  end

  # ── Interactive chat loop ─────────────────────────────────────────────────────

  @doc """
  Enters an interactive REPL loop for chatting with a pod.

  Reads from stdin, sends to the pod, prints the response.
  Exits on EOF (Ctrl-D) or when the user types `/quit`.

  ## Examples

      # Internal — called by cmd_run/2
      DesignatorInator.CLI.chat_loop("assistant", "session-uuid")
      # You: Hello
      # assistant: Hi! How can I help?
      # You: /quit
  """
  @spec chat_loop(String.t(), String.t()) :: :ok
  def chat_loop(pod_name, session_id) do
    # Template (HTDP step 4):
    # 1. IO.write("You: ")
    # 2. IO.gets("") → input | :eof
    # 3. On :eof or "/quit\n": print goodbye, return :ok
    # 4. On input: DesignatorInator.Pod.chat(pod_name, String.trim(input), session_id)
    # 5. Print "#{pod_name}: #{response}"
    # 6. Recurse with the returned session_id
    raise "not implemented"
  end

  # ── Usage/help ────────────────────────────────────────────────────────────────

  @doc false
  def print_usage do
    IO.puts("""
    designator-inator — Designator-inator agent orchestration CLI

    Usage:
      designator-inator run <pod-path> [--detach] [--session <id>]
      designator-inator serve <pod-path> [--port <n>]
      designator-inator list
      designator-inator stop <name>
      designator-inator logs <name>
      designator-inator models
      designator-inator connect <ip>

    Examples:
      designator-inator run ./examples/assistant/
      designator-inator serve ./examples/code-reviewer/ --port 4000
      designator-inator models
    """)
  end
end
