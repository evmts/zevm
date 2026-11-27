---
title: ExEx & Rebase Fork
tags: [exex, rebase-fork, streaming, fork]
---

# ExEx & Rebase Fork

See [[Overview]] and [[Execution-Engine]].

## Execution Extensions (ExEx)

`src/exex.zig` implements typed, zero-overhead Execution Extension event streaming across both trusted and light modes:

- Typed `Event` union covering block lifecycle (committed/reverted), transaction pool admission, state changes, control-surface mutations, light-mode finalized header advances, and rebase lifecycle events.
- `EventIterator` and comptime node parameterization so downstream consumers (indexers, test harnesses, Smithers flows) subscribe without paying runtime overhead when disabled.

## Rebase Fork (`--fork-follow`)

`src/rebase_fork.zig` tracks live upstream heads while preserving local transactions and state mutations:

- Upstream head polling and reorg detection orchestrated in `src/rebase_fork.zig`.
- Transaction replay engine with access-list optimization to re-apply local transactions cleanly on top of new upstream blocks.
- Integrated with `zevm_reset`, `zevm_setRpcUrl`, `NodeMetadata`/`NodeInfo`, and ExEx rebase notifications.
- End-to-end verified by `src/exex_rebase_integration_test.zig`.
