# ZEVM - Zig Ethereum Virtual Machine

## Overview

ZEVM is a Zig Ethereum client shipped as one binary with two explicit runtime modes:

1. **Light mode** - sync consensus from the Beacon chain and serve proof-verified, read-only execution data.
2. **Trusted mode** - run a Hardhat/Anvil-style development node with local execution, local mutation, and optional RPC fork backing.

Forking is configuration inside trusted mode, not a third product mode.

## Product Goal

ZEVM should be a thin integration shell that composes our existing Ethereum libraries into:

- a trust-minimized read client for verified execution-state reads
- a fast trusted dev node for local testing, scripting, and forked development

The product should not duplicate EVM, state-manager, or JSON-RPC method-model ownership that already exists in sibling libraries we control.

## Architecture

ZEVM is a **thin integration layer** on top of two upstream libraries we own:

- **voltaire** (`../voltaire`) - Ethereum primitives, JSON-RPC types, state manager, journal/snapshot support, fork backend, blockchain, crypto, and other execution-layer foundations
- **guillotine-mini** (`../bench/guillotine-mini`) - EVM interpreter, tracing substrate, and execution host integration

ZEVM owns:

- CLI/config parsing and mode selection
- runtime composition and lifecycle
- HTTP JSON-RPC transport
- mode-aware request routing and method gating
- startup, shutdown, checkpoint wiring, and readiness reporting

ZEVM does **not** own:

- a second execution-state abstraction layered on top of Voltaire
- a second canonical JSON-RPC method model if Voltaire already owns it
- a second EVM or tracing implementation

If a required capability is missing upstream, add it upstream rather than rebuilding it in ZEVM.

## Runtime Model

ZEVM should expose one configuration surface with an explicit mode sum type:

- `mode.light: LightOptions`
- `mode.trusted: TrustedOptions`

`TrustedOptions` may include optional fork configuration. Forking is still trusted mode.

The runtime should be assembled once at startup into a mode-specific runtime/handler graph. Unsupported methods must fail deterministically based on mode, rather than being partially wired and failing later in execution.

## Mode Contracts

### Light Mode

Light mode is a read-only product surface.

- Sync consensus via the Beacon chain and persist checkpoint progress.
- Serve execution reads only when backed by proofs validated against a synced execution root.
- Initial light-mode RPC scope is proof-backed reads plus readiness/sync status.
- `safe` and `finalized` semantics must come from consensus sync, not local placeholders.

Light mode does **not** support:

- `eth_call`
- `eth_estimateGas`
- transaction submission
- mining
- snapshots/revert
- state mutation
- impersonation
- filters/subscriptions
- WebSocket transport

Proof-backed `eth_call` is explicitly deferred until there is a clear verified execution story for transient call state.

### Trusted Mode

Trusted mode is the full dev-node product surface.

- Default startup creates a deterministic local dev chain with managed development accounts.
- Optional fork configuration reads from a remote RPC source through Voltaire's fork backend.
- Reads resolve local overlay first and then remote fork state when a fork source is configured.
- All writes, mining, snapshots, impersonation, and time controls affect only local trusted-mode state.
- Trusted mode does not attempt proof verification.

## State, Fork, and Snapshot Semantics

Trusted mode must use Voltaire's state-manager stack as its only execution-state foundation.

- Use upstream `StateManager`, journal/snapshot support, `ForkBackend`, and `Blockchain`.
- Do not introduce a second ZEVM-owned journaled state abstraction.
- Local overlays on forked state live in trusted mode and remain local-only.

Snapshot/revert exists only in trusted mode.

A trusted-mode snapshot captures the mutable local execution shell:

- state journal checkpoint / local overlay
- canonical local chain head
- receipt and log indexes derived from local canonical blocks
- pending txpool state
- mining configuration and block-environment overrides
- impersonation state
- time controls

A snapshot does **not** capture:

- consensus or checkpoint-sync state
- the remote fork source itself

Implementation preference: restore state through upstream checkpoint/revert primitives plus deterministic restoration of ZEVM-owned metadata, not by deep-copying the entire node state in ZEVM.

## Delivery Priorities

### Phase 1 - Trusted Mode MVP

Build a runnable trusted node first. This is the shortest path to a usable product and the right place to stabilize runtime ownership.

Required in phase 1:

1. **Runnable startup and mode selection**
   - One binary
   - Default startup enters trusted mode
   - Invalid mode/flag combinations fail deterministically

2. **HTTP JSON-RPC transport**
   - Configurable listener (default `8545`)
   - JSON-RPC 2.0 request/response handling
   - batch requests
   - notifications
   - correct standard error mapping
   - one canonical shipping transport/parser stack

3. **Core trusted-mode reads**
   - `eth_chainId`
   - `eth_blockNumber`
   - `eth_getBalance`
   - `eth_getCode`
   - `eth_getStorageAt`
   - `eth_getTransactionCount`
   - `eth_gasPrice`
   - `eth_coinbase`
   - `eth_accounts`
   - `eth_maxPriorityFeePerGas`
   - `eth_blobBaseFee`
   - `eth_feeHistory`

4. **Trusted-mode execution simulation**
   - `eth_call`
   - `eth_estimateGas`
   - checkpoint/revert execution semantics
   - state overrides

5. **Transaction submission and mining**
   - `eth_sendTransaction`
   - `eth_sendRawTransaction`
   - nonce-ordered pending pool
   - automine
   - manual mining
   - interval mining

6. **Canonical query surface**
   - `eth_getBlockByNumber`
   - `eth_getBlockByHash`
   - `eth_getTransactionByHash`
   - `eth_getTransactionReceipt`
   - `eth_getBlockReceipts`
   - `eth_getLogs`

7. **Trusted-mode dev controls**
   - `evm_snapshot`
   - `evm_revert`
   - Hardhat/Anvil-compatible state mutation methods
   - impersonation
   - time controls
   - trusted-mode fork startup via remote RPC

### Phase 2 - Light Mode Verified Reads

After trusted-mode runtime ownership is stable, expose the light-client product surface.

Required in phase 2:

- startup/config for network selection and checkpoint persistence
- bootstrapping, resume, and sync advancement
- readiness/sync-status reporting
- proof acquisition for account, storage, code, and nonce reads
- proof-backed implementations of core read methods
- explicit safe failure on stale checkpoints, invalid proofs, and malformed upstream responses

### Phase 3 - Advanced Tooling

Only after trusted-mode canonical execution and light-mode verified reads are stable:

- debug tracing (`debug_traceCall`, `debug_traceTransaction`)
- filter lifecycle APIs
- WebSocket transport and subscriptions

Tracing, filters, and subscriptions should not ship ahead of canonical block, receipt, log, and snapshot correctness.

## Target Feature Parity

ZEVM aims for parity with:

- **Hardhat EDR** (edr/) - trusted dev-node behavior, mining controls, snapshots, impersonation, tracing
- **Foundry Anvil** (foundry/) - fast forkable dev node
- **TEVM** (../tevm-monorepo) - trusted client behavior across `eth`, `anvil`, and `debug` handlers
- **Helios** - light-client sync plus proof-verified reads

## What's Already Done

### Consensus Layer

- BLS12-381 signature verification
- SSZ Merkle proof validation
- Beacon API client (bootstrap, updates, finality)
- consensus sync engine (bootstrap -> sync -> advance)
- checkpoint file persistence
- network configs (mainnet, sepolia, holesky)

### Execution Layer

- transaction processing with gas accounting
- block building with receipt generation
- state management with journaling
- Merkle Patricia Trie support for state-root computation
- contract code deduplication groundwork
- host adapter bridging Voltaire state to `guillotine-mini`

## Explicit Non-Goals For The First Delivery

- No third standalone "fork mode"
- No light-mode transaction sending or local mutation
- No proof-backed `eth_call` in the first light-mode delivery
- No WebSocket/subscription surface before the canonical HTTP execution surface is correct
- No ZEVM-local replacement for upstream state-manager or EVM ownership

## Zig Style Rules

- No local type aliases (`const Foo = bar.Foo` is banned). Always use fully qualified paths.
- No stored allocators. Pass allocator explicitly to methods that need it.
- Zig 0.15 with lowercase `@typeInfo` variants (`.int`, `.bool`, `.float`).
