---
modules: [Jido.Chat.Slack.Source, Jido.Chat.Slack.InteractionResponse]
---
# Slack source obligations

## Purpose

Define the current public Slack adapter boundary. Use fixed fixtures and recording
transports. Keep live success tests separate from this offline gate.

### jido_chat_slack.source.I1 — The Source is receive-only and privately keyed
- **scope:** Source discovery, credentials, source ownership, and missing app token.
- **must:** Declare push mode and only admitted facts. Hash the app token for source ownership. Reject a missing token and perform no outbound Chat operation.
- **kind:** security
- **status:** active

### jido_chat_slack.source.I2 — Acknowledgement follows admission
- **scope:** Socket frames, shared Sensor admission, duplicate deliveries, and room filtering.
- **must:** Emit one canonical fact through the shared Sensor and then acknowledge the envelope. Suppress duplicate facts. Filtered rooms can be acknowledged without dispatch. Never put private response handles in the ACK.
- **kind:** ordering
- **status:** active

### jido_chat_slack.source.I3 — Failed admission and sessions have bounded recovery
- **scope:** Rejected or timed-out admission, disconnect, stale sessions, socket death, and shutdown.
- **must:** Do not acknowledge rejected or timed-out input. Reconnect with a fresh connection after failure and ignore old socket frames. Close the socket and stop the worker when its owner stops.
- **kind:** ordering
- **status:** active

### jido_chat_slack.source.I4 — Protocol responses have an explicit host boundary
- **scope:** Options, response payload support, signatures, and response deadlines.
- **must:** Render option completion only through explicit response helpers when the envelope allows it. Verify exact signed bytes and reject stale or altered requests. The receive-only Source ACK must not claim synchronous Action completion.
- **kind:** security
- **status:** active

### jido_chat_slack.source.I5 — An Agent can reply through the same shared Action boundary
- **scope:** Source to Sensor to Agent Plugin to shared SendMessage to Slack transport.
- **must:** Admit a fixed input, route it through the real Plugin, execute the shared Action, preserve room and reply identity, and record exactly one provider reply. Stop test-owned workers.
- **kind:** ordering
- **status:** active

### jido_chat_slack.source.I6 — OTP reports omit private worker data
- **scope:** Source status, last input frames, exception details, and socket callback state.
- **must:** Replace private state, raw input messages, debug logs, and non-atomic failure reasons in Source OTP reports. Omit socket callback state and process dictionaries. Verify a controlled failure with private frame and exception values. Preserve a safe failure category. Do not claim that the dependency's raw socket buffer or host telemetry is public-safe.
- **kind:** security
- **status:** active
