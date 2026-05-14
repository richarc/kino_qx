defmodule Kino.Qx.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/richarc/kino_qx"

  def project do
    [
      app: :kino_qx,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Kino.Qx",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Kino.Qx.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime
      {:kino, "~> 0.19"},
      {:qx, path: "../qx"},
      {:req, "~> 0.5"},
      # Jason arrives transitively via Kino, but pin explicitly so the
      # smart cell's encode/decode behaviour can't drift if Kino
      # internals change.
      {:jason, "~> 1.4"},
      # Dev/test
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Livebook Smart Cells for the Qx Portal. Browse and inject saved
    OpenQASM / Elixir snippets into a notebook, OR transpile an
    OpenQASM 3.0 circuit via the portal and submit it to IBM Quantum
    directly — measurement counts render inline.
    """
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      maintainers: ["Craig Richards"],
      links: %{
        "GitHub" => @source_url,
        "Portal" => "https://qxportal.dev"
      },
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
