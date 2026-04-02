ExUnit.start()

# Set up SQLite sandbox for tests that use the Memory.Repo
{:ok, _} = DesignatorInator.Memory.Repo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(DesignatorInator.Memory.Repo, :manual)
