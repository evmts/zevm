---
title: ZEVM Mythical History
tags: [history, mythical, epics, architecture]
---

# ZEVM Mythical History

Back to [[Overview]]. Machine-readable epic index: `.smithers/history/epics.json`.

A mythical history tells the clean, linear story of how ZEVM would be built from scratch today: atomic architectural milestones, specs before code, and every subsystem grounded in verified tests.

## Epic 1: Pinned Native Foundation & Build Graph
- Establish Zig `0.15.2` workspace (`build.zig`, `build.zig.zon`) over pinned sibling checkouts of `evmts/voltaire` and `evmts/guillotine-mini` (`native-dependencies.json`).
- Add deterministic native dependency preflight (`tools/dependency_preflight.zig`) and source-digest keying (`tools/native_deps_digest.mjs`).

## Epic 2: Trusted Execution Engine & State Database
- Build `src/database/` (accounts, contracts, atomic snapshots), `src/evm_backend.zig` (pluggable EVM seam), `src/host_adapter.zig`, `src/tx_processor.zig`, `src/block_builder.zig`, `src/mining_coordinator.zig`, and `src/txpool.zig`.
- Replace EthereumJS and all owned TypeScript with the single native Zig execution core (`d5387120`).

## Epic 3: Canonical JSON-RPC, Engine API & Dev Ergonomics
- Implement spec-driven HTTP/WS JSON-RPC and JWT-authenticated Engine API (`src/rpc/`, `docs/specs/json-rpc-contract.md`).
- Add Hardhat `console.log` capture (`src/console_log.zig`) and verify full Hive `ethereum/rpc-compat` parity (`tools/hive_rpc_compat_smoke.js`).

## Epic 4: Beacon Light Client & Cryptographic Proof Verification
- Implement sync-committee BLS verification (`src/consensus_verifier.zig`, `src/consensus_sync.zig`), MPT proof checking (`src/mpt_proof.zig`, `src/light_proof.zig`), and baked checkpoints for Mainnet, Sepolia, Holesky, and Hoodi (`src/light_default_checkpoints.zig`).

## Epic 5: Prague, Osaka & Fusaka Readiness
- Implement EIP-7825, EIP-7892, EIP-7910 (`eth_config`), EIP-7918, EIP-7934, EIP-7951 (`P256VERIFY`), EIP-7594 PeerDAS v1, and canonical genesis system contracts (EIP-4788, 2935, 7002, 7251) with `requests_hash`.

## Epic 6: Formal Lean 4 Spec, Fuzzing & Official Ethereum Conformance
- Author zero-sorry Lean 4 reference spec (`spec/lean/`) and run 140,000-case differential fuzzing (`tools/lean_diff_fuzz.zig`) with 0 divergences.
- Ship 14 property/fuzz suites (~30 `std.testing.fuzz` targets) plus `ABITests`, `RLPTests`, `TrieTests`, `TransactionTests`, early/mid/latest `GeneralStateTests`, and 5-round multi-model audit remediation.

## Epic 7: ExEx Event Streams & Rebase Fork
- Implement comptime-parameterized Execution Extensions (`src/exex.zig`) and live upstream-following rebase forks (`src/rebase_fork.zig`) with end-to-end integration tests (`src/exex_rebase_integration_test.zig`).

## Epic 8: Native Distribution & Smithers Cloud Coding Factory
- Package C ABI (`include/zevm.h`), 11-platform Node-API (`@evmts/zevm`), browser WASM (`src/browser.zig`), reproducible release metadata (`src/release_metadata.zig`), automated `zevm.sh` + `llms.txt` publishing, Uphill Lighthouse backpressure UI, Obsidian wiki, and personalized Smithers Cloud factory (`.smithers/FACTORY.ts`).
