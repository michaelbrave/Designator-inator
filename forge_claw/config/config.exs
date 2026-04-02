import Config

# ── Database ──────────────────────────────────────────────────────────────────
config :forge_claw, ForgeClaw.Memory.Repo,
  database: Path.expand("~/.forgeclaw/memory.db"),
  pool_size: 5

config :forge_claw, ecto_repos: [ForgeClaw.Memory.Repo]

# ── Model management ──────────────────────────────────────────────────────────
# Directory scanned for .gguf files at startup
config :forge_claw, :models_dir, Path.expand("~/.forgeclaw/models")

# Total VRAM budget in MB (set to RAM budget if running CPU-only)
config :forge_claw, :vram_budget_mb, 8192

# Directory for per-pod workspace storage
config :forge_claw, :workspaces_dir, Path.expand("~/.forgeclaw/workspaces")

# ── Inference ─────────────────────────────────────────────────────────────────
# Base port for llama-server instances; each model gets an incrementing port
config :forge_claw, :llama_server_base_port, 8080

# Path to the llama-server binary (auto-detected if on PATH)
config :forge_claw, :llama_server_bin, System.find_executable("llama-server") || "llama-server"

# Default inference timeout in milliseconds
config :forge_claw, :inference_timeout_ms, 120_000

# ── MCP gateway ───────────────────────────────────────────────────────────────
config :forge_claw, :mcp_http_port, 4000

# Tokens file for SSE client authentication
config :forge_claw, :tokens_file, Path.expand("~/.forgeclaw/tokens.yaml")

# ── ReAct loop ────────────────────────────────────────────────────────────────
config :forge_claw, :max_react_iterations, 20

import_config "#{config_env()}.exs"
