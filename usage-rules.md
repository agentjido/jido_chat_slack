# Usage Rules for Jido Chat Slack

- Use immutable `Jido.Chat.Client` configuration and native request/result Signals.
- Use core Chat Actions. Find Slack extensions with `Jido.Chat.Slack.operations/0`.
- Use `Jido.Chat.Slack.Source` with the shared `Jido.Chat.Sensor` for Socket Mode.
- Let the host own process supervision, storage, retries, and reply Actions.
- The Source is receive-only. Its ACK confirms Sensor admission.
- Keep credentials in private Client configuration. Do not put them in Signals.
- Keep live API tests tagged `:live` and excluded by default.
- Do not commit `.env` or token values. Do not modify `CHANGELOG.md`.
- Keep Socket Mode optional. Outgoing requests use the Slack Web API.
