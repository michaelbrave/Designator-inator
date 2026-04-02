import Config

# Use an in-memory SQLite database for tests
config :designator_inator, DesignatorInator.Memory.Repo,
  database: Path.expand("../tmp/designator_inator_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

# Small VRAM budget for tests so eviction logic triggers easily
config :designator_inator, :vram_budget_mb, 512

# Point model dir at the test fixtures directory
config :designator_inator, :models_dir, Path.expand("../test/fixtures/models", __DIR__)

config :designator_inator, :workspaces_dir, Path.expand("../test/fixtures/workspaces", __DIR__)

# Mock inference in unit tests — integration tests override per-test
config :designator_inator, :inference_provider_mock, true

config :logger, level: :warning
