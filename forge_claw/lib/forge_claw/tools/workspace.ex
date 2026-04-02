defmodule ForgeClaw.Tools.Workspace do
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

  Given a workspace at `/home/user/.forgeclaw/workspaces/my-pod/`:

      iex> call(%{"action" => "write", "path" => "notes.md", "content" => "hello"})
      {:ok, "Written: notes.md"}

      iex> call(%{"action" => "read", "path" => "notes.md"})
      {:ok, "hello"}

      iex> call(%{"action" => "list"})
      {:ok, "notes.md\\nplan.md"}

      iex> call(%{"action" => "read", "path" => "../../etc/passwd"})
      {:error, "Access denied: path is outside workspace"}
  """

  use ForgeClaw.Tool

  # ── Tool behaviour callbacks ─────────────────────────────────────────────────

  @impl ForgeClaw.Tool
  def name, do: "workspace"

  @impl ForgeClaw.Tool
  def description do
    "Read, write, list, and delete files in the agent's workspace directory. " <>
      "All paths are relative to the workspace root. " <>
      "Cannot access files outside the workspace."
  end

  @impl ForgeClaw.Tool
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

      iex> ForgeClaw.Tools.Workspace.call(%{
      ...>   "action" => "read",
      ...>   "path" => "notes.md",
      ...>   "_workspace_root" => "/home/user/.forgeclaw/workspaces/my-pod"
      ...> })
      {:ok, "# Notes\\nHello world"}
  """
  @impl ForgeClaw.Tool
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
    raise "not implemented"
  end

  # ── Pure helper functions ────────────────────────────────────────────────────

  @doc """
  Resolves `relative_path` against `workspace_root` and checks it stays inside.

  Returns `{:ok, absolute_path}` if safe, `{:error, :path_traversal}` otherwise.

  This is the security boundary.  All file operations call this first.

  ## Examples

      iex> ForgeClaw.Tools.Workspace.safe_path("/workspaces/my-pod", "notes.md")
      {:ok, "/workspaces/my-pod/notes.md"}

      iex> ForgeClaw.Tools.Workspace.safe_path("/workspaces/my-pod", "../other-pod/secret")
      {:error, :path_traversal}

      iex> ForgeClaw.Tools.Workspace.safe_path("/workspaces/my-pod", "/etc/passwd")
      {:error, :path_traversal}

      iex> ForgeClaw.Tools.Workspace.safe_path("/workspaces/my-pod", "a/b/../../notes.md")
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
    raise "not implemented"
  end

  @doc """
  Reads the file at `relative_path` inside `workspace_root`.

  ## Examples

      iex> ForgeClaw.Tools.Workspace.read_file("/workspaces/my-pod", "notes.md")
      {:ok, "# Notes\\nHello world"}

      iex> ForgeClaw.Tools.Workspace.read_file("/workspaces/my-pod", "missing.txt")
      {:error, "File not found: missing.txt"}

      iex> ForgeClaw.Tools.Workspace.read_file("/workspaces/my-pod", "../../etc/passwd")
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
    raise "not implemented"
  end

  @doc """
  Writes `content` to `relative_path` inside `workspace_root`.
  Creates intermediate directories if needed.

  ## Examples

      iex> ForgeClaw.Tools.Workspace.write_file("/workspaces/my-pod", "notes.md", "hello")
      {:ok, "Written: notes.md"}

      iex> ForgeClaw.Tools.Workspace.write_file("/workspaces/my-pod", "subdir/file.txt", "data")
      {:ok, "Written: subdir/file.txt"}

      iex> ForgeClaw.Tools.Workspace.write_file("/workspaces/my-pod", "../escape.txt", "bad")
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
    raise "not implemented"
  end

  @doc """
  Lists files in `relative_path` inside `workspace_root`.

  Returns a newline-separated list of relative paths so the LLM can read it
  as plain text.

  ## Examples

      iex> ForgeClaw.Tools.Workspace.list_files("/workspaces/my-pod", ".")
      {:ok, "notes.md\\nplan.md\\nsubdir/file.txt"}

      iex> ForgeClaw.Tools.Workspace.list_files("/workspaces/my-pod", "subdir")
      {:ok, "subdir/file.txt"}

      iex> ForgeClaw.Tools.Workspace.list_files("/workspaces/my-pod", "nonexistent")
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
    raise "not implemented"
  end

  @doc """
  Deletes the file at `relative_path` inside `workspace_root`.

  Does not delete directories.

  ## Examples

      iex> ForgeClaw.Tools.Workspace.delete_file("/workspaces/my-pod", "notes.md")
      {:ok, "Deleted: notes.md"}

      iex> ForgeClaw.Tools.Workspace.delete_file("/workspaces/my-pod", "missing.txt")
      {:error, "File not found: missing.txt"}
  """
  @spec delete_file(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def delete_file(workspace_root, relative_path) do
    # Template (HTDP step 4):
    # 1. safe_path guard
    # 2. File.rm(abs_path)
    # 3. Map results to user-facing strings
    raise "not implemented"
  end
end
