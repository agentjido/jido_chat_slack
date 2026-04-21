# AGENTS.md - Jido Chat Slack Development Guide

`jido_chat_slack` is the Slack adapter for `Jido.Chat`.

## Commands

- `mix setup` - Fetch dependencies.
- `mix test` - Run the default non-live test suite.
- `mix test --include live` - Run explicitly enabled live Slack tests.
- `mix quality` - Run the Jido package quality gate.
- `mix coveralls` - Run coverage.
- `mix install_hooks` - Explicitly install local git hooks.

## Rules

- Keep live Slack tests excluded by default with the `:live` tag.
- Do not commit `.env` or credentials.
- Keep Socket Mode ingress optional and adapter-scoped.
- Preserve the adapter boundary; supervised runtime concerns belong in `jido_messaging`.
