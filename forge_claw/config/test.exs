import Config

# Use an in-memory SQLite database for tests
config :forge_claw, ForgeClaw.Memory.Repo,
  database: ":memory:",
  pool: Ecto.Adapters.SQL.Sandbox

# Small VRAM budget for tests so eviction logic triggers easily
config :forge_claw, :vram_budget_mb, 512

# Point model dir at the test fixtures directory
config :forge_claw, :models_dir, Path.expand("../test/fixtures/models", __DIR__)

config :forge_claw, :workspaces_dir, Path.expand("../test/fixtures/workspaces", __DIR__)

# Mock inference in unit tests — integration tests override per-test
config :forge_claw, :inference_provider_mock, true

config :logger, level: :warning
