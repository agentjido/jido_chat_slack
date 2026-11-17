# Validation

The default suite is provider-free. It checks:

- capability and unsupported-operation contracts;
- canonical operation results and explicit credential flow;
- Events API, interactivity, modal, option, and slash command normalization;
- webhook signature and request decoding;
- Socket Mode admission before acknowledgement;
- Slack Web API request shape and error mapping;
- card, modal, and option rendering.

Run:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix test.contracts
mix quality
mix coveralls
```

Live checks are separate and excluded by default. They require a disposable
Slack channel and explicit environment credentials.
