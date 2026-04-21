# Jido Chat Slack

`jido_chat_slack` is the Slack adapter package for `jido_chat`.

## Experimental Status

This package is experimental and pre-1.0. APIs and behavior will change.
It is part of the Elixir implementation aligned to the Vercel Chat SDK
([chat-sdk.dev/docs](https://www.chat-sdk.dev/docs)).

`Jido.Chat.Slack.Adapter` is the canonical adapter module and uses Slack's
HTTP APIs via `Req`.

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
config :jido_chat_slack, :slack_app_token, System.get_env("SLACK_APP_TOKEN")
```

## Live Integration Test

There is a live test module at:

- `test/jido/chat/slack/live_integration_test.exs`

It is excluded by default. To run it:

1. Copy and fill a local env file:

```bash
cp .env.example .env
```

2. Run:

```bash
mix test test/jido/chat/slack/live_integration_test.exs --include live
```

Current live coverage includes:

- send, fetch, edit, and delete
- metadata lookup
- stream fallback through core `Jido.Chat.Adapter.stream/4`
- reply continuity through Slack thread routing
- reaction add and remove
- local path upload and raw byte upload through `send_file/3`
- canonical single-file post through core `post_message/4`
- optional DM open and ephemeral post when `SLACK_TEST_USER_ID` is set

## Ingress Modes (`listener_child_specs/2`)

`Jido.Chat.Slack.Adapter.listener_child_specs/2` supports:

- `ingress.mode = "webhook"`: no listener workers (`{:ok, []}`), host HTTP handles
  Events API, Interactivity, and Slash Command ingress.
- `ingress.mode = "socket_mode"`: starts `SocketModeWorker`, opens Slack
  Socket Mode using an app-level token (`xapp-...`), acks envelopes, and emits
  payloads through `sink_mfa`.

Slack history fetches currently support backward pagination only. Passing
`direction: :forward` returns `{:error, :unsupported_direction}` instead of
silently ignoring the option.

For interaction responses, you can either:

- set `chat.metadata[:slack_response]` inside a slash/action/modal handler when
  using webhook ingress, or
- provide `response_builder` / `slack_response_builder` in webhook opts or
  Socket Mode ingress settings to build inline Slack response payloads.

Example:

```elixir
Jido.Chat.Slack.Adapter.listener_child_specs("bridge_slack",
  ingress: %{
    mode: "socket_mode",
    app_token: System.fetch_env!("SLACK_APP_TOKEN"),
    response_builder: fn %{sink_result: sink_result} ->
      case sink_result do
        {:reply, payload} -> payload
        _ -> nil
      end
    end
  },
  sink_mfa: {Jido.Messaging.IngressSink, :emit, [MyApp.Messaging, "bridge_slack"]}
)
```
