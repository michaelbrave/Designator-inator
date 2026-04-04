import Config

# ── Database ──────────────────────────────────────────────────────────────────
config :designator_inator, DesignatorInator.Memory.Repo,
  database: Path.expand("~/.designator_inator/memory.db"),
  pool_size: 5

config :designator_inator, ecto_repos: [DesignatorInator.Memory.Repo]

# ── Model management ──────────────────────────────────────────────────────────
# Directory scanned for .gguf files at startup
config :designator_inator, :models_dir, Path.expand("~/.designator_inator/models")

# Total VRAM budget in MB (set to RAM budget if running CPU-only)
config :designator_inator, :vram_budget_mb, 8192

# Directory for per-pod workspace storage
config :designator_inator, :workspaces_dir, Path.expand("~/.designator_inator/workspaces")

# ── Inference ─────────────────────────────────────────────────────────────────
# Base port for llama-server instances; each model gets an incrementing port
config :designator_inator, :llama_server_base_port, 8080

# Path to the llama-server binary (auto-detected if on PATH)
config :designator_inator, :llama_server_bin, System.find_executable("llama-server") || "llama-server"

# Default inference timeout in milliseconds
config :designator_inator, :inference_timeout_ms, 120_000

# How long to wait for llama-server to become healthy after starting (ms).
# Large models need several minutes to load tensors and run the warm-up pass.
config :designator_inator, :llama_ready_timeout_ms, 210_000   # 3.5 min

# Default context window when the model file reports 0 (unknown).
# Prevents llama-server from using its own default (often 256k) which
# allocates enormous KV caches. Override per-pod in config.yaml.
config :designator_inator, :default_context_size, 16_384

# ── MCP gateway ───────────────────────────────────────────────────────────────
config :designator_inator, :mcp_http_port, 4000

# Tokens file for SSE client authentication
config :designator_inator, :tokens_file, Path.expand("~/.designator_inator/tokens.yaml")

# ── ReAct loop ────────────────────────────────────────────────────────────────
config :designator_inator, :max_react_iterations, 20

import_config "#{config_env()}.exs"
