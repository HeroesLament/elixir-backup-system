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
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 0.20"},
      {:phoenix_html, "~> 3.0"},
      {:plug_cowboy, "~> 2.7"},
      {:httpoison, "~> 2.0"},
      {:jason, "~> 1.4"},
      {:rocksdb, "~> 1.8"},
      {:ex_aws, "~> 2.4"},
      {:ex_aws_s3, "~> 2.4"},
      {:libcluster, "~> 3.3"},
      {:logger_json, "~> 5.1"},
      {:telemetry, "~> 1.2"},
      {:ex_doc, "~> 0.31", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [test: ["test"]]
  end
end
