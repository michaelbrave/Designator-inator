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

  alias DesignatorInator.{PodSupervisor, ModelInventory, SwarmRegistry, Pod, Memory}

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
    {command, command_args, flags} = parse_main_args(args)

    case ensure_app_started() do
      :ok ->
        case dispatch_command(command, command_args, flags) do
          :ok -> System.stop(0)
          {:error, reason} ->
            IO.puts(format_error(reason))
            System.stop(1)
        end

      {:error, reason} ->
        IO.puts(format_error(reason))
        System.stop(1)
    end
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
    case args do
      [pod_path | _] ->
        pod_path = Path.expand(pod_path)

        case DesignatorInator.Pod.Manifest.load(Path.join(pod_path, "manifest.yaml")) do
          {:ok, manifest} ->
            case PodSupervisor.start_pod(pod_path) do
              {:ok, _pid} ->
                if Keyword.get(flags, :detach, false) do
                  IO.puts("Pod started: #{manifest.name}")
                  :ok
                else
                  session_id = Keyword.get(flags, :session) || Memory.new_session_id()
                  IO.puts("[DesignatorInator] Starting pod: #{manifest.name}")
                  chat_loop(manifest.name, session_id)
                end
              
              {:error, reason} ->
                IO.puts(format_error(reason))
                {:error, reason}
            end

          {:error, reason} ->
            IO.puts(format_error(reason))
            {:error, reason}
        end

      [] ->
        IO.puts("Usage: designator-inator run <pod-path> [--detach] [--session <id>]")
        {:error, :missing_pod_path}
    end
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
    case args do
      [pod_path | _] ->
        case PodSupervisor.start_pod(pod_path) do
          {:ok, _pid} ->
            case Keyword.get(flags, :port) do
              nil ->
                IO.puts("[DesignatorInator] MCP stdio mode is not yet wired")
                {:error, :not_implemented}

              port ->
                IO.puts("[DesignatorInator] SSE mode on port #{port} is not yet wired")
                {:error, :not_implemented}
            end

          {:error, reason} ->
            IO.puts(format_error(reason))
            {:error, reason}
        end

      [] ->
        IO.puts("Usage: designator-inator serve <pod-path> [--port <n>]")
        {:error, :missing_pod_path}
    end
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
    pods = PodSupervisor.list_pods()

    rows =
      Enum.map(pods, fn %{name: name, status: status, pid: pid} ->
        [name, Atom.to_string(status), inspect(pid)]
      end)

    print_table(["NAME", "STATUS", "PID"], rows)
    :ok
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
    case args do
      [name | _] ->
        case PodSupervisor.stop_pod(name) do
          :ok ->
            IO.puts("[DesignatorInator] Pod stopped: #{name}")
            :ok

          {:error, reason} ->
            IO.puts(format_error(reason))
            {:error, reason}
        end

      [] ->
        IO.puts("Usage: designator-inator stop <name>")
        {:error, :missing_pod_name}
    end
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
    case ModelInventory.list() do
      {:ok, models} ->
        rows =
          Enum.map(models, fn model ->
            [
              model.name,
              format_params(model.size_params_b),
              format_quantization(model.quantization),
              format_size(model.size_bytes)
            ]
          end)

        print_table(["NAME", "PARAMS", "QUANT", "SIZE"], rows)
        :ok

      {:error, reason} ->
        IO.puts(format_error(reason))
        {:error, reason}
    end
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
    case args do
      [ip_or_hostname | _] ->
        case SwarmRegistry.connect(ip_or_hostname) do
          {:ok, node_name} ->
            IO.puts("[DesignatorInator] Connected to: #{node_name}")

            pods =
              SwarmRegistry.list_on_node(node_name)
              |> Enum.map_join(", ", fn %{name: name, pid: pid} ->
                "#{name} (#{inspect(pid)})"
              end)

            if pods != "" do
              IO.puts("[DesignatorInator] Remote pods visible: #{pods}")
            end

            :ok

          {:error, reason} ->
            IO.puts(format_error(reason))
            {:error, reason}
        end

      [] ->
        IO.puts("Usage: designator-inator connect <ip>")
        {:error, :missing_host}
    end
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
    IO.write("You: ")

    case IO.gets("") do
      :eof ->
        IO.puts("Goodbye")
        :ok

      input ->
        trimmed = String.trim(input)

        if trimmed == "/quit" do
          IO.puts("Goodbye")
          :ok
        else
          case pod_module().chat(pod_name, trimmed, session_id) do
            {:ok, response, next_session_id} ->
              IO.puts("#{pod_name}: #{response}")
              chat_loop(pod_name, next_session_id)

            {:error, reason} ->
              IO.puts(format_error(reason))
              :ok
          end
        end
    end
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

  defp parse_main_args(args) do
    case args do
      [] -> {nil, [], []}
      [command | rest] ->
        {flags, positional, _invalid} = OptionParser.parse(rest, strict: [detach: :boolean, session: :string, port: :integer])
        {command, positional, flags}
    end
  end

  defp ensure_app_started do
    case Application.ensure_all_started(:designator_inator) do
      {:ok, _} -> :ok
      {:error, {_app, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_command(nil, _args, _flags) do
    print_usage()
    {:error, :missing_command}
  end

  defp dispatch_command("run", args, flags), do: cmd_run(args, flags)
  defp dispatch_command("serve", args, flags), do: cmd_serve(args, flags)
  defp dispatch_command("list", _args, _flags), do: cmd_list()
  defp dispatch_command("stop", args, _flags), do: cmd_stop(args)
  defp dispatch_command("models", _args, _flags), do: cmd_models()
  defp dispatch_command("connect", args, _flags), do: cmd_connect(args)

  defp dispatch_command(_unknown, _args, _flags) do
    print_usage()
    {:error, :unknown_command}
  end

  defp pod_module do
    Application.get_env(:designator_inator, :cli_pod_module, Pod)
  end

  defp format_error(reason) when is_binary(reason), do: "[DesignatorInator] #{reason}"
  defp format_error(reason), do: "[DesignatorInator] #{inspect(reason)}"

  defp print_table(headers, rows) do
    widths = column_widths([headers | rows])

    [headers | rows]
    |> Enum.map_join("\n", &format_row(&1, widths))
    |> IO.puts()
  end

  defp column_widths(rows) do
    rows
    |> Enum.zip()
    |> Enum.map(fn column ->
      column
      |> Tuple.to_list()
      |> Enum.map(&String.length(to_string(&1)))
      |> Enum.reduce(0, &max/2)
    end)
  end

  defp format_row(cells, widths) do
    cells
    |> Enum.with_index()
    |> Enum.map(fn {cell, index} ->
      cell
      |> to_string()
      |> String.pad_trailing(Enum.at(widths, index, 0))
    end)
    |> Enum.join("  ")
  end

  defp format_params(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1) <> "B"
  defp format_params(value), do: to_string(value)

  defp format_quantization({:unknown, quant}), do: quant
  defp format_quantization(atom) when is_atom(atom), do: atom |> Atom.to_string() |> String.upcase()

  defp format_size(bytes) when is_integer(bytes) and bytes >= 1_000_000_000,
    do: :erlang.float_to_binary(bytes / 1_000_000_000, decimals: 1) <> " GB"

  defp format_size(bytes) when is_integer(bytes) and bytes >= 1_000_000,
    do: :erlang.float_to_binary(bytes / 1_000_000, decimals: 1) <> " MB"

  defp format_size(bytes), do: "#{bytes} B"
end
