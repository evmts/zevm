# ZEVM Internal Support: Light Mode Semantics

Last updated: 2026-03-30

This page supports the normative light-mode contract in:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

## 1. Runtime Role

Light mode is a read-only runtime that serves proof-backed execution-state reads.

Supported RPC surface:

- `zevm_lightSyncStatus`
- `eth_chainId`
- `eth_blockNumber`
- `eth_getBalance`
- `eth_getCode`
- `eth_getStorageAt`
- `eth_getTransactionCount`

Unsupported in light mode (`-32010`) includes:

- `eth_call` (proof-backed target deferred in phase 1)
- `eth_estimateGas`
- `eth_feeHistory`
- `eth_sendTransaction`, `eth_sendRawTransaction`
- `eth_getBlockByNumber`, `eth_getBlockByHash`
- `eth_getBlockTransactionCountByHash`, `eth_getBlockTransactionCountByNumber`
- `eth_getTransactionByHash`, `eth_getTransactionByBlockHashAndIndex`, `eth_getTransactionByBlockNumberAndIndex`, `eth_getTransactionReceipt`
- `eth_getBlockReceipts`, `eth_getLogs`
- all trusted-only dev-node controls (`zevm_*` mutation/mining/snapshot/impersonation controls)

## 2. Networks And Chain IDs

Light mode supports exactly:

- `mainnet` -> `0x1`
- `sepolia` -> `0xaa36a7` (11155111)
- `holesky` -> `0x4268` (17000)

`eth_chainId` must return the fixed mapping for the selected network.

Network-set governance:

- phase-1 light-network set is closed and exact: `mainnet`, `sepolia`, `holesky`
- adding, removing, or renaming a supported light network is a normative contract change and requires synchronized updates to `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md`

Startup input rule:

- `consensusRpcUrl` must serve the same network selected by `network`
- checkpoint startup inputs from CLI/config (`--checkpoint`, `mode.light.checkpoint`) must be `0x`-prefixed 32-byte hashes (`Hash32`)
- `--strict-checkpoint-age` is a presence flag: present means `true`, omitted means `false`, and explicit assignment forms (for example `--strict-checkpoint-age=false`) are invalid
- selected startup checkpoint hash must resolve on the configured `network` via `consensusRpcUrl`; network mismatch is startup failure before opening the HTTP listener
- phase-1 operator-facing light-mode startup inputs are `network`, `consensusRpcUrl`, `checkpoint`, `checkpointDir`, `maxCheckpointAgeSeconds`, and `strictCheckpointAge`
- among proof-source plumbing inputs, only `consensusRpcUrl` is operator-configurable; other proof-source internals are implementation-defined and not user-configurable

Startup consensus-network handshake (before listener):

1. resolve `network`, `consensusRpcUrl`, and selected startup checkpoint from startup precedence
2. call `GET <consensusRpcUrl>/eth/v1/beacon/genesis`
3. require HTTP `200` and parse `data.genesis_validators_root` as `Hash32`
4. require root match for selected `network`:
   - `mainnet` -> `0x4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95`
   - `sepolia` -> `0xd8ea171f3c94aea21ebc42a1ed61052acf3f9209c00e4efbaaddac09ed9b8078`
   - `holesky` -> `0x9143aa7c615a7f7115e2b6aac319c03529df8242ae705fba9df39b79c59fa8b1`
5. if handshake fails (request failure, non-`200`, malformed payload, missing/invalid root, or root mismatch), startup fails before opening the HTTP listener

## 3. Checkpoint Selection And Age

This section stays intentionally brief to reduce drift. Canonical checkpoint-selection and checkpoint-age behavior is defined in:

- `docs/specs/prd.md#53-light-mode-cli`
- `docs/specs/prd.md#55-precedence`
- `docs/specs/prd.md#56-persisted-checkpoint-file-contract`
- `docs/specs/prd.md#57-checkpoint-age-policy`
- `docs/specs/prd.md#58-startup-failure-behavior`
- `docs/specs/prd.md#10-light-mode-checkpoint-and-history-semantics`
- `docs/specs/json-rpc-contract.md#5-errors` (especially sections 5.2 and 5.3)
- `docs/specs/json-rpc-contract.md#53-shared-error-rules`
- `docs/specs/json-rpc-contract.md#62-light-selectors-and-retained-history`
- `docs/specs/json-rpc-contract.md#710-light-sync-status-object`
- `docs/specs/json-rpc-contract.md#13-light-mode-methods`

Operational support notes (non-normative):

- Startup checkpoint source resolution feeds `checkpointSource` provenance in `zevm_lightSyncStatus` (`explicit`, `persisted`, `default`).
- Persisted checkpoint handling uses `${resolvedCheckpointDir}/checkpoint` as startup input; runtime `lastCheckpoint` progression remains runtime state in phase 1.
- Checkpoint-age evaluation and strict/non-strict stale handling are startup-time concerns; error-code and readiness interactions are carried by the JSON-RPC contract sections listed above.
- For implementation context on merge precedence and startup validation flow, see `docs/specs/internal/startup-and-configuration.md` (especially sections 6 and 7).

## 4. Sync Status Semantics

`zevm_lightSyncStatus` fields include:

- `ready`: read-availability gate
- `status`: `syncing`, `synced`, or `error`
- `network`: selected light network (`mainnet`, `sepolia`, or `holesky`)
- `checkpointSource`: `explicit`, `persisted`, or `default`
- `lastCheckpoint`: most recently accepted checkpoint root
- `optimisticSlot`, `safeSlot`, `finalizedSlot`

Invariants:

- `ready = true` only when `status = "synced"`
- `status = "syncing"` or `status = "error"` implies `ready = false`
- `network` is always present and equals the selected startup light network for the process lifetime
- `ready` may transition from `false` to `true` only when `status` transitions to `synced` after ZEVM has accepted verified optimistic, safe, and finalized heads for the selected network
- while `ready = true`, slot coherence must hold: `finalizedSlot <= safeSlot <= optimisticSlot`
- selector semantics are unchanged: `latest` resolves to the optimistic execution head, `safe` resolves to the consensus-backed safe execution head, and `finalized` resolves to the consensus-finalized execution head
- if `status` leaves `synced` or slot coherence cannot be maintained, ZEVM must set `ready = false` in the same state transition before serving subsequent gated RPC calls
- `checkpointSource` reflects the selected startup checkpoint source and remains stable for the process lifetime:
  - `explicit`: selected from user-provided checkpoint input (CLI `--checkpoint` or config `mode.light.checkpoint`)
  - `persisted`: selected from `${resolvedCheckpointDir}/checkpoint`
  - `default`: selected from ZEVM bundled release/build default checkpoint for the selected network (deterministic for that release/build artifact; may rotate across releases/builds; for published release identifiers, the bundled value is published in that release's required `light-default-checkpoints.json`)
- `lastCheckpoint` is always present as `Hash32` after listener startup
- `optimisticSlot`, `safeSlot`, and `finalizedSlot` are always present as `QuantityHex` values (not `null`)
- `finalizedSlot <= safeSlot <= optimisticSlot`
- while `status = "syncing"`, slot values may remain `0x0` until headers are available
- when `status = "error"`, slot fields keep the last known values and are not nullified
- `checkpointSource = "default"` does not expose `releaseIdentifier` and cannot by itself prove metadata-backed provenance

`lastCheckpoint` semantics:

- initialized from selected startup checkpoint after validation
- updated whenever a newer checkpoint is accepted
- reflects current accepted checkpoint state, not a pinned startup value
- `checkpointSource` does not change when `lastCheckpoint` advances
- `lastCheckpoint` updates do not imply on-disk checkpoint persistence in phase 1

Lifecycle transitions:

- listener-start entry state: `status = "syncing"` and `ready = false`
- `syncing -> synced`: initial light sync has accepted verified optimistic, safe, and finalized heads; this transition also sets `ready = true`
- `syncing -> error`: light sync fails after listener startup
- `synced -> error`: previously synced runtime later fails to advance/verify or loses slot coherence; this transition also sets `ready = false` before serving subsequent gated RPC calls
- phase-1 recovery from `error` requires operator action: fix upstream/configuration cause and restart ZEVM

Operational implications by state:

- `status = "syncing"`: proof-backed reads and `eth_blockNumber` remain gated (`-32011`); `eth_chainId` and `zevm_lightSyncStatus` stay callable
- `status = "synced"`: proof-backed reads are enabled (`ready = true`); proof failures still surface as `-32014` or `-32015`
- `status = "error"`: proof-backed reads and `eth_blockNumber` remain gated (`-32011`) until successful process restart

## 5. Readiness And Selector Boundaries

Readiness:

- readiness gating applies to proof-backed reads and `eth_blockNumber` only
- `eth_chainId` and `zevm_lightSyncStatus` are always callable in light mode regardless of `ready`
- while `ready=false`, proof-backed reads (including numeric selectors, even if out of retained window) and `eth_blockNumber` fail with `-32011`
- numeric-window validation (`-32602`) applies only when `ready=true`
- while `ready=true`, reads are served only when proof verification succeeds

Selector rules:

- supported tags: `latest`, `safe`, `finalized`, `earliest`, numeric
- `pending` unsupported (`-32010`)
- numeric selectors allowed only for block `0` plus retained-history window of latest `8191` verified blocks
- numeric outside retained history when otherwise ready -> `-32602`
- proof verification failure -> `-32014`
- malformed data from upstream proof source -> `-32015`

Light mode does not provide arbitrary archive reads outside retained verified history.
