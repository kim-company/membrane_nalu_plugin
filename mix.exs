defmodule Membrane.NALU.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_nalu_plugin,
      version: "0.1.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: "https://github.com/kim-company/membrane_nalu_plugin",
      name: "Membrane NALU Plugin",
      description: description(),
      package: package()
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
      {:membrane_file_plugin, "~> 0.17", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["KIM Keep In Mind"],
      files: ~w(lib mix.exs README.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/kim-company/membrane_nalu_plugin"}
    ]
  end

  defp description do
    """
    NALU parser and aggregator for the Membrane Framework.
    """
  end
end
