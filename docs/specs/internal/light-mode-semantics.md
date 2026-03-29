# ZEVM Internal Support: Light Mode Semantics

Last updated: 2026-03-29

## Network And Checkpoint Contract

### Intended behavior

Light mode is the phase-2 runtime for consensus-backed verification and proof-backed reads.

It must:

- select `mainnet`, `sepolia`, or `holesky`
- bootstrap from an explicit checkpoint, persisted checkpoint, or baked default checkpoint
- treat baked network defaults as precedence inputs without freezing their literal hashes as public contract
- persist checkpoint progress to `checkpointDir/checkpoint`
- resume from the selected checkpoint source on restart
- enforce checkpoint age policy using `maxCheckpointAgeSeconds` and `strictCheckpointAge`
- treat a checkpoint at exactly `maxCheckpointAgeSeconds` as valid; the stale-checkpoint condition is exactly `age > maxCheckpointAgeSeconds`
- if `strictCheckpointAge = false`, a stale selected checkpoint logs a warning and continues startup
- if `strictCheckpointAge = true`, a stale selected checkpoint fails startup
- expose only standard `eth_*` reads plus `zevm_lightSyncStatus`
- never expose the trusted-mode `zevm_*`, `anvil_*`, `hardhat_*`, or legacy `evm_*` dev-control surface

Checkpoint precedence:

1. explicit user checkpoint
2. persisted checkpoint
3. baked network default

Persisted checkpoint file contract:

- path: `checkpointDir/checkpoint`
- format: 64 hex characters representing the 32-byte checkpoint hash
- whitespace: trimmed on read
- malformed file: startup failure

### Observed code constraints

- `src/checkpoint.zig` already encodes the on-disk filename and 64-hex contract.
- `src/consensus_sync.zig` already contains baked defaults for the three supported networks, but those exact literals are observed implementation defaults rather than public API guarantees.
- As rechecked on 2026-03-29, `src/consensus_sync.zig` still returns `age < self.config.max_checkpoint_age` from `isValidCheckpoint`, so `age == maxCheckpointAgeSeconds` is treated as invalid or stale in current helper code.
- As rechecked on 2026-03-29, the executable path does not yet expose any of this publicly.
- `src/consensus_sync.zig` uses `SyncStatus.err` internally, while the published status string contract is `error`; that naming drift is implementation detail, not a semantic change.

### Unresolved ambiguity

- None about the checkpoint file format, supported network set, or public method surface.
- The intended contract is settled: `age == maxCheckpointAgeSeconds` is valid, and only `age > maxCheckpointAgeSeconds` is stale.
- Current `HEAD` explicitly contradicts that equality boundary in helper code, and as rechecked on 2026-03-29 it still lacks the executable light-mode startup flow.

### Affected public pages

- `mintlify/docs/concepts/light-mode.mdx`
- `mintlify/docs/reference/configuration/light-mode.mdx`
- `mintlify/docs/concepts/runtime-modes.mdx`
- `mintlify/docs/reference/configuration/overview.mdx`

### Source IDs

- `LIGHT-01`
- `LIGHT-02`
- `LIGHT-03`
- `LIGHT-06`

### Contradiction IDs

- `C-011`

## Status Surface

### Intended behavior

Light-mode readiness and sync status are part of the public JSON-RPC contract through `zevm_lightSyncStatus`.

Method contract:

- method: `zevm_lightSyncStatus`
- params: none
- available only in light mode
- return shape:

```json
{
  "ready": false,
  "status": "syncing",
  "network": "sepolia",
  "checkpointSource": "persisted",
  "lastCheckpoint": "0x...",
  "optimisticSlot": "0x0",
  "finalizedSlot": "0x0"
}
```

Field rules:

- `ready`: boolean gate for proof-backed reads; `true` only when `status = "synced"` and ZEVM can serve proof-backed reads
- `status`: `syncing`, `synced`, or `error`
- `network`: selected light network
- `checkpointSource`: `explicit`, `persisted`, or `default`
- `lastCheckpoint`: most recent accepted checkpoint hash or `null`
- `optimisticSlot`: current optimistic slot
- `finalizedSlot`: current finalized slot
- Exact payload fields and mode-gating rules live in `docs/specs/json-rpc-contract.md`.

Availability rules:

- In trusted mode this method fails with the ZEVM mode-gating error.
- In light mode it remains callable even while the light client is still syncing.

### Observed code constraints

- `src/consensus_sync.zig` already exposes `status`, `lastCheckpoint()`, `optimisticSlot()`, and `finalizedSlot()`.
- As rechecked on 2026-03-29, no public RPC method is wired yet.

### Unresolved ambiguity

- None about the payload contract.
- The unresolved work is public RPC exposure.

### Affected public pages

- `mintlify/docs/concepts/light-mode.mdx`
- `mintlify/docs/reference/json-rpc/verified-light-mode-reads.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`
- `mintlify/docs/concepts/runtime-modes.mdx`

### Source IDs

- `LIGHT-04`

### Contradiction IDs

- `C-012`

## `eth_blockNumber` Contract

### Intended behavior

- Light mode includes `eth_blockNumber` in the public method set.
- The exact tuple remains `[]` or omitted, and the result type remains `QuantityHex`.
- While `ready = false`, `eth_blockNumber` fails with `-32011`.
- Once `ready = true`, `eth_blockNumber` returns the block number of the light-mode `latest` head, meaning the latest verified optimistic execution head.

### Observed code constraints

- `src/rpc/handlers/eth_read.zig` and its tests cover trusted-mode `eth_blockNumber` only.
- There is no light-mode RPC route that could currently demonstrate a settled public contract.

### Unresolved ambiguity

- None remains for the intended light-mode `eth_blockNumber` contract.
- The unresolved work is implementation wiring, not product semantics.

### Affected public pages

- `mintlify/docs/concepts/light-mode.mdx`
- `mintlify/docs/concepts/runtime-modes.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`
- `mintlify/docs/reference/json-rpc/overview.mdx`
- `mintlify/docs/reference/json-rpc/verified-light-mode-reads.mdx`

### Source IDs

- `RPC-ETH-BLOCKNUMBER`

## Proof-Backed Read Boundary

### Intended behavior

Light mode supports this status-and-read surface:

- `zevm_lightSyncStatus`
- `eth_chainId`
- `eth_blockNumber`
- `eth_getBalance`
- `eth_getCode`
- `eth_getStorageAt`
- `eth_getTransactionCount`

Read rules:

- Reads must verify the relevant proof against a synced execution root.
- `latest` resolves to the latest verified optimistic execution head.
- `safe` resolves to a consensus-backed safe head.
- `finalized` resolves to the consensus-finalized head.
- `earliest` resolves to block `0`.
- `pending` is unsupported.
- While `ready = false`, ZEVM serves no proof-backed reads and fails them with `-32011`.
- While `ready = false`, `eth_blockNumber` also fails with `-32011`.
- Once ready, `eth_blockNumber` returns the block number of `latest`, meaning the latest verified optimistic execution head.
- Once ready, numeric selectors are supported only for block `0` and for exact blocks inside the retained verified-history window containing the most recent `8191` verified execution blocks when ZEVM can verify the exact execution block and the requested proof-backed read against that block's state root.
- If light mode is ready in general but the requested numeric block is outside that retained verified-history window, the request fails with `-32602`.
- Failure to verify an otherwise-supported proof-backed read remains a proof verification failure under `-32014`, not an out-of-window selector error.
- ZEVM does not promise arbitrary checkpoint-to-head historical archive reads.
- Proof verification failure maps to `-32014`.
- Malformed upstream data maps to `-32015`.
- Exact request tuples, selector behavior, and error behavior live in `docs/specs/json-rpc-contract.md`.

### Observed code constraints

- The consensus verification substrate exists, but there is no proof-backed execution-read bridge in `src/`.
- Trusted-mode helper code still aliases `safe` and `finalized` to the local head because light-mode query bridging does not exist yet.

### Unresolved ambiguity

- None about the intended tag semantics or the light-mode-only surface split.
- The open work is the proof-backed read bridge and the not-ready error path.

### Affected public pages

- `mintlify/docs/concepts/light-mode.mdx`
- `mintlify/docs/reference/json-rpc/verified-light-mode-reads.mdx`
- `mintlify/docs/concepts/runtime-modes.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`

### Source IDs

- `LIGHT-05`
- `RPC-04`
- `RPC-TAGS-LIGHT`

### Contradiction IDs

- `C-012`

### Internal support docs

- `docs/specs/json-rpc-contract.md`
- `docs/specs/internal/runtime-modes-and-boundaries.md`
- `docs/specs/internal/transport-and-error-semantics.md`

### Notes

- Light mode is proof-backed only; any request that cannot be verified must fail rather than falling back to placeholder data.
