# Jido Chat Slack

[![Hex.pm](https://img.shields.io/hexpm/v/jido_chat_slack.svg)](https://hex.pm/packages/jido_chat_slack)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_chat_slack/)
[![CI](https://github.com/agentjido/jido_chat_slack/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_chat_slack/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_chat_slack.svg)](https://github.com/agentjido/jido_chat_slack/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

`jido_chat_slack` is the Slack adapter package for `jido_chat`.

## Release Status

This package is being prepared for the Jido 1.x chat package release line.
It is part of the Elixir implementation aligned to the Vercel Chat SDK
([chat-sdk.dev/docs](https://www.chat-sdk.dev/docs)).

`Jido.Chat.Slack.Adapter` is the canonical adapter module and uses Slack's
HTTP APIs via `Req`.

## Installation

```elixir
def deps do
  [
    {:jido_chat_slack, "~> 1.0"}
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

To route Slack API calls through a proxy or local-compatible endpoint, pass
`:base_url` at runtime:

```elixir
Adapter.send_message("C123", "hi",
  token: System.fetch_env!("SLACK_BOT_TOKEN"),
  base_url: "http://localhost:8081/api"
)
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

The Slack adapter ingress callback supports:

- `ingress.mode = "webhook"`: no listener workers (`{:ok, []}`), host HTTP handles
  Events API, Interactivity, and Slash Command ingress.
- `ingress.mode = "socket_mode"`: starts `SocketModeWorker`, opens Slack
  Socket Mode using an app-level token (`xapp-...`), acks envelopes, and emits
  payloads through `sink_mfa`.

Slack history fetches currently support backward pagination only. Passing
`direction: :forward` returns `{:error, :unsupported_direction}` instead of
silently ignoring the option.

## Resource Context and Read Receipts

The adapter supplies native Slack data for the core resource contracts:

- `get_user/2` returns normalized Slack profile data.
- `fetch_subject/2` uses the channel topic for a channel subject. When you pass
  `:external_thread_id`, `:thread_ts`, or `:message_id`, it returns the thread
  root text and permalink.
- `get_thread_participants/2` follows Slack reply cursors and returns unique
  canonical participants. `:limit`, `:page_size`, and `:max_pages` bound the
  work. The call returns `{:error, :participant_page_limit_exceeded}` instead
  of a partial result when `:max_pages` is reached.
- `mark_as_read/3` uses `conversations.mark`. Repeated calls are safe.

These calls require the related Slack token scopes. Slack provider errors are
returned without conversion.

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
