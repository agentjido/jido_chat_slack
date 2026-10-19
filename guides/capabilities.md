# Slack capability audit

Audit date: 2026-10-18. Scope: the current local `jido_chat` V3 contract,
this adapter, and live tests in EBoss Labs. This is not a claim that all Slack
APIs are available through this package.

## Assessment

The adapter declares 20 of the 23 shared operations as native. Local tests call
all 20 through the public Chat API and validate the result Signals against the
Client catalog. A test checks that this list matches the declared capabilities.
The other three operations return `unsupported` with outcome `not_attempted`.
Thus, the complete shared surface is accounted for, but it is not fully supported.
A native capability means that a provider path exists. It does not prove that
the installed token has permission, or that every optional field is supported.

The approved installation has `users:read`, `files:write`, `files:read`, and
`channels:manage`. It was reinstalled after user approval. The app token has
`connections:write`. Socket Mode, interactivity, and `message.channels` are enabled.
The live tests check exact message and file identity, catalog round trips, request
context, thread replies, users, participants, read cursor, and upload/download.
See [the test matrix](test-matrix.md) for test names and evidence for each row.

## Changes made during this audit

- Require exact timestamps for single-message lookup and return `not_found` for
  a missing message. An ordinary reply cannot return an older channel message.
- Apply ephemeral text formats. Reject unsupported HTML and file controls before I/O.
- Preserve history continuation and the provider thread-page `has_more` value.
- Resolve a file's message identity when upload completion omits share timestamps.
  Use at most three `files.info` calls, with 100 ms between retries. This path
  needs `files:read`. Failure after upload can mean the write succeeded; do not
  retry the full upload without checking the workspace.
- Use shared Signal definition rules for the Slack card extension, including
  private-value and JSON checks.
- Hide private Source data in OTP reports. Convert callback exceptions to a safe
  failure reason before they reach the parent. See [diagnostic limits](contracts.md).
- Enable peer, CA chain, SNI, and HTTPS hostname checks for Socket Mode by default.
- Add fixed-fixture contract tests, public facade/Exec/Flow checks, fault tests,
  a Covenant gate, and a traceable operation matrix.

Production line coverage is checked separately from contract and live coverage.
The Covenant gate requires all 18 active obligations to have passing evidence.
See [the contract guide](contracts.md) for fixed fixtures, stable IDs, and scope.

Live result: eight automatic tests pass. The separate UI test passes. Together,
they prove successful provider paths for 19 native core operations and the card
extension. The optional private-download fixture test is skipped because its URL
is absent; the upload/download round trip passes. `load_options` has local host
function and response-helper tests. Synchronous dynamic option replies remain a
gap. No scope rejection is counted as successful operation evidence.

Local result: 119 tests pass; 10 live tests are excluded by default. Production
line coverage is 92.3%, above the 90% gate. All 21 contract tests pass and cover
18 of 18 active obligations. Compilation with warnings as errors, formatting,
and whitespace checks pass. The full `mix quality` alias also passes, including
Dialyzer with zero errors and Doctor with zero failed modules. The local type
cache was rebuilt, and its application list now includes Jido and ExUnit.
Dependency builds on OTP 29 emit deprecated-catch
warnings from `yamerl`; the adapter compilation has no warnings.

## Shared operations

All native rows have local contract tests with a test transport. “Live” below
means an API response was checked in the approved test workspace.

| Operation | State | Live evidence and limits |
| --- | --- | --- |
| `send_message` | Native | Send, thread reply, and Agent reply pass. Plain text and Slack markup; keyboard payloads have local tests. |
| `edit_message` | Native | Edit a bot-owned message passes. Keyboard and format payloads have local tests. |
| `delete_message` | Native | Cleanup of test messages passes. Subject to Slack message ownership rules. |
| `send_file` | Native, partial fields | Upload and exact-byte download pass. Uses the external upload flow. Host file references need a private `file_resolver`. Explicit plain/HTML caption formats and keyboards return `unsupported`; they are not silently discarded. `media_kind` does not force a Slack display mode. |
| `fetch_metadata` | Native | Public test channel passes. Access depends on channel type and token permissions. |
| `fetch_thread` | Native | Existing root lookup passes. Thread ID is the root message timestamp. |
| `fetch_message` | Native, limited | Channel/root lookup passes. The shared request has no thread ID, so an ordinary thread reply is not available through this lookup. A live test confirms `not_found` rather than returning an older message. Use `fetch_messages` with the root thread ID for replies. |
| `get_user` | Native | Exact bot user lookup passes with `users:read`. |
| `fetch_subject` | Native | Channel and thread subjects pass. Thread subject uses its root text. |
| `get_thread_participants` | Native, observed only | Observed participants pass with `users:read`. Collects authors from a bounded scan, not a subscription/member list. Returns `scope: observed`, `complete: false`. |
| `mark_as_read` | Native | Channel API acceptance passes with `channels:manage`. Moves the token owner's read cursor; it is not a delivery/read receipt. |
| `download_file` | Native | Upload-to-receive-to-download passes with exact bytes. The separate optional fixture URL test is skipped. Needs access to the file and `files:read`. Default transport accepts only HTTPS URLs on `files.slack.com`. |
| `add_reaction` | Native | Adding a reaction passes. |
| `remove_reaction` | Native | Removing the test reaction passes. |
| `post_ephemeral` | Native | API acceptance passes for the configured test user. This does not prove that the user saw it. Plain format and HTML rejection have local tests. |
| `open_dm` | Native | DM opening passes with `im:write`. The test does not send a DM message. |
| `fetch_messages` | Native, backward only | Channel history, cursor continuation, and thread replies pass. Forward direction is rejected. No automatic full-history scan. |
| `list_threads` | Native, page scan | Finding the test root passes. Filters roots from one channel history page. Follow the returned cursor; it is not a complete workspace thread index. |
| `open_modal` | Native, host context required | Real button, modal opening, and submitted values pass through the shared Sensor. Requires a fresh Slack `trigger_id`, supplied through private execution options. A saved/artificial trigger does not prove live operation. |
| `load_options` | Native, host supplied | Local loader, completion, and response rendering tests only. Requires the host `options_loader`; no built-in data source. See the response-path limit below. |
| `stream_text` | Unsupported | Implementation gap. Slack has `chat.startStream`, `chat.appendStream`, and `chat.stopStream`. Thread and recipient rules must be mapped to the shared synchronous stream contract. |
| `start_typing` | Unsupported | Slack assistant status is a possible thread-scoped mapping. It is not yet connected to this operation. General room typing and assistant status need an explicit contract. |
| `create_thread` | Unsupported | Shared input is room plus name. Slack replies attach to an existing root. A future mapping could post a named root, but that side effect needs a defined contract and tests. Today use `send_message`, then reply to its ID. |

## Incoming events and response paths

Fourteen fact definitions are registered: message received/updated/deleted,
reaction added/removed, action received, modal submitted/closed, options requested,
slash command received, assistant thread started/context changed, membership
changed, and normalization failed. Fixtures test these mappings. Message
receipt has live Socket Mode and Agent proof. The UI test checks a button and
modal submission. These tests do not prove human mention or slash commands.

The shared `ThreadStarted`, `ThreadChanged`, and `ReceiptReceived` facts are not
emitted. A thread reply remains a message fact with a thread ID. Read cursor
updates do not supply portable user read receipts. Unsupported provider payloads
produce a normalization failure or no facts, as defined by the normalizer.

The Source acknowledges a Socket Mode envelope after shared Sensor admission.
It does not wait for the Agent to finish work and does not put an Action result
in the acknowledgement. This is suitable for asynchronous message processing.
It does not provide the synchronous payload needed for dynamic select options
or modal validation errors. The interaction response helpers exist, but a host
must wire them into an ingress path that can return the result before Slack's
response deadline. This is a functional gap for a complete interactive bot.

Source tests cover reconnect delay, failed admission without acknowledgement,
retries, duplicate handling through the Sensor, process death, and shutdown.
These are local fault tests. They do not prove delivery across a host crash,
long network outage, or token rotation. There is no durable event store here.

## Slack features beyond shared Chat

`Jido.Chat.Slack.SendCard` is the current extension Action. Cards support text,
sections, fields, images, links, buttons, selects, tables, and modal controls.
Charts use text fallback. Payload rendering and provider limits have local tests;
the live card test uses a simple title. It does not prove every control in Slack.
“Markdown” uses Slack markup, not a complete CommonMark conversion.

The package does not expose a general Slack Web API proxy. Other gaps include:

- Assistant streaming, status, suggested prompts, titles, and agent sessions.
- App Home publishing and view update/push flows.
- Channel discovery, creation, joins, invitations, topics, and membership management.
- Search, pins, bookmarks, scheduled messages, custom unfurls, and message metadata workflows.
- File listing/deletion, remote files, and shared file administration.
- Canvas, lists, workflows, calls, huddles, Slack Connect, and enterprise administration.

These are possible extension areas, not part of the minimum shared Chat contract.
No live success claim is made for private channels, group DMs, Slack Connect,
enterprise installations, user tokens, token rotation, rate-limit recovery, or
HTTP ingress deployed behind a real server. The live workspace is EBoss Labs,
not epicfirm. Rate-limit errors have local tests; sustained load does not.

## Work needed for full coverage

1. Define and implement `stream_text`, thread-scoped status/typing, and
   `create_thread`. Keep unsupported results until each mapping is explicit.
2. Add a synchronous interaction response path. Prove button, slash command,
   modal submission/validation, and external option selection with a real user.
3. Resolve reply lookup: extend the shared query with thread context, or provide
   a bounded provider lookup. Preserve exact message identity.
4. Add private channel and DM ingress tests, actual rate-limit tests, and recovery
   tests across a host restart. Add further Slack extension APIs as product needs arise.

## Repeat the checks

Use the published Hex dependencies. Keep credentials in
ignored `.env` files. Run from the Slack package:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix coveralls
mix test.contracts
RUN_LIVE_SLACK_TESTS=true SLACK_TEST_WORKSPACE=ebosslabs \
  mix test test/jido/chat/slack/live_integration_test.exs --include live
```

The live suite checks `auth.test` before writes. Configure `SLACK_TEST_USER_ID`
for DM opening and the ephemeral request. Without it, that test is skipped.
For download, set `SLACK_TEST_FILE_URL` and exact `SLACK_TEST_FILE_CONTENT`.
Without a URL, the separate download fixture test is skipped. The upload test
creates its own file, normalizes the received media, downloads exact bytes, and
removes the file. Without upload scopes, a permission branch checks rejection;
that branch is not counted as successful upload evidence. Ordinary test messages
are deleted. Ephemeral messages have no normal message deletion path. DM opening
can leave the conversation open. Tests do not grant new OAuth scopes.

Set `RUN_LIVE_SLACK_UI_TESTS=true` for the real button/modal test. A browser or
person must click **Open test form**, enter **Jido UI proof**, and submit within
the test timeout. Run it separately with `--only live_ui`. The default live run
skips this test. Do not run two Socket Mode suites against the same app token at
the same time; Slack can distribute envelopes across active connections.

## Provider references

- [Streaming methods](https://docs.slack.dev/reference/methods/chat.startStream/)
- [Assistant thread status](https://docs.slack.dev/reference/methods/assistant.threads.setStatus/)
- [Read cursor ownership and scopes](https://docs.slack.dev/reference/methods/conversations.mark/)
- [Thread replies and scopes](https://docs.slack.dev/reference/methods/conversations.replies/)
- [Ephemeral delivery limits](https://docs.slack.dev/reference/methods/chat.postEphemeral/)
- [Interaction response deadlines](https://docs.slack.dev/interactivity/handling-user-interaction/)
