defmodule Shipyard.MixProject do
  use Mix.Project

  def project do
    [
      app: :shipyard,
      version: "0.1.0",
      elixir: "~> 1.20",
      # Temporary: the worker's VM ends through Shipyard.Application.stop/1,
      # not as a permanent application's crash.
      start_permanent: false,
      deps: [],
      aliases: [
        # The whole gate (`bin/shipyard check`).
        check: [
          "compile --warnings-as-errors --force",
          "format --check-formatted",
          "test --warnings-as-errors"
        ]
      ]
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  def application do
    [extra_applications: [:logger], mod: {Shipyard.Application, []}]
  end
end
