defmodule BanditBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :bandit_bench,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BanditBench.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.4"},
      {:plug, "~> 1.13"}
    ]
  end
end
