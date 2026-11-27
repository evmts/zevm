---
title: ZEVM Overview
tags: [overview, index, zevm, smithers]
---

# ZEVM Overview

ZEVM (`evmts/zevm`) is an embeddable Zig Ethereum execution and proof-backed light-client node built on pinned sibling sources of Voltaire (`evmts/voltaire`) and Guillotine Mini (`evmts/guillotine-mini`). It exposes one shared native core through a CLI binary, a C ABI (`include/zevm.h`), Node-API bindings (`@evmts/zevm` across 11 platforms), and a browser WebAssembly build.

## Runtime Modes

1. **Trusted mode** (`src/node/runtime.zig`): writable local dev and fork node with deterministic dev accounts, mining controls, transaction pool, snapshots, Hardhat `console.log` capture, ExEx event streams, and rebase fork following.
2. **Light mode** (`src/consensus_sync.zig`, `src/light_proof.zig`): proof-backed, consensus-anchored read-only client verifying beacon sync committees and Merkle Patricia Trie proofs before trusting remote RPC data.

Forking is a trusted-mode configuration, not a separate runtime mode.

## Wiki Map

- [[Architecture]]: layered Zig architecture, sibling dependency pins, and pluggable EVM backend seam
- [[Execution-Engine]]: transaction pipeline, block builder, state database, and hardfork schedule
- [[Fusaka-and-Osaka]]: Osaka/Fusaka EIPs, blob schedules, and Prague/Osaka genesis system contracts
- [[JSON-RPC-and-Engine-API]]: JSON-RPC dispatch, Engine API JWT auth, and Hive `rpc-compat` parity
- [[Beacon-Light-Client]]: sync-committee BLS verification, checkpoints, and MPT state proofs
- [[ExEx-and-Rebase-Fork]]: Execution Extensions event streams and upstream-following rebase forks
- [[Formal-Verification-and-Fuzzing]]: Lean 4 reference spec, 140k differential fuzz cases, and 30 Zig fuzz targets
- [[Native-Bindings-and-Releases]]: C ABI, N-API 11-platform matrix, WASM, and reproducible release tuples
- [[Smithers-Factory-and-Trust]]: Smithers Cloud factory, shared cache trust boundary, Lighthouse backpressure, and MCP auth
- [[Mythical-History]]: clean architectural evolution of ZEVM from initial prototype to native Zig 0.1.0

## Live Surfaces

- **Coding Factory:** https://smithers.sh/evmts/zevm
- **Public MCP Server:** https://smithers.sh/evmts/zevm/mcp
- **Documentation & `llms.txt`:** https://zevm.sh/docs and https://zevm.sh/docs/llms.txt
- **Lighthouse Backpressure Audit:** https://zevm.sh/docs/audit/
- **GitHub Mirror:** https://github.com/evmts/zevm
