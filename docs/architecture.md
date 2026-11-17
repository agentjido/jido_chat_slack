# Architecture

The package has four public boundaries:

- `Jido.Chat.Slack.Adapter` declares capabilities, executes core request Signals,
  and normalizes provider input.
- `Jido.Chat.Slack.Source` connects Socket Mode to the shared receive-only
  `Jido.Chat.Sensor`.
- `Jido.Chat.Slack.Webhook` verifies and decodes host-owned HTTP input.
- `Jido.Chat.Slack.Renderer` converts canonical cards, modals, and options to
  Slack Block Kit values.

`Jido.Chat.Client` contains the bot token, app token, signing secret, transport,
and private transport settings. Operations pass the bot token as an explicit
transport argument. Application environment lookup is not used.

The Source starts one linked `SocketModeWorker`. The worker owns the connection,
Slack envelope acknowledgements, and reconnect timing. It calls the shared
Sensor before it acknowledges an input envelope. It owns no room, message, or
identity state.

Jido Chat core owns Agent DSL integration, authorization, room processes,
durable declarations, membership, history, and storage adapters.
