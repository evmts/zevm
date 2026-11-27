---
title: Formal Verification, Fuzzing & Conformance
tags: [lean4, fuzzing, conformance, testing, uphill]
---

# Formal Verification, Fuzzing & Conformance

See [[Overview]], [[Execution-Engine]], and [[Smithers-Factory-and-Trust]].

ZEVM combines formal methods, coverage-guided fuzzing, official Ethereum test fixtures, and continuous Lighthouse-style Uphill scoring.

## Lean 4 Reference Specification

- Lives under `spec/lean/` (`ZevmSpec`), built with `--wfail` in CI.
- CI executes an explicit Lean environment audit confirming **zero `sorry` and zero unproved `axiom` declarations** across all `ZevmSpec` modules.
- `tools/lean_diff_fuzz.zig` (`zig build diff-fuzz-lean -Doptimize=ReleaseSafe`) runs differential fuzzing comparing the compiled Lean 4 reference binary against Zig execution (verified at 140,000 cumulative cases with **0 divergences**).

## Coverage-Guided Fuzzing

- 14 property-based and native `std.testing.fuzz` suites (`src/fuzz/`, `tools/c_abi_fuzz_test.zig`, `src/safety_rpc_fuzz_test.zig`) covering ~30 targets across consensus, EVM execution, MPT/KZG proofs, JSON-RPC, Engine API, light client sync, CLI/config, and C ABI.
- Run deterministically everywhere via `zig build fuzz -Doptimize=ReleaseSafe` and live coverage-guided on Linux via `tools/fuzz_ubuntu.sh`.

## Official Ethereum Test Suites

- `zig build verify` runs fast unit/smoke checks plus `tools/abi_tests.zig`, `tools/trie_tests.zig`, and `tools/rlp_tests.zig` (55/55 RLP cases).
- `zig build transaction-tests` (`tools/transaction_tests.zig`) runs the pinned `TransactionTests` corpus.
- `zig build verify-early-state` (Frontier–Istanbul), `zig build verify-mid-forks` (491 Berlin + 585 Shanghai), and `zig build verify-latest-state` (19,527/19,732 Cancun = 99.0%, 17,767/17,992 Prague = 98.7%, regression-guarded by `tools/latest_fork_state_baseline.json`).
- `bun tools/hive_rpc_compat_smoke.js` validates full `ethereum/rpc-compat` transcripts.

## Continuous Lighthouse Backpressure

`.agents/uphill/uphill.yaml` scores 7 categories (`safety`, `style`, `footprint`, `verification`, `documentation`, `conformance`, `factory`) and `tools/audit_report.mjs` renders the interactive Lighthouse report published to `https://zevm.sh/docs/audit/`.
