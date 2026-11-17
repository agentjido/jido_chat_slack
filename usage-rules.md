# LLM Usage Rules for Jido Chat Slack

`jido_chat_slack` adapts Slack Web API, Events API, interactivity, and Socket
Mode behavior to the Jido Chat V3 contracts.

## Working Rules

- Build immutable `Jido.Chat.Client` values with explicit private credentials.
- Use request Signals and core Jido Chat Actions for outbound work.
- Normalize private provider input with `Jido.Chat.normalize/2`.
- Use `Jido.Chat.Slack.Source` with the shared `Jido.Chat.Sensor` for Socket Mode.
- Let the host own webhook HTTP, retries, reply logic, and supervision.
- Keep raw payloads and credentials out of public Signals.
- Keep live API tests tagged `:live` and excluded by default.
- Do not commit `.env` or token values.
- Keep Socket Mode optional; outbound calls remain Web API calls.
- Managed room runtime and durable storage belong in Jido Chat core.
- Do not restore V2 option structs or direct adapter send APIs.
- Run `mix test`, `mix quality`, and `mix coveralls` before release work.
