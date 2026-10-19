# Jido Chat Slack

## V3 checkpoint

This branch requires the Jido v3 Chat API. All dependencies use Hex.
`jido_chat ~> 3.0.0-dev` is not published as of 2026-10-19.
Dependency resolution and tests remain blocked until a compatible release is available.
The lock file retains existing Hex entries; resolve it again after publication.

Slack provider for the stateless Jido Chat SDK. Clients contain configuration.
Client construction starts no process and makes no network request.

```elixir
client = Jido.Chat.Client.new!(Jido.Chat.Slack.Adapter,
  id: "support.slack",
  credentials: %{token: System.fetch_env!("SLACK_BOT_TOKEN")}
)

{:ok, completed} = Jido.Chat.send_text(client, room_id, "Hello")
message_id = completed.data["result"]["id"]

{:ok, delivery} = Jido.Chat.normalize(client, provider_input)
```

Chat requests, results, and incoming events are Jido Signals. Use
`Jido.Chat.operations(client)` and `Jido.Chat.event_definitions(client)` to build
host catalogs and routes. Core Chat Actions handle messages, files, reactions,
threads, users, history, ephemeral messages, modals, and option queries.
`Jido.Chat.Slack.SendCard` is the native Slack card Action. Its request definition
is `Jido.Chat.Slack.Signal.SendCard`. Use `Jido.Chat.Slack.operations/0` to find
Slack extensions. Old message and file structs and adapter helper APIs are removed.

See the [capability audit](guides/capabilities.md) for all 23 shared operations,
live evidence, permission limits, and Slack features that are not yet available.
See the [contract guide](guides/contracts.md) for Covenant and privacy limits.

Plain text disables Slack markup. Markdown uses Slack markup. Chat keyboards use
Block Kit buttons. HTML is unsupported. File keyboards and explicit plain/HTML caption formats return `unsupported`.
File input uses base64 content and a
filename, or a portable resource reference. The host must supply a private
`:file_resolver` function for upload references. The function receives the
reference and returns `{:ok, %{path: path, filename: filename}}` or
`{:ok, %{data: bytes, filename: filename}}`. File bytes and paths stay out of Signals. Downloads with the default transport
accept only HTTPS references on `files.slack.com`. Redirects to other hosts do
not carry the bot authorization header.

## Socket Mode input

The host owns the shared Sensor. `Jido.Chat.Slack.Source` starts a linked,
receive-only worker. It opens a Socket Mode connection, normalizes input, and
calls the shared Sensor. It sends a protocol ACK only after Sensor admission.
An ACK does not confirm storage or chat delivery. The worker sends no chat replies.
The worker reconnects with a fresh URL after disconnect and closes its socket on
shutdown. Use one Sensor per app token.

```elixir
client = Jido.Chat.Client.new!(Jido.Chat.Slack.Adapter,
  id: "support.slack",
  credentials: %{
    token: System.fetch_env!("SLACK_BOT_TOKEN"),
    app_token: System.fetch_env!("SLACK_APP_TOKEN")
  }
)

{:ok, sensor} = Jido.Chat.Sensor.start_link(
  client: client,
  source: Jido.Chat.Slack.Source,
  rooms: [System.fetch_env!("SLACK_TEST_CHANNEL_ID")],
  emit: "jido.chat.message.received",
  dispatch: {:pid, target: self()}
)
```

For an Agent with `Jido.Chat.Plugin`, add this connection inside its `chat` block:

```elixir
connection :slack do
  client Jido.Chat.Slack.Adapter,
    id: "support.slack",
    credentials: %{token: bot_token, app_token: app_token}

  rooms [slack_channel_id]
  commands [Jido.Chat.SendMessage, Jido.Chat.EditMessage, Jido.Chat.AddReaction]
  source Jido.Chat.Slack.Source, emit: "jido.chat.message.received"
end
```

The Plugin owns `Jido.Chat.Sensor`. Add an Agent route for each emitted fact type.
Route commands to `Jido.Chat.Plugin.Execute`. The reply Action builds and emits a
core Chat command Signal. No custom Sensor or runtime topology is needed.

Enable Socket Mode and subscribe to the required bot events in Slack app settings.
The app token needs `connections:write`. For channel message input, subscribe to
`message.channels`. The bot must have access to the selected channel. Credentials
and app permissions remain host configuration. Webhook hosts must verify
signatures before they call `Jido.Chat.normalize/3`.

Private Source options include `:connection_client`, `:socket_client`,
`:connection_options`, `:socket_options`, `:reconnect_interval` (1,000 ms),
`:max_reconnect_interval` (30,000 ms), and `:push_timeout` (2,000 ms).
Tests can replace the connection and socket clients without a network connection.

## Development

Use the local Chat and current Core packages:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix quality
mix test
mix test.contracts
mix coveralls
```

Default tests exclude `:live`. Live tests load `.env` and `.env.test`. Required
keys are `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, and `SLACK_TEST_CHANNEL_ID`.
The local environment can also contain `SLACK_TEST_USER_ID` and
`SLACK_SIGNING_SECRET`. Never commit credentials.

```sh
RUN_LIVE_SLACK_TESTS=true SLACK_TEST_WORKSPACE=ebosslabs mix test --include live
```

`SLACK_TEST_WORKSPACE` selects the workspace name checked with `auth.test` before
messages are sent. It defaults to `epicfirm`. The live suite tests message
operations, thread and history queries, DM opening, ephemeral API acceptance,
user/participant lookup, read cursor, upload/download, a card, Socket Mode admission, and an Agent Plugin reply.
Test messages are removed after each test. The optional download test needs
`SLACK_TEST_FILE_URL` and `SLACK_TEST_FILE_CONTENT`. File upload needs
`files:write`; message identity recovery and download need `files:read`. The approved
EBoss Labs installation has these scopes. The optional screen test needs
`RUN_LIVE_SLACK_UI_TESTS=true`; see the [test matrix](guides/test-matrix.md). See the
[capability audit](guides/capabilities.md) for the exact limits of these tests.
