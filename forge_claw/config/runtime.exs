import Config

# Runtime config is evaluated after the app starts.
# Override any compile-time config here based on environment variables.

if vram = System.get_env("FORGECLAW_VRAM_MB") do
  config :forge_claw, :vram_budget_mb, String.to_integer(vram)
end

if models_dir = System.get_env("FORGECLAW_MODELS_DIR") do
  config :forge_claw, :models_dir, models_dir
end

if llama_bin = System.get_env("FORGECLAW_LLAMA_SERVER") do
  config :forge_claw, :llama_server_bin, llama_bin
end

if port = System.get_env("FORGECLAW_MCP_PORT") do
  config :forge_claw, :mcp_http_port, String.to_integer(port)
end
