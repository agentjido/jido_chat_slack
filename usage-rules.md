# LLM Usage Rules for Jido Chat Slack

`jido_chat_slack` adapts Slack Web API, Events API, interactivity, and Socket
Mode behavior to the `Jido.Chat.Adapter` contract.

## Working Rules

- Keep shared chat behavior in `Jido.Chat.Adapter` callbacks.
- Keep live API tests tagged `:live` and excluded by default.
- Do not commit `.env` or token values.
- Keep Socket Mode optional; outbound calls remain Web API calls.
- Preserve the adapter boundary; runtime supervision belongs in `jido_messaging`.
- Run `mix test`, `mix quality`, and `mix coveralls` before release work.
