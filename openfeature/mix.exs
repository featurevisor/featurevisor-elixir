defmodule FeaturevisorOpenFeature.MixProject do
  use Mix.Project

  @version "1.2.0"
  @source_url "https://github.com/featurevisor/featurevisor-elixir"

  def project do
    [
      app: :featurevisor_openfeature,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "OpenFeature provider for the Featurevisor Elixir SDK",
      package: package(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      featurevisor_dependency(),
      {:open_feature, "~> 0.1.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp featurevisor_dependency do
    case System.get_env("FEATUREVISOR_OPENFEATURE_PATH") do
      nil -> {:featurevisor, "== #{@version}"}
      path -> {:featurevisor, "== #{@version}", path: path}
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Featurevisor" => "https://featurevisor.com"},
      files: ["lib", "mix.exs", "README.md", "LICENSE"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "LICENSE"]
    ]
  end
end
