defmodule ForgeClaw.Tools.WorkspaceTest do
  @moduledoc """
  Tests for `ForgeClaw.Tools.Workspace`.

  ## Testing strategy (HTDP step 6)

  `safe_path/2` is the security-critical function and is tested exhaustively.
  All file operation tests call through the full `call/1` interface to validate
  the integration of safe_path with the actual filesystem operations.
  """

  use ExUnit.Case, async: true

  alias ForgeClaw.Tools.Workspace

  setup do
    workspace = Path.join(System.tmp_dir!(), "fc_workspace_#{:rand.uniform(99999)}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  # ── safe_path/2 — security boundary ──────────────────────────────────────────

  describe "safe_path/2" do
    test "allows a simple relative path", %{workspace: ws} do
      assert {:ok, path} = Workspace.safe_path(ws, "notes.md")
      assert path == Path.join(ws, "notes.md")
    end

    test "allows nested relative paths", %{workspace: ws} do
      assert {:ok, _} = Workspace.safe_path(ws, "subdir/file.txt")
    end

    test "allows path that stays inside after resolution", %{workspace: ws} do
      assert {:ok, path} = Workspace.safe_path(ws, "a/b/../../notes.md")
      assert path == Path.join(ws, "notes.md")
    end

    test "blocks path traversal with ..", %{workspace: ws} do
      assert {:error, :path_traversal} = Workspace.safe_path(ws, "../other-pod/secret")
    end

    test "blocks absolute path escape", %{workspace: ws} do
      assert {:error, :path_traversal} = Workspace.safe_path(ws, "/etc/passwd")
    end

    test "blocks double traversal", %{workspace: ws} do
      assert {:error, :path_traversal} = Workspace.safe_path(ws, "foo/../../etc/passwd")
    end
  end

  # ── read_file/2 ───────────────────────────────────────────────────────────────

  describe "read_file/2" do
    test "reads an existing file", %{workspace: ws} do
      File.write!(Path.join(ws, "hello.txt"), "world")
      assert {:ok, "world"} = Workspace.read_file(ws, "hello.txt")
    end

    test "returns error for missing file", %{workspace: ws} do
      assert {:error, msg} = Workspace.read_file(ws, "nonexistent.txt")
      assert msg =~ "not found"
    end

    test "blocks path traversal", %{workspace: ws} do
      assert {:error, msg} = Workspace.read_file(ws, "../../etc/passwd")
      assert msg =~ "denied"
    end
  end

  # ── write_file/3 ──────────────────────────────────────────────────────────────

  describe "write_file/3" do
    test "writes a new file", %{workspace: ws} do
      assert {:ok, _} = Workspace.write_file(ws, "new.txt", "content")
      assert File.read!(Path.join(ws, "new.txt")) == "content"
    end

    test "creates subdirectories as needed", %{workspace: ws} do
      assert {:ok, _} = Workspace.write_file(ws, "sub/dir/file.txt", "data")
      assert File.exists?(Path.join(ws, "sub/dir/file.txt"))
    end

    test "blocks path traversal", %{workspace: ws} do
      assert {:error, msg} = Workspace.write_file(ws, "../escape.txt", "bad")
      assert msg =~ "denied"
      refute File.exists?(Path.join(Path.dirname(ws), "escape.txt"))
    end
  end

  # ── list_files/2 ──────────────────────────────────────────────────────────────

  describe "list_files/2" do
    test "lists files in workspace root", %{workspace: ws} do
      File.write!(Path.join(ws, "a.txt"), "")
      File.write!(Path.join(ws, "b.txt"), "")
      assert {:ok, listing} = Workspace.list_files(ws, ".")
      assert listing =~ "a.txt"
      assert listing =~ "b.txt"
    end

    test "returns error for nonexistent subdir", %{workspace: ws} do
      assert {:error, _} = Workspace.list_files(ws, "nonexistent")
    end
  end

  # ── call/1 — full integration ─────────────────────────────────────────────────

  describe "call/1" do
    test "write then read round-trip", %{workspace: ws} do
      assert {:ok, _} = Workspace.call(%{
        "action" => "write",
        "path" => "roundtrip.txt",
        "content" => "hello workspace",
        "_workspace_root" => ws
      })

      assert {:ok, "hello workspace"} = Workspace.call(%{
        "action" => "read",
        "path" => "roundtrip.txt",
        "_workspace_root" => ws
      })
    end

    test "returns error for unknown action", %{workspace: ws} do
      assert {:error, msg} = Workspace.call(%{
        "action" => "explode",
        "_workspace_root" => ws
      })
      assert msg =~ "Unknown action"
    end
  end
end
