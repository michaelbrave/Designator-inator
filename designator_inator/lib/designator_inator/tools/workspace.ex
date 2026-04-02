defmodule DesignatorInator.Tools.Workspace do
  @moduledoc """
  Built-in tool: read, write, and list files in the pod's workspace directory.

  ## Data definitions (HTDP step 1)

  The `action` parameter determines which operation to perform:

  | action   | Required params | Optional params | Effect                               |
  |----------|-----------------|-----------------|--------------------------------------|
  | `"read"` | `path`          | —               | Returns file contents as text        |
  | `"write"`| `path`, `content` | —             | Writes `content` to the file         |
  | `"list"` | —               | `path`          | Lists files in `path` (default: root)|
  | `"delete"`| `path`         | —               | Deletes a file                       |

  ## Security: path traversal prevention

  All `path` arguments are resolved relative to the pod's workspace root.
  Before any filesystem operation, `safe_path/2` is called to verify that the
  resolved absolute path is still inside the workspace root.

  Attack vectors prevented:
  - `"../other-pod/secret.txt"` — walks up out of workspace
  - `"/etc/passwd"` — absolute path escape
  - `"foo/../../etc/passwd"` — double-traversal

  Any path that resolves outside the workspace root returns `{:error, "Access denied: ..."}`.

  ## Examples

  Given a workspace at `/home/user/.designator_inator/workspaces/my-pod/`:

      iex> call(%{"action" => "write", "path" => "notes.md", "content" => "hello"})
      {:ok, "Written: notes.md"}

      iex> call(%{"action" => "read", "path" => "notes.md"})
      {:ok, "hello"}

      iex> call(%{"action" => "list"})
      {:ok, "notes.md\\nplan.md"}

      iex> call(%{"action" => "read", "path" => "../../etc/passwd"})
      {:error, "Access denied: path is outside workspace"}
  """

  use DesignatorInator.Tool

  # ── Tool behaviour callbacks ─────────────────────────────────────────────────

  @impl DesignatorInator.Tool
  def name, do: "workspace"

  @impl DesignatorInator.Tool
  def description do
    "Read, write, list, and delete files in the agent's workspace directory. " <>
      "All paths are relative to the workspace root. " <>
      "Cannot access files outside the workspace."
  end

  @impl DesignatorInator.Tool
  def parameters_schema do
    %{
      "action" => %{
        type: :string,
        required: true,
        description: "Operation to perform",
        enum: ["read", "write", "list", "delete"]
      },
      "path" => %{
        type: :string,
        required: false,
        description: "File path relative to workspace root (required for read/write/delete)"
      },
      "content" => %{
        type: :string,
        required: false,
        description: "Content to write (required for write action)"
      }
    }
  end

  @doc """
  Dispatches to the appropriate file operation based on `params["action"]`.

  `workspace_root` is injected at runtime by the Pod process.  The tool module
  is instantiated with the workspace path so it can validate paths.

  When called by the `ReActLoop`, the params map comes directly from the LLM.
  Validation happens inside this function, not before.

  ## Examples

      iex> DesignatorInator.Tools.Workspace.call(%{
      ...>   "action" => "read",
      ...>   "path" => "notes.md",
      ...>   "_workspace_root" => "/home/user/.designator_inator/workspaces/my-pod"
      ...> })
      {:ok, "# Notes\\nHello world"}
  """
  @impl DesignatorInator.Tool
  @spec call(map()) :: {:ok, String.t()} | {:error, String.t()}
  def call(params) do
    # Template (HTDP step 4):
    # 1. Extract workspace_root from params["_workspace_root"]
    # 2. Pattern match on params["action"]:
    #    "read"   -> read_file(workspace_root, params["path"])
    #    "write"  -> write_file(workspace_root, params["path"], params["content"])
    #    "list"   -> list_files(workspace_root, params["path"] || ".")
    #    "delete" -> delete_file(workspace_root, params["path"])
    #    _        -> {:error, "Unknown action: #{action}"}
    workspace_root = params["_workspace_root"]
    action = params["action"]

    cond do
      not is_binary(workspace_root) or workspace_root == "" ->
        {:error, "Missing workspace root"}

      action == "read" and is_binary(params["path"]) ->
        read_file(workspace_root, params["path"])

      action == "write" and is_binary(params["path"]) and is_binary(params["content"]) ->
        write_file(workspace_root, params["path"], params["content"])

      action == "list" ->
        list_files(workspace_root, params["path"] || ".")

      action == "delete" and is_binary(params["path"]) ->
        delete_file(workspace_root, params["path"])

      action in ["read", "delete"] ->
        {:error, "Missing required path"}

      action == "write" and not is_binary(params["path"]) ->
        {:error, "Missing required path"}

      action == "write" ->
        {:error, "Missing required content"}

      true ->
        {:error, "Unknown action: #{inspect(action)}"}
    end
  end

  # ── Pure helper functions ────────────────────────────────────────────────────

  @doc """
  Resolves `relative_path` against `workspace_root` and checks it stays inside.

  Returns `{:ok, absolute_path}` if safe, `{:error, :path_traversal}` otherwise.

  This is the security boundary.  All file operations call this first.

  ## Examples

      iex> DesignatorInator.Tools.Workspace.safe_path("/workspaces/my-pod", "notes.md")
      {:ok, "/workspaces/my-pod/notes.md"}

      iex> DesignatorInator.Tools.Workspace.safe_path("/workspaces/my-pod", "../other-pod/secret")
      {:error, :path_traversal}

      iex> DesignatorInator.Tools.Workspace.safe_path("/workspaces/my-pod", "/etc/passwd")
      {:error, :path_traversal}

      iex> DesignatorInator.Tools.Workspace.safe_path("/workspaces/my-pod", "a/b/../../notes.md")
      {:ok, "/workspaces/my-pod/notes.md"}
  """
  @spec safe_path(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, :path_traversal}
  def safe_path(workspace_root, relative_path) do
    # Template (HTDP step 4):
    # 1. Build candidate = Path.join(workspace_root, relative_path)
    # 2. Expand to absolute: resolved = Path.expand(candidate)
    # 3. normalized_root = Path.expand(workspace_root)
    # 4. Check: String.starts_with?(resolved, normalized_root <> "/") or resolved == normalized_root
    # 5. If yes: {:ok, resolved}
    # 6. If no: {:error, :path_traversal}
    if Path.type(relative_path) == :absolute do
      {:error, :path_traversal}
    else
      normalized_root = Path.expand(workspace_root)
      resolved = workspace_root |> Path.join(relative_path) |> Path.expand()

      if resolved == normalized_root or String.starts_with?(resolved, normalized_root <> "/") do
        {:ok, resolved}
      else
        {:error, :path_traversal}
      end
    end
  end

  @doc """
  Reads the file at `relative_path` inside `workspace_root`.

  ## Examples

      iex> DesignatorInator.Tools.Workspace.read_file("/workspaces/my-pod", "notes.md")
      {:ok, "# Notes\\nHello world"}

      iex> DesignatorInator.Tools.Workspace.read_file("/workspaces/my-pod", "missing.txt")
      {:error, "File not found: missing.txt"}

      iex> DesignatorInator.Tools.Workspace.read_file("/workspaces/my-pod", "../../etc/passwd")
      {:error, "Access denied: path is outside workspace"}
  """
  @spec read_file(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read_file(workspace_root, relative_path) do
    # Template (HTDP step 4):
    # 1. Call safe_path(workspace_root, relative_path)
    # 2. On {:error, :path_traversal}: return user-facing error message
    # 3. On {:ok, abs_path}: File.read(abs_path)
    # 4. On {:ok, content}: return {:ok, content}
    # 5. On {:error, :enoent}: return {:error, "File not found: #{relative_path}"}
    # 6. On other file errors: return {:error, "Cannot read #{relative_path}: #{inspect(reason)}"}
    case safe_path(workspace_root, relative_path) do
      {:error, :path_traversal} ->
        {:error, "Access denied: path is outside workspace"}

      {:ok, abs_path} ->
        case File.read(abs_path) do
          {:ok, content} -> {:ok, content}
          {:error, :enoent} -> {:error, "File not found: #{relative_path}"}
          {:error, reason} -> {:error, "Cannot read #{relative_path}: #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Writes `content` to `relative_path` inside `workspace_root`.
  Creates intermediate directories if needed.

  ## Examples

      iex> DesignatorInator.Tools.Workspace.write_file("/workspaces/my-pod", "notes.md", "hello")
      {:ok, "Written: notes.md"}

      iex> DesignatorInator.Tools.Workspace.write_file("/workspaces/my-pod", "subdir/file.txt", "data")
      {:ok, "Written: subdir/file.txt"}

      iex> DesignatorInator.Tools.Workspace.write_file("/workspaces/my-pod", "../escape.txt", "bad")
      {:error, "Access denied: path is outside workspace"}
  """
  @spec write_file(Path.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def write_file(workspace_root, relative_path, content) do
    # Template (HTDP step 4):
    # 1. Call safe_path(workspace_root, relative_path) — guard traversal
    # 2. Create parent dirs: File.mkdir_p!(Path.dirname(abs_path))
    # 3. File.write(abs_path, content)
    # 4. On :ok: return {:ok, "Written: #{relative_path}"}
    # 5. On {:error, reason}: return {:error, "Cannot write #{relative_path}: #{reason}"}
    case safe_path(workspace_root, relative_path) do
      {:error, :path_traversal} ->
        {:error, "Access denied: path is outside workspace"}

      {:ok, abs_path} ->
        File.mkdir_p!(Path.dirname(abs_path))

        case File.write(abs_path, content) do
          :ok -> {:ok, "Written: #{relative_path}"}
          {:error, reason} -> {:error, "Cannot write #{relative_path}: #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Lists files in `relative_path` inside `workspace_root`.

  Returns a newline-separated list of relative paths so the LLM can read it
  as plain text.

  ## Examples

      iex> DesignatorInator.Tools.Workspace.list_files("/workspaces/my-pod", ".")
      {:ok, "notes.md\\nplan.md\\nsubdir/file.txt"}

      iex> DesignatorInator.Tools.Workspace.list_files("/workspaces/my-pod", "subdir")
      {:ok, "subdir/file.txt"}

      iex> DesignatorInator.Tools.Workspace.list_files("/workspaces/my-pod", "nonexistent")
      {:error, "Directory not found: nonexistent"}
  """
  @spec list_files(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def list_files(workspace_root, relative_path) do
    # Template (HTDP step 4):
    # 1. Call safe_path(workspace_root, relative_path)
    # 2. Walk directory recursively (Path.wildcard or File.ls with recursion)
    # 3. Strip workspace_root prefix from each path
    # 4. Sort and join with newlines
    # 5. Return {:ok, joined_string}
    case safe_path(workspace_root, relative_path) do
      {:error, :path_traversal} ->
        {:error, "Access denied: path is outside workspace"}

      {:ok, abs_path} ->
        cond do
          not File.exists?(abs_path) ->
            {:error, "Directory not found: #{relative_path}"}

          not File.dir?(abs_path) ->
            {:error, "Not a directory: #{relative_path}"}

          true ->
            files =
              abs_path
              |> Path.join("**")
              |> Path.wildcard(match_dot: true)
              |> Enum.filter(&File.regular?/1)
              |> Enum.map(&Path.relative_to(&1, workspace_root))
              |> Enum.sort()

            {:ok, Enum.join(files, "\n")}
        end
    end
  end

  @doc """
  Deletes the file at `relative_path` inside `workspace_root`.

  Does not delete directories.

  ## Examples

      iex> DesignatorInator.Tools.Workspace.delete_file("/workspaces/my-pod", "notes.md")
      {:ok, "Deleted: notes.md"}

      iex> DesignatorInator.Tools.Workspace.delete_file("/workspaces/my-pod", "missing.txt")
      {:error, "File not found: missing.txt"}
  """
  @spec delete_file(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def delete_file(workspace_root, relative_path) do
    # Template (HTDP step 4):
    # 1. safe_path guard
    # 2. File.rm(abs_path)
    # 3. Map results to user-facing strings
    case safe_path(workspace_root, relative_path) do
      {:error, :path_traversal} ->
        {:error, "Access denied: path is outside workspace"}

      {:ok, abs_path} ->
        case File.rm(abs_path) do
          :ok -> {:ok, "Deleted: #{relative_path}"}
          {:error, :enoent} -> {:error, "File not found: #{relative_path}"}
          {:error, :eisdir} -> {:error, "Cannot delete directory: #{relative_path}"}
          {:error, reason} -> {:error, "Cannot delete #{relative_path}: #{inspect(reason)}"}
        end
    end
  end
end
