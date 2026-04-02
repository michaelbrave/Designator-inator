ExUnit.start()

# Set up SQLite sandbox for tests that use the Memory.Repo
Ecto.Adapters.SQL.Sandbox.mode(ForgeClaw.Memory.Repo, :manual)
