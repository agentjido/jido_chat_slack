# Slack contracts

Run `mix test.contracts`. See [the contract guide](../../guides/contracts.md) for
18 stable obligation IDs, the fixed fixture rules, no-call checks, privacy limits,
and the difference between contract coverage and production line coverage.

The four `*_contract_test.exs` files contain 21 tests. Keep literal obligation
tags when a test moves. Change an obligation and its fixed fixture only after a
review of the public contract. Do not derive expected values from production
capability declarations or renderers.
