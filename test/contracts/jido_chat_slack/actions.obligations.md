---
modules: [Jido.Chat.Slack.SendCard]
---
# Slack actions obligations

## Purpose

Define the current public Slack adapter boundary. Use fixed fixtures and recording
transports. Keep live success tests separate from this offline gate.

### jido_chat_slack.actions.I1 — Actions accept serialized native requests
- **scope:** All twenty native core Actions.
- **must:** Run serialized fixed request fixtures through Jido.Exec and validate each completion, result, trace, causal/request/client identity, and JSON round trip.
- **kind:** persisted-format
- **status:** active

### jido_chat_slack.actions.I2 — The Slack card is one native Action
- **scope:** SendCard through Chat.execute and Jido.Exec for two Clients.
- **must:** Preserve one fixed request/completion pair, Block Kit wire content, room/thread identity, and private per-client authorization.
- **kind:** functional
- **status:** active

### jido_chat_slack.actions.I3 — Failures expose no private provider context
- **scope:** Foreign requests, malformed envelopes, rejected requests, and network failure.
- **must:** Reject invalid input before I/O. Return stable safe failure categories and preserve trace and causation without raw provider details or credentials in Signals.
- **kind:** security
- **status:** active

### jido_chat_slack.actions.I4 — Core and Slack Actions compose in a native Flow
- **scope:** Dependent message and card steps.
- **must:** Complete both steps in order with separate causal identities. Stop after a failed dependency without a second provider write.
- **kind:** ordering
- **status:** active
