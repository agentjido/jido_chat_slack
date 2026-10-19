---
modules: [Jido.Chat.Slack.Signal.SendCard, Jido.Chat.Slack.Normalizer]
---
# Slack signals obligations

## Purpose

Define the current public Slack adapter boundary. Use fixed fixtures and recording
transports. Keep live success tests separate from this offline gate.

### jido_chat_slack.signals.I1 — Extension identities and request shape are fixed
- **scope:** Card request, completion, failure, and schema.
- **must:** Preserve literal type and dataschema identities. Admit only the declared card request fields.
- **kind:** persisted-format
- **status:** active

### jido_chat_slack.signals.I2 — Chat policy keeps private values out of public Signals
- **scope:** Chat policy construction and admission: card content, runtime handles, secrets, and constructor context.
- **must:** Reject nested private data, process handles, unknown envelope fields, and identity overrides. Valid card requests must round trip through the Client catalog.
- **kind:** security
- **status:** active

### jido_chat_slack.signals.I3 — All admitted incoming facts use safe canonical fields
- **scope:** Fourteen incoming fact families.
- **must:** Match independent fixed provider fixtures. Preserve source, delivery, item, and room subject identity. Exclude private trigger, response URL, and credentials from public facts.
- **kind:** functional
- **status:** active

### jido_chat_slack.signals.I4 — Complete normalization is stable and isolated
- **scope:** Webhook, JSON, form, host wrapper, Socket Mode, multiple Clients, and partial failure.
- **must:** Keep stable item identities across input forms. Scope source and subject to the Client. Reject an invalid full delivery and never return partial success after a fatal limit failure.
- **kind:** ordering
- **status:** active
