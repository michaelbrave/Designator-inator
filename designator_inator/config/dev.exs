import Config

config :logger, :console,
  format: "[$level] $message\n",
  metadata: [:pod, :model, :session_id]

config :designator_inator, :vram_budget_mb, 16_384
