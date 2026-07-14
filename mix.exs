defmodule EBS.MixProject do
  use Mix.Project

  def project do
    [
      app: :ebs,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EBS.Application, []}
    ]
  end

  defp deps do
    [
      # HTTP + JSON
      {:httpoison, "~> 2.0"},
      {:jason, "~> 1.4"},

      # Database (metadata durability)
      {:ecto_sqlite3, "~> 0.12"},
      {:ecto, "~> 3.10"}
    ]
  end

  defp aliases do
    [test: ["test"]]
  end
end
