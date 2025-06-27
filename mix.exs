defmodule Membrane.NALU.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_nalu_plugin,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:membrane_core, "~> 1.2"},
      {:membrane_file_plugin, "~> 0.17", only: :test}
    ]
  end
end
