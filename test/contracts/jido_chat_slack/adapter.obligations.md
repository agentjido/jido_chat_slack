---
modules: [Jido.Chat.Slack, Jido.Chat.Slack.Adapter]
---
# Slack adapter obligations

## Purpose

Define the current public Slack adapter boundary. Use fixed fixtures and recording
transports. Keep live success tests separate from this offline gate.

### jido_chat_slack.adapter.I1 — Discovery is explicit and stateless
- **scope:** Public exports, 23 capabilities, extension pairs, admitted facts, and application metadata.
- **must:** Preserve the reviewed public exports, exactly twenty native and three unsupported core operations, one card Action, and fourteen admitted facts. Discovery and Client construction make no provider call. Start no adapter application process.
- **kind:** functional
- **status:** active

### jido_chat_slack.adapter.I2 — Native operations preserve the provider boundary
- **scope:** All twenty native core operations and two Client identities.
- **must:** Use each fixed request, provider method sequence, and canonical result fixture. Validate completion, client/request identity, trace, and causation through the public Chat API. Keep credentials isolated.
- **kind:** ordering
- **status:** active

### jido_chat_slack.adapter.I3 — Facade helpers use shared Actions
- **scope:** All available facade helpers, stream sources, typing, and thread creation.
- **must:** Execute supported helpers through their shared Action. Reject unsupported helpers without reading streams or provider I/O. Preserve portable file content and exact identifiers.
- **kind:** functional
- **status:** active

### jido_chat_slack.adapter.I4 — Invalid and unsupported content has no side effect
- **scope:** Formats, private facade options, client-scoped resources, and file controls.
- **must:** Reject unsupported formats and file controls, foreign resources, and unknown facade options before transport I/O. Do not silently discard unsupported content.
- **kind:** security
- **status:** active
