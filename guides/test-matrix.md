# Slack test matrix

Audit: 2026-10-18, EBoss Labs, `#jido_chat_slack_testing`. This matrix separates
local contract evidence from successful provider calls. Credentials stay in
ignored files. Tests do not grant permissions.

## Shared operations

Every native row is in the fixed `operations.json` fixture. It runs through
`AdapterContractTest` test **every native operation uses the fixed wire sequence
and exact canonical result for two clients**, and `ActionsContractTest` test
**all native Actions execute serialized requests and preserve causal context**. See the
source files for the exact test names and literal obligation tags. Adapter I2
and Actions I1 cover these rows. Adapter I3 checks public facade helpers.

The following names identify tests in `test/jido/chat/slack/live_integration_test.exs`:

- **Lifecycle**: public Chat message lifecycle and thread continuity.
- **Queries**: thread queries and channel history return canonical results.
- **Users**: user lookup and read cursor enforce installed permissions.
- **Direct**: DM opening and ephemeral delivery use the configured test user.
- **Files**: file upload succeeds or reports the installed permission limit.
- **Modal**: a real button opens a modal and submission reaches the shared Sensor.

| Shared operation | Local evidence | Successful live evidence and limit |
| --- | --- | --- |
| send_message | Adapter I2/I3, Actions I1 | Lifecycle; exact ID/text and reply root; Sensor and Agent reply tests |
| edit_message | Same | Lifecycle; fetch confirms changed text |
| delete_message | Same | Lifecycle; exact lookup after deletion returns not_found |
| send_file | Same; bounded identity recovery in TransportMatrixTest | Files; external upload, exact shared-message timestamp and filename; cleanup deletes file |
| fetch_metadata | Same | Lifecycle; exact channel ID |
| fetch_thread | Same | Queries; exact root ID |
| fetch_message | Same | Lifecycle; exact root ID; Queries rejects ordinary reply lookup |
| get_user | Same | Users; exact bot user ID |
| fetch_subject | Same | Queries; room and thread subjects |
| get_thread_participants | Same | Users; observed scope, incomplete bounded scan |
| mark_as_read | Same | Users; bot read-cursor API acceptance |
| download_file | Same; URL/redirect checks | Files; normalize uploaded media, download its resource reference, compare exact bytes |
| add_reaction | Same | Lifecycle; add test reaction |
| remove_reaction | Same | Lifecycle; remove test reaction |
| post_ephemeral | Same | Direct; API acceptance, not proof of visible delivery |
| open_dm | Same | Direct; direct room ID, no DM message sent |
| fetch_messages | Same | Queries; backward history and cursor continuation; Agent test verifies reply ID in root thread |
| list_threads | Same | Queries; finds exact root on scanned page |
| open_modal | Same | Modal; fresh private trigger, returned view ID, real submission with matching ID and values |
| load_options | Same; Source I4 | Host function only. Local completion/response payload and time budget. No synchronous Source response path. |
| stream_text | Adapter I3 | Unsupported; local recording proves no provider call or stream read |
| start_typing | Adapter I3 | Unsupported; local recording proves no provider call |
| create_thread | Adapter I3 | Unsupported; local recording proves no provider call |

A provider call does not prove all optional fields, room types, or token types.
The optional private-download fixture test is separate from the upload/download
round trip. It is skipped when `SLACK_TEST_FILE_URL` is absent. The Modal test
needs `RUN_LIVE_SLACK_UI_TESTS=true` and a person or browser controller to click
**Open test form**, enter **Jido UI proof**, and submit before its timeout.

## Extension, facts, and lifecycle

| Area | Local evidence | Live evidence or missing proof |
| --- | --- | --- |
| SendCard, the only extension | Actions I2/I3/I4; Signals I1/I2; rendered payload/limits tests | public Slack card Action; simple card only |
| MessageReceived | Signals I3 | Socket Mode input reaches shared Sensor and produces a public Chat reply; Socket Mode input reaches the Agent Plugin and sends a Chat reply |
| ActionReceived, ModalSubmitted | Signals I3 | Modal test; real UI, exact message/view identity, JSON/catalog round trip without private trigger |
| MessageUpdated/Deleted, ReactionAdded/Removed | Signals I3 | Provider writes pass, but receipt of each separate fact is not asserted live |
| ModalClosed, OptionsRequested, SlashCommandReceived | Signals I3 | No live receipt proof. Commands need app configuration. Dynamic options need a synchronous response path. |
| AssistantThreadStarted/ContextChanged, MembershipChanged, NormalizationFailed | Signals I3 | No live success claim; fixed provider fixtures |
| Full-delivery failure, input forms, client identity | Signals I4 | Local malformed second-item test rejects partial success |
| Duplicate/filter/ACK order, timeout/reconnect, stale socket/death/shutdown | Source I1/I2/I3 | Local fault injection; live connection and reply only |
| Agent Plugin to shared Action | Source I5 | Live Agent reply; exact root and resulting message ID |
| Worker crash privacy | Source I6 | Controlled local crash with private frame, options, debug log and dictionary; see diagnostic limits in contracts guide |
| Webhook signature/deadline helper | Source I4 | Fixed local bytes/time; no deployed HTTP ingress proof |
| Error mapping, rate limits, upload partial failure | ProviderErrorsTest, TransportMatrixTest, Actions I3/I4 | No induced Slack rate limit, token rotation, or network outage |

## Gates and reports

`mix test.contracts` checks all 18 active obligations. The default suite excludes
live tests. `mix coveralls` checks production line coverage at 90% or more.
CI runs tests and Covenant. The capability guide records the latest measured
counts. Neither a green coverage report nor a native capability declaration
means that the full Slack API is supported.
