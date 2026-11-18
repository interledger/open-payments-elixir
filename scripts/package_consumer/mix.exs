defmodule PackageConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :open_payments_package_consumer,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: [{:open_payments_elixir, path: "vendor/open_payments_elixir"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
