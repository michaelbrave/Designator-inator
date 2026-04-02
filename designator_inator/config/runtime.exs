import Config

# Runtime config is evaluated after the app starts.
# Override any compile-time config here based on environment variables.

if vram = System.get_env("DESIGNATOR_INATOR_VRAM_MB") do
  config :designator_inator, :vram_budget_mb, String.to_integer(vram)
end

if models_dir = System.get_env("DESIGNATOR_INATOR_MODELS_DIR") do
  config :designator_inator, :models_dir, models_dir
end

if llama_bin = System.get_env("DESIGNATOR_INATOR_LLAMA_SERVER") do
  config :designator_inator, :llama_server_bin, llama_bin
end

if port = System.get_env("DESIGNATOR_INATOR_MCP_PORT") do
  config :designator_inator, :mcp_http_port, String.to_integer(port)
end
