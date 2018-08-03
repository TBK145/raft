defmodule Raft.MixProject do
  use Mix.Project

  def project do
    [
      app: :raft,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Raft, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:apex, "~> 1.0.0"}
    ]
  end
end
