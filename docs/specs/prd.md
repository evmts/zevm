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

ZEVM is a thin integration layer on top of two upstream libraries we own:

- `voltaire` (`../voltaire`) - Ethereum primitives, JSON-RPC types, state manager, journal/snapshot support, fork backend, blockchain, crypto, and other execution-layer foundations
- `guillotine-mini` (`../bench/guillotine-mini`) - EVM interpreter, tracing substrate, and execution host integration

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

## Docs-First Requirement

ZEVM is specified docs-first.

The PRD and supporting docs must define the full product contract, including:

- exact startup flags
- exact config-file fields
- defaults
- precedence
- invalid combinations
- notification behavior
- supported block tags
- mode-specific method availability
- startup and runtime error behavior

Do not preserve a “conceptual only” posture for startup, configuration, or transport surfaces. Those surfaces are part of the product contract and must be specified exactly even when `HEAD` is still incomplete.

## Runtime Model

ZEVM exposes one configuration surface with an explicit mode sum type:

- `mode.light: LightOptions`
- `mode.trusted: TrustedOptions`

`TrustedOptions` may include optional fork configuration. Forking is still trusted mode.

The runtime is assembled once at startup into a mode-specific runtime/handler graph. Unsupported methods must fail deterministically based on mode rather than being partially wired and failing later in execution.

## Startup And Configuration Contract

ZEVM ships one binary, `zevm`.

Default startup enters trusted mode. Light mode is selected explicitly.

### Shared CLI Contract

| Flag | Value | Default | Applies to | Notes |
| --- | --- | --- | --- | --- |
| `--config` | path to JSON config file | none | both | Optional. ZEVM loads the config file before applying CLI overrides. |
| `--mode` | `trusted` or `light` | `trusted` | both | Selects the active runtime mode. |
| `--host` | bind host | `127.0.0.1` | both | HTTP listener bind host. |
| `--port` | TCP port | `8545` | both | HTTP listener bind port. |

### Trusted-Mode CLI Contract

| Flag | Value | Default |
| --- | --- | --- |
| `--chain-id` | `u64` | `31337` |
| `--coinbase-index` | integer `0..9` | `0` |
| `--initial-balance` | wei, decimal string | `10000000000000000000000` |
| `--gas-price` | wei, decimal string | `2000000000` |
| `--base-fee` | wei, decimal string | `1000000000` |
| `--blob-base-fee` | wei, decimal string | `1` |
| `--max-priority-fee-per-gas` | wei, decimal string | `1000000000` |
| `--block-gas-limit` | `u64` | `30000000` |
| `--mining` | `auto`, `manual`, or `interval` | `auto` |
| `--block-time` | seconds | none |
| `--fork-url` | HTTP(S) execution RPC URL | none |
| `--fork-block-number` | `u64` | none |

Trusted-mode rules:

- `--block-time` is required when `--mining interval` is selected.
- `--block-time` is invalid with `--mining auto` or `--mining manual`.
- `--fork-block-number` is invalid without `--fork-url`.
- trusted-mode flags are invalid when `--mode light` is active
- `--fork-url` does not implicitly change `chainId`; trusted mode remains a local dev chain unless the user explicitly overrides `chainId`

### Light-Mode CLI Contract

| Flag | Value | Default |
| --- | --- | --- |
| `--network` | `mainnet`, `sepolia`, or `holesky` | `mainnet` |
| `--consensus-rpc-url` | HTTP(S) Beacon API endpoint | none, required in light mode |
| `--checkpoint` | `0x`-prefixed 32-byte hex hash | none |
| `--checkpoint-dir` | directory path | `.zevm/checkpoints/<network>` |
| `--max-checkpoint-age-seconds` | `u64` | `1209600` |
| `--strict-checkpoint-age` | boolean flag | `false` |

Light-mode rules:

- `--consensus-rpc-url` is required when `--mode light` is selected
- light-mode flags are invalid when `--mode trusted` is active
- `--checkpoint` is an explicit user override and takes precedence over persisted or baked defaults

### Canonical Config File Contract

When `--config` is used, ZEVM reads a JSON file whose shape is part of the public contract.

Exactly one runtime branch may appear under `mode`.

Trusted-mode config:

```json
{
  "rpc": {
    "host": "127.0.0.1",
    "port": 8545
  },
  "mode": {
    "trusted": {
      "chainId": 31337,
      "coinbaseIndex": 0,
      "initialBalance": "10000000000000000000000",
      "gasPrice": "2000000000",
      "baseFee": "1000000000",
      "blobBaseFee": "1",
      "maxPriorityFeePerGas": "1000000000",
      "blockGasLimit": 30000000,
      "mining": {
        "type": "auto"
      },
      "fork": null
    }
  }
}
```

Light-mode config:

```json
{
  "rpc": {
    "host": "127.0.0.1",
    "port": 8545
  },
  "mode": {
    "light": {
      "network": "mainnet",
      "consensusRpcUrl": "https://beacon.example",
      "checkpoint": null,
      "checkpointDir": ".zevm/checkpoints/mainnet",
      "maxCheckpointAgeSeconds": 1209600,
      "strictCheckpointAge": false
    }
  }
}
```

Config rules:

- `rpc.host` and `rpc.port` are shared settings
- `mode` must contain exactly one of `trusted` or `light`
- a config file that contains both `mode.trusted` and `mode.light` is invalid
- a config file that contains neither `mode.trusted` nor `mode.light` is invalid
- CLI overrides win over config-file values
- CLI `--mode` may confirm the config-file mode, but it may not conflict with it

### Precedence Rules

Startup resolves values in this order:

1. CLI flags
2. config-file fields from `--config`
3. persisted light-mode checkpoint, if applicable
4. baked defaults in the selected mode

Checkpoint selection in light mode resolves in this order:

1. explicit user-provided checkpoint from `--checkpoint` or `mode.light.checkpoint`
2. persisted checkpoint from `checkpointDir/checkpoint`
3. baked network default checkpoint from the selected network config

### Invalid Combination And Failure Contract

ZEVM must fail before opening the HTTP listener when startup input is invalid.

Hard failures include:

- unknown CLI flag
- missing value for a value-taking flag
- invalid integer or wei literal
- conflicting mode selection between CLI and config file
- both `mode.trusted` and `mode.light` present in config
- trusted-only flag in light mode
- light-only flag in trusted mode
- `--consensus-rpc-url` missing in light mode
- `--block-time` missing for interval mining
- `--block-time` present outside interval mining
- `--fork-block-number` without `--fork-url`
- `coinbaseIndex` outside the managed-account range
- malformed checkpoint hex

Current `HEAD` only parses `--host` and `--port`; that is an implementation gap, not the product contract.

## Mode Contracts

### Light Mode

Light mode is the phase-2 read-only product surface.

It must:

- sync consensus via the Beacon chain
- persist checkpoint progress
- serve execution reads only when backed by proofs validated against a synced execution root
- expose readiness and sync status through JSON-RPC
- derive `safe` and `finalized` semantics from consensus sync rather than local placeholders

Light mode supports these public JSON-RPC methods:

- `eth_chainId`
- `eth_blockNumber`
- `eth_getBalance`
- `eth_getCode`
- `eth_getStorageAt`
- `eth_getTransactionCount`
- `zevm_lightSyncStatus`

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

Light-mode block-tag semantics:

| Tag | Meaning in light mode |
| --- | --- |
| `latest` | latest verified optimistic execution head |
| `safe` | consensus-backed safe head derived from the optimistic light-client head |
| `finalized` | consensus-finalized execution head |
| `earliest` | block `0` |
| numeric quantity | exact block number when ZEVM can map it to verified state |
| `pending` | unsupported in light mode |

`zevm_lightSyncStatus` takes no params and returns:

```json
{
  "ready": true,
  "status": "synced",
  "network": "mainnet",
  "checkpointSource": "explicit",
  "lastCheckpoint": "0x9b41a80f58c52068a00e8535b8d6704769c7577a5fd506af5e0c018687991d55",
  "optimisticSlot": "0x1234",
  "finalizedSlot": "0x1230"
}
```

`checkpointSource` is one of:

- `explicit`
- `persisted`
- `default`

`status` is one of:

- `syncing`
- `synced`
- `error`

Readiness rule:

- `ready = true` only when `status = "synced"` and ZEVM can serve proof-backed reads
- while `ready = false`, proof-backed read methods must fail with a deterministic light-mode-not-ready JSON-RPC error instead of serving unverified data

Proof-backed `eth_call` is explicitly deferred until there is a clear verified execution story for transient call state.

### Trusted Mode

Trusted mode is the phase-1 full dev-node surface.

It must:

- create a deterministic local dev chain by default
- support managed development accounts
- optionally read from a remote RPC source through Voltaire's fork backend
- resolve reads from local overlay first and then remote fork state when a fork source is configured
- keep all writes, mining, snapshots, impersonation, and time controls local to the trusted runtime
- avoid proof verification

Trusted-mode defaults:

- chain ID `31337`
- mnemonic `test test test test test test test test test test test junk`
- derivation path root `m/44'/60'/0'/0/`
- initial HD index `0`
- 10 deterministic managed dev accounts
- initial balance `10000 ETH` per managed account
- coinbase = managed account index `0`
- gas price `2000000000`
- base fee `1000000000`
- blob base fee `1`
- max priority fee per gas `1000000000`
- block gas limit `30000000`
- mining mode `auto`

The managed-account contract is exact and public.

ZEVM trusted mode uses the first 10 accounts derived from the canonical mnemonic and derivation path above. `eth_accounts` returns these addresses in ascending index order, `coinbaseIndex` selects by index into this exact table, and `eth_sendTransaction` may sign only for these managed accounts unless impersonation is active.

| Index | Address | Private key |
| --- | --- | --- |
| `0` | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80` |
| `1` | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` |
| `2` | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` |
| `3` | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` | `0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6` |
| `4` | `0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65` | `0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a` |
| `5` | `0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc` | `0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba` |
| `6` | `0x976EA74026E726554dB657fA54763abd0C3a0aa9` | `0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e` |
| `7` | `0x14dC79964da2C08b23698B3D3cc7Ca32193d9955` | `0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356` |
| `8` | `0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f` | `0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97` |
| `9` | `0xa0Ee7A142d267C1f36714E4a8F75612F20a79720` | `0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6` |

These are public development-only keys. They are part of the ZEVM trusted-mode compatibility contract and are never safe for public networks.

Trusted-mode block-tag semantics:

| Tag | Meaning in trusted mode |
| --- | --- |
| `latest` | current canonical local head |
| `pending` | compatibility alias of `latest` |
| `safe` | compatibility alias of `latest` |
| `finalized` | compatibility alias of `latest` |
| `earliest` | block `0` |
| numeric quantity | exact local block number |

Trusted-mode `pending`, `safe`, and `finalized` do **not** provide consensus-backed finality. They are compatibility aliases only. Real `safe` and `finalized` semantics belong to light mode.

## JSON-RPC Transport Contract

Phase 1 ships one canonical HTTP JSON-RPC 2.0 transport rooted at the newer `src/rpc/server.zig` plus `src/rpc/dispatcher.zig` direction. The older local `src/rpc/envelope.zig` plus `src/rpc/router.zig` path is a prototype, not the intended shipping transport.

HTTP contract:

- transport: HTTP only
- path: `/`
- allowed method: `POST`
- non-`POST` requests: HTTP `405`
- JSON-RPC responses: HTTP `200` with `content-type: application/json`
- notification-only requests or notification-only batches: HTTP `204` with empty body

JSON-RPC framing contract:

- single requests supported
- batches supported
- mixed valid/invalid batch items supported
- standard JSON-RPC 2.0 error codes supported
- mode-specific unsupported methods fail deterministically

Notification contract:

- a notification is a request object with no `id` member
- ZEVM must not send a JSON-RPC response for notifications
- a batch that contains only notifications must not send a JSON-RPC response body
- a mixed batch returns responses only for the items that carried an `id`
- `"id": null` is not a notification; it receives a response with `id: null`

Current `HEAD` responds to notification-shaped requests in both in-tree transport paths. That is a bug, not an open wording choice.

Standard JSON-RPC error mapping:

| Condition | Code |
| --- | --- |
| parse error | `-32700` |
| invalid request | `-32600` |
| method not found | `-32601` |
| invalid params | `-32602` |
| internal error | `-32603` |

ZEVM-specific runtime errors:

| Condition | Code |
| --- | --- |
| method unsupported in the active mode | `-32010` |
| light mode not ready to serve verified reads | `-32011` |
| checkpoint too old under strict age policy | `-32012` |
| invalid or corrupt checkpoint input | `-32013` |
| proof verification failure | `-32014` |
| malformed upstream response | `-32015` |

## State, Fork, And Snapshot Semantics

Trusted mode must use Voltaire's state-manager stack as its only execution-state foundation.

- use upstream `StateManager`, journal/snapshot support, `ForkBackend`, and `Blockchain`
- do not introduce a second ZEVM-owned journaled state abstraction
- local overlays on forked state live in trusted mode and remain local-only

Snapshot/revert exists only in trusted mode.

A trusted-mode snapshot captures the mutable local execution shell:

- state journal checkpoint or local overlay
- canonical local chain head
- receipt and log indexes derived from local canonical blocks
- pending txpool state
- mining configuration and block-environment overrides
- impersonation state
- time controls

A snapshot does **not** capture:

- consensus or checkpoint-sync state
- the remote fork source itself

Implementation preference: restore state through upstream checkpoint/revert primitives plus deterministic restoration of ZEVM-owned metadata rather than deep-copying the entire node state in ZEVM.

## Light-Mode Checkpoint Contract

Light mode persists the selected checkpoint in `checkpointDir/checkpoint`.

The persisted file contract is:

- filename: `checkpoint`
- location: inside the configured `checkpointDir`
- contents: exactly 64 hex characters representing the 32-byte checkpoint hash
- `0x` prefix: not stored on disk
- surrounding whitespace: ignored when loading

Startup behavior:

- if an explicit checkpoint is provided, ZEVM uses it and ignores the persisted checkpoint for selection purposes
- if no explicit checkpoint is provided and `checkpointDir/checkpoint` exists, ZEVM uses the persisted checkpoint
- if no explicit or persisted checkpoint exists, ZEVM uses the baked network default
- if a persisted checkpoint file exists but is malformed, ZEVM fails startup instead of silently falling back
- if the selected checkpoint is older than `maxCheckpointAgeSeconds` and `strictCheckpointAge = false`, ZEVM logs a warning and continues
- if the selected checkpoint is older than `maxCheckpointAgeSeconds` and `strictCheckpointAge = true`, ZEVM fails startup

The baked network defaults currently come from the network definitions already present in `src/consensus_sync.zig` for `mainnet`, `sepolia`, and `holesky`.

## Delivery Priorities

### Phase 1 - Trusted Mode MVP

Build a runnable trusted node first. This is the shortest path to a usable product and the right place to stabilize runtime ownership.

Required in phase 1:

1. **Runnable startup and mode selection**
   - one binary
   - default startup enters trusted mode
   - exact shared flags: `--config`, `--mode`, `--host`, `--port`
   - exact trusted-mode flags: `--chain-id`, `--coinbase-index`, `--initial-balance`, `--gas-price`, `--base-fee`, `--blob-base-fee`, `--max-priority-fee-per-gas`, `--block-gas-limit`, `--mining`, `--block-time`, `--fork-url`, `--fork-block-number`
   - invalid mode/flag combinations fail deterministically

2. **HTTP JSON-RPC transport**
   - configurable listener (default `8545`)
   - JSON-RPC 2.0 request/response handling
   - batch requests
   - notifications
   - no response for missing-`id` notifications
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

- exact light-mode flags: `--network`, `--consensus-rpc-url`, `--checkpoint`, `--checkpoint-dir`, `--max-checkpoint-age-seconds`, `--strict-checkpoint-age`
- startup/config for network selection and checkpoint persistence
- bootstrapping, resume, and sync advancement
- readiness/sync-status reporting through `zevm_lightSyncStatus`
- proof acquisition for account, storage, code, and nonce reads
- proof-backed implementations of core read methods
- explicit safe failure on stale checkpoints, invalid proofs, and malformed upstream responses
- checkpoint precedence: explicit user input, then persisted checkpoint, then baked network default

### Phase 3 - Advanced Tooling

Only after trusted-mode canonical execution and light-mode verified reads are stable:

- debug tracing (`debug_traceCall`, `debug_traceTransaction`)
- filter lifecycle APIs
- WebSocket transport and subscriptions

Tracing, filters, and subscriptions should not ship ahead of canonical block, receipt, log, and snapshot correctness.

## Target Feature Parity

ZEVM aims for parity with:

- Hardhat EDR (`edr/`) for trusted dev-node behavior, mining controls, snapshots, impersonation, and tracing
- Foundry Anvil (`foundry/`) for fast forkable dev-node behavior
- TEVM (`../tevm-monorepo`) for trusted-client handler coverage across `eth`, `anvil`, and `debug`
- Helios for light-client sync plus proof-verified reads

External references are supporting context only. The repository docs remain the primary ZEVM authority.

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

- no third standalone "fork mode"
- no light-mode transaction sending or local mutation
- no proof-backed `eth_call` in the first light-mode delivery
- no WebSocket/subscription surface before the canonical HTTP execution surface is correct
- no ZEVM-local replacement for upstream state-manager or EVM ownership

## Zig Style Rules

- no local type aliases (`const Foo = bar.Foo` is banned); always use fully qualified paths
- no stored allocators; pass allocator explicitly to methods that need it
- Zig 0.15 with lowercase `@typeInfo` variants (`.int`, `.bool`, `.float`)
