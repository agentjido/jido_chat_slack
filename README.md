# Jido Chat Slack

`jido_chat_slack` is the Slack adapter package for `jido_chat`.

## Experimental Status

This package is experimental and pre-1.0. APIs and behavior will change.
It is part of the Elixir implementation aligned to the Vercel Chat SDK
([chat-sdk.dev/docs](https://www.chat-sdk.dev/docs)).

`Jido.Chat.Slack.Adapter` is the canonical adapter module and uses Slack's
HTTP APIs via `Req`.

`Jido.Chat.Slack.Channel` is kept as a compatibility wrapper for legacy
`Jido.Chat.Channel` integrations.

## Installation

```elixir
def deps do
  [
    {:jido_chat, github: "agentjido/jido_chat", branch: "main"},
    {:jido_chat_slack, github: "agentjido/jido_chat_slack", branch: "main"}
  ]
end
```

## Usage

```elixir
alias Jido.Chat.Slack.Adapter

{:ok, incoming} =
  Adapter.transform_incoming(%{
    "type" => "message",
    "channel" => "C123",
    "user" => "U456",
    "text" => "hello",
    "ts" => "1706745600.000100"
  })

{:ok, sent} =
  Adapter.send_message("C123", "hi",
    token: System.fetch_env!("SLACK_BOT_TOKEN")
  )
```

## Config

You can pass `:token` and `:signing_secret` per call, or configure globally:

```elixir
config :jido_chat_slack, :slack_bot_token, System.get_env("SLACK_BOT_TOKEN")
config :jido_chat_slack, :slack_signing_secret, System.get_env("SLACK_SIGNING_SECRET")
```

## Ingress Modes (`listener_child_specs/2`)

`Jido.Chat.Slack.Adapter.listener_child_specs/2` currently supports:

- `ingress.mode = "webhook"`: no listener workers (`{:ok, []}`), host HTTP handles
  Events API, Interactivity, and Slash Command ingress.

Socket Mode is intentionally not implemented in this package yet.
