---
title: JSON-RPC & Engine API Contract
tags: [rpc, engine-api, hive, console-log]
---

# JSON-RPC & Engine API Contract

See [[Overview]], [[Execution-Engine]], and `docs/specs/json-rpc-contract.md`.

## Transport & Dispatch

- `src/rpc/server.zig` serves HTTP JSON-RPC (`8545`), WebSocket subscriptions, and the Engine API listener (`8551`) with HS256 JWT validation (accepting the Hive test JWT secret in fixture mode).
- `src/rpc/dispatcher.zig` and `src/rpc/dispatch_wiring.zig` route requests across:
  - Core reads (`src/rpc/handlers/eth_read.zig`, `src/rpc/handlers/block_spec.zig`)
  - Block, receipt, and log queries (`src/rpc/block_queries.zig`, `src/rpc/handlers/block_query_handlers.zig`)
  - Simulation & tracing (`src/rpc/handlers/simulation.zig`, `src/rpc/handlers/debug_raw.zig`)
  - Submission & txpool (`src/rpc/handlers/tx_submission.zig`, `src/rpc/handlers/txpool.zig`)
  - Fork & dev controls (`src/rpc/dev_runtime.zig`, `src/rpc/trusted_fork_handlers.zig`, `src/rpc/handlers/dev_erc20.zig`)
  - Fork metadata (`src/rpc/handlers/eth_config.zig`)

## Hardhat `console.log` Capture

`src/console_log.zig` intercepts calls to the canonical Hardhat console address during execution and exposes captured entries via `tevm_drainConsoleLogs`. Internal gas estimates inside `eth_sendTransaction`, `eth_signTransaction`, and `eth_createAccessList` suppress duplicate recording so every log appears exactly once.

## Hive `ethereum/rpc-compat` Parity

`tools/hive_rpc_compat_smoke.js` builds `tools/hive/zevm-client/` and runs the official `lib/execution-apis` `rpc-compat` transcripts against a real ZEVM container. Block responses strictly match the `execution-apis` `Block` schema (omitting extra `totalDifficulty` fields).
