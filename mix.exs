defmodule Jido.Chat.Slack.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_chat_slack"

  def project do
    [
      app: :jido_chat_slack,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        plt_add_apps: [:mix]
      ],
      name: "Jido Chat Slack",
      description: "Slack adapter package for Jido.Chat",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: [quality: :test, q: :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jido_chat, github: "agentjido/jido_chat", branch: "main"},
      {:req, "~> 0.5"},
      {:websockex, "~> 0.5.1"},
      {:jason, "~> 1.4"},
      {:dotenvy, "~> 1.1", only: [:test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test"
      ]
    ]
  end
end
