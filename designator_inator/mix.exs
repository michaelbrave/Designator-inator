defmodule DesignatorInator.MixProject do
  use Mix.Project

  def project do
    [
      app: :designator_inator,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    if Mix.env() == :test do
      [
        extra_applications: [:logger, :crypto]
      ]
    else
      [
        extra_applications: [:logger, :crypto],
        mod: {DesignatorInator.Application, []}
      ]
    end
  end

  # Include test support files only in test env
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # HTTP client — for llama-server and cloud provider API calls
      {:req, "~> 0.5"},

      # YAML parsing — for manifest.yaml and config.yaml
      {:yaml_elixir, "~> 2.9"},

      # SQLite persistence — for conversation memory and task state
      {:ecto_sqlite3, "~> 0.17"},
      {:ecto, "~> 3.12"},

      # JSON — fast encoding/decoding for MCP JSON-RPC
      {:jason, "~> 1.4"},

      # HTTP server — for MCP SSE transport
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},

      # File system watching — for soul.md hot reload
      {:file_system, "~> 1.0"},

      # UUID generation — for session IDs and task IDs
      {:uniq, "~> 0.6"},

      # Test mocking
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
