defmodule DesignatorInator.ToolRegistryTest do
  use ExUnit.Case, async: false

  alias DesignatorInator.ToolRegistry
  alias DesignatorInator.Types.ToolDefinition

  setup do
    start_supervised!({ToolRegistry, []})
    :ok
  end

  defp tool(name, description \\ "desc") do
    %ToolDefinition{name: name, description: description, parameters: %{}}
  end

  test "lookup/1 returns all matching tools" do
    pid = self()
    ToolRegistry.register("assistant", pid, [tool("chat"), tool("status")])
    ToolRegistry.register("code-reviewer", pid, [tool("review_code")])

    assert [{"assistant", ^pid, %ToolDefinition{name: "chat"}}] = ToolRegistry.lookup("chat")
    assert [{"assistant", ^pid, %ToolDefinition{name: "status"}}] = ToolRegistry.lookup("status")
    assert ToolRegistry.lookup("missing") == []
  end

  test "list_all/0 returns every registration" do
    ToolRegistry.register("assistant", self(), [tool("chat")])
    ToolRegistry.register("code-reviewer", self(), [tool("review_code")])

    names =
      ToolRegistry.list_all()
      |> Enum.map(fn {pod_name, _pid, tool_def} -> {pod_name, tool_def.name} end)
      |> Enum.sort()

    assert names == [{"assistant", "chat"}, {"code-reviewer", "review_code"}]
  end

  test "tools_for_pod/1 returns only tools for the requested pod" do
    ToolRegistry.register("assistant", self(), [tool("chat"), tool("get_status")])
    ToolRegistry.register("code-reviewer", self(), [tool("review_code")])

    names =
      ToolRegistry.tools_for_pod("assistant")
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert names == ["chat", "get_status"]
  end

  test "register/2 replaces previous tools for the same pod" do
    pid = self()
    ToolRegistry.register("assistant", pid, [tool("chat")])
    ToolRegistry.register("assistant", pid, [tool("get_status")])

    assert ToolRegistry.lookup("chat") == []
    assert [{"assistant", ^pid, %ToolDefinition{name: "get_status"}}] = ToolRegistry.lookup("get_status")
  end

  test "deregister/1 removes all tools for a pod" do
    ToolRegistry.register("assistant", self(), [tool("chat")])
    assert :ok = ToolRegistry.deregister("assistant")
    assert ToolRegistry.lookup("chat") == []
    assert ToolRegistry.tools_for_pod("assistant") == []
  end
end
