defmodule DarkChonkyWhale.MixProject do
  use Mix.Project

  def project do
    [
      app: :dark_chonky_whale,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {DarkChonkyWhale.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Framework
      {:dexterous, github: "GES233/Dexterous", sparse: "apps/dexterous", override: true},
      {:dexterous_loader, github: "GES233/Dexterous", sparse: "apps/dexterous_loader"},
      {:dexterous_hmr, github: "GES233/Dexterous", sparse: "apps/dexterous_hmr"},

      # LLM Support
      {:req_llm, "~> 1.6"},

      # Serialization
      {:jason, "~> 1.4"},

      # Legacy codepage transcoding (GBK, Shift-JIS, …) for shell output
      {:codepagex, "~> 0.1"}
    ]
  end
end
