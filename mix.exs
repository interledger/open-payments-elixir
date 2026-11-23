defmodule OpenPayments.MixProject do
  use Mix.Project

  @version "1.0.0"

  def project do
    [
      app: :open_payments_elixir,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: [
        check: [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "credo --strict",
          "test"
        ]
      ],
      description: "An Elixir client for the Open Payments APIs",
      package: [
        licenses: ["Apache-2.0"],
        files: ["lib", "priv", "mix.exs", "README.md", "LICENSE", "CHANGELOG.md"],
        links: %{"Source" => "https://github.com/interledger/open-payments-elixir"}
      ],
      source_url: "https://github.com/interledger/open-payments-elixir",
      dialyzer: [plt_add_apps: [:mix]],
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"],
        source_ref: "v#{@version}"
      ]
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  def application, do: [extra_applications: [:logger, :crypto, :public_key]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.7.5"},
      {:jason, "~> 1.4"},
      {:message_signatures, "~> 0.1.0"},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:plug, "~> 1.16", only: :test},
      {:bandit, "~> 1.6", only: :test}
    ]
  end
end
