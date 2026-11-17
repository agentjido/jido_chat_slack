---
title: Slack adapter Jido Chat V3 migration
type: implementation-plan
date: 2026-11-16
last_reviewed: 2026-11-16
artifact_contract: kata-plan/v1
artifact_readiness: completed
domain: software
execution: code
product_contract_source: approved-goal
---

# Slack Adapter Jido Chat V3 Migration

## Goal Capsule

- Objective: Migrate Slack to the current Jido Chat V3 Client, Signal,
  Adapter, and Sensor Source contracts without a V2 compatibility API.
- Means: Keep Slack Web API transport, rendering, signing, interaction, and
  Socket Mode protocol behavior; replace the V2 callback adapter and option
  structs with typed operation dispatch, deterministic normalization, a push
  Source, and explicit provider helpers.
- Authority: Local Slack package and local Jido Chat verification. No live
  Slack call, credential use, branch change, commit, push, release, or remote
  update.
- Stop conditions: Stop before provider I/O, a core provider branch, a second
  room/runtime tree, a compatibility API, or an unapproved remote action.

## Starting Evidence

- Local `main` is clean at `770be0f`. Its existing `origin/main` reference is
  two dependency-lock commits ahead. They update Dialyxir and git_ops only.
  This unit will not change the branch or contact GitHub. Dependency resolution
  will retain equivalent current versions in the migrated lock.
- The package selects Jido Chat `~> 1.2`, has a 2,485-line V2 adapter, eight
  option structs, application-environment credentials, V2 webhook envelopes,
  and a Messaging runtime ownership statement.
- Useful provider boundaries already exist: Req Web API transport, renderer,
  interaction-response builder, and a supervised Socket Mode worker.
- Normal tests exclude `:live`. No live Slack call is authorized.

## Product Contract

- **R1:** Select sibling `../jido_chat` and consolidated Jido V3 at
  `ec96da6015b4b1e5a1642d50651235d9d52808ec`.
- **R2:** `Jido.Chat.Slack.Adapter` implements only the current stateless
  adapter callbacks and an explicit native-or-unsupported operation map.
- **R3:** Bot and app tokens stay in `Client.credentials`. Provider endpoint,
  signing policy, bot identity, and Socket Mode policy stay in `Client.config`.
  Web API transport receives the bot token as a distinct argument.
- **R4:** Preserve native Slack operations for message and file work, metadata,
  threads, users, subjects, participants, read receipts, downloads, reactions,
  ephemeral messages, modals, options, history, thread lists, and direct rooms.
- **R5:** Normalize Slack messages, updates, deletes, reactions, slash commands,
  actions, modal events, and option requests into stable ordered V3 facts.
- **R6:** `Jido.Chat.Slack.Source` uses the shared push Sensor and the existing
  linked Socket Mode worker. It owns no room tree, queue, or storage.
- **R7:** Slack webhook signing and acknowledgement remain provider helpers.
  The host owns its HTTP endpoint and calls `Jido.Chat.normalize/2` for admitted
  payloads.
- **R8:** Keep the renderer and interaction response boundary when they preserve
  a provider rule. Remove V2 option structs, EventEnvelope/Incoming conversions,
  callback fallbacks, global credential lookup, and retired Messaging ownership.
- **R9:** Offline tests cover the Adapter Test Kit, operations, normalization,
  Source, Socket Mode, signing, rendering, and transport request shaping. Live
  tests stay tagged and excluded.
- **R10:** Tests, coverage, quality, docs, production compile, unused dependency,
  dependency tree, compile graph, source scan, diff check, and design review pass.

## Implementation Units

1. Select local Jido Chat V3 and refresh the dependency graph.
2. Make transport authentication explicit and replace V2 option structs with
   private operation data.
3. Add V3 Operations and deterministic Normalizer modules.
4. Add the push Source around Socket Mode and keep signing/response helpers as
   provider-owned utilities.
5. Replace the Adapter, remove compatibility code, and update tests and docs.
6. Run all offline gates and an Elixir design review, fix all supported
   findings, and repeat affected checks.

## Verification Contract

Run from `/Users/mhostetler/Source/Jido/jido_chat/jido_chat_slack`.

- `mix test` and contract tests make no live provider call.
- The local dependency tree uses sibling Jido Chat and exact consolidated Jido.
- No V2 callback, fallback capability, global token lookup, `Jido.Messaging`,
  or removed Jido Chat type remains.
- Required package checks and the final full design review pass.

## Definition of Done

- R1 through R10 have current evidence.
- The V3 adapter, operations, normalizer, Source, webhook helper, transport,
  tests, and documents are implemented.
- The design review found and fixed token-requiring local options, an unsafe
  download URL boundary, an invalid modal-trigger fallback, weak Socket Mode
  status redaction, a bot-participant failure, stale V2 option modules, and an
  unused permalink transport callback.
- `mix test` passes 28 offline tests with one live test excluded.
- Contract tests, compile with warnings as errors, Credo, Dialyzer, Doctor,
  coverage execution, and documentation checks pass.
- No live provider call or remote change occurred.
