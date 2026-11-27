---
title: Execution Engine & State Database
tags: [execution, consensus, state, database]
---

# Execution Engine & State Database

See also [[Architecture]], [[Fusaka-and-Osaka]], and [[Formal-Verification-and-Fuzzing]].

## Core Pipeline

1. **Transaction Encoding & Validation (`src/transaction_encoding.zig`, `src/tx_processor.zig`):** decodes Legacy, EIP-2930, EIP-1559, EIP-4844 blob, and EIP-7702 authorization-list transactions. Enforces sender recovery, nonce, balance, intrinsic gas, EIP-7623 calldata floor, EIP-7825 per-tx gas limit cap, and EIP-7918 blob fee reserve before execution.
2. **State Database & Journaling (`src/database/database.zig`, `src/database/accounts.zig`, `src/database/contracts.zig`):** in-memory account, storage, and bytecode store with atomic checkpoint/revert snapshots, fork overlays, and storage-root computation (`src/mpt_proof.zig`).
3. **Host Adapter (`src/host_adapter.zig`):** bridges Guillotine Mini host callbacks (`SLOAD`, `SSTORE`, `BALANCE`, `EXTCODE*`, `TLOAD`/`TSTORE`, precompiles via `src/precompile_compat.zig`, and Hardhat `console.log` interception via `src/console_log.zig`).
4. **Block Builder & Mining (`src/block_builder.zig`, `src/mining_coordinator.zig`, `src/genesis.zig`, `src/genesis_alloc.zig`):** seals blocks with EIP-4895 withdrawals, EIP-4788 beacon root, EIP-2935 blockhash history, EIP-7002/7251 execution requests (`requests_hash`), bloom filters, receipt tries, and block-size caps (EIP-7934).
5. **Chain Import & Indexes (`src/chain_import.zig`, `src/receipt_index.zig`, `src/log_index.zig`, `src/txpool.zig`):** supports RLP block import (used by Hive and fixture verifiers), failure-atomic receipt/log indexing, and nonce-ordered mempool scheduling.

## Hardfork Activation

`src/hardfork_schedule.zig` defines per-network hardfork schedules (Mainnet, Sepolia, Holesky, Hoodi, Devnet) including BPO blob parameter schedules (EIP-7892). All consensus-critical paths are guarded in `github.protectedPaths` inside `.smithers/FACTORY.ts`.
