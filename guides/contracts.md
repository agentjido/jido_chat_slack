# Slack contract checks

Run `mix test.contracts` from this package. Covenant is a development and test
dependency with `runtime: false`. The alias runs `covenant.check`. CI runs this
check after the default tests. The check needs no Slack token or connection.

The contract has 18 active obligations in four components:

| Component | IDs | Test file |
| --- | --- | --- |
| Adapter | `jido_chat_slack.adapter.I1` through `I4` | `test/contracts/adapter_contract_test.exs` |
| Actions | `jido_chat_slack.actions.I1` through `I4` | `test/contracts/actions_contract_test.exs` |
| Signals | `jido_chat_slack.signals.I1` through `I4` | `test/contracts/signals_contract_test.exs` |
| Source | `jido_chat_slack.source.I1` through `I6` | `test/contracts/source_contract_test.exs` |

Each obligation has a literal `@tag obligation:` in its test. The Markdown
files in `test/contracts/jido_chat_slack/` are the reviewed requirements.
Covenant checks static tag coverage and executes the tagged tests to check
runtime evidence. Both must be 100%. Its coverage report is contract coverage;
it is not production line coverage. The separate `mix coveralls` gate requires
at least 90% production line coverage.

The fixed JSON files in `test/contracts/fixtures/` define the expected exports,
capabilities, incoming facts, requests, provider call order, and result fields.
They are authored separately from the implementation. Do not regenerate them
from the functions under test. The recording request module consumes each plan
once, checks the exact method and selected payload fields, and rejects extra
calls. Tests check that every expected call was used.

Adapter and Action tests cover all 20 native operations for two Client IDs.
They check public facade helpers, JSON/catalog round trips, client and request
identity, trace context, causation, shared Exec, and a two-step Flow. The three
unsupported operations must cause no provider call. An unsupported stream must
not read its input. Format, reference, and private-option failures have the same
no-call checks. The card extension has request/completed/failed schema checks.
All 14 registered fact families have fixed incoming fixtures.

Source checks use the real shared Sensor and Agent Plugin with a recording
socket. They check ACK order, room filters, duplicates, failed admission,
timeout, stale sockets, reconnect, socket death, and shutdown. One controlled
failure enables the OTP debug log, places private data in the last frame and
process dictionary, and raises an exception with private text. The worker must
stop with a safe category. Captured reports must omit that data. Signature
checks use fixed bytes and time. An options test checks the host response helper
and a local execution budget; it does not prove Slack's external deadline.

## Privacy boundary

Worker status reports replace state, last input, debug log, dictionary, and
non-atomic reasons. Worker callback exceptions become `source_failure` before
they reach the linked Sensor. The socket callback hides its state and converts
non-atomic disconnect reasons to `connection_failure`. Sensitive process flags
reduce automatic process details. TLS defaults check the peer certificate,
CA chain, SNI, and hostname, including the HTTPS wildcard rule.

WebSockex owns its outer status report, raw socket buffer, and telemetry events.
Its callback cannot remove the outer buffer or a host-enabled system debug log.
The dependency can emit raw frames and connection data through telemetry. Do
not send these fields to public logs. This package does not install a telemetry
handler or claim to redact arbitrary host tracing, `:sys` debugging, crash dumps,
or VM inspection. The local report test proves the worker boundary and socket
callback state; it does not prove all dependency diagnostics are free of private
data. A host that needs that stronger guarantee needs a reviewed socket driver
or a filter at the diagnostic sink.

## Live evidence

See [the test matrix](test-matrix.md) and [the capability audit](capabilities.md).
Live tests are separate from Covenant. A scope rejection, skipped fixture, local
recording transport, or rendered payload is not live success evidence.

## Full quality check

Run `mix quality` with the local dependency paths set. This runs format,
compilation, Credo, Dialyzer, and Doctor checks. The Slack Dialyzer configuration
includes `:jido` and `:ex_unit` in addition to `:mix`. Jido is a host-owned,
non-runtime dependency of Chat. The test build also compiles support modules
that call ExUnit. Both applications need type information in the test PLT.
Do not suppress missing-function warnings to replace that information. A stale
PLT that lists removed modules must be rebuilt in the adapter's local cache.
