# ZEVM Internal Support: Light Mode Semantics

Last updated: 2026-03-21

## Network And Checkpoint Contract

Light mode is the phase-2 runtime for consensus-backed verification and proof-backed reads.

It must:

- select `mainnet`, `sepolia`, or `holesky`
- bootstrap from an explicit checkpoint, persisted checkpoint, or baked default checkpoint
- persist checkpoint progress to `checkpointDir/checkpoint`
- resume from the selected checkpoint source on restart
- enforce checkpoint age policy using `maxCheckpointAgeSeconds` and `strictCheckpointAge`

Checkpoint precedence:

1. explicit user checkpoint
2. persisted checkpoint
3. baked network default

Persisted checkpoint file contract:

- path: `checkpointDir/checkpoint`
- format: 64 hex characters representing the 32-byte checkpoint hash
- whitespace: trimmed on read
- malformed file: startup failure

- current repo reality: `src/checkpoint.zig` already encodes the on-disk filename and 64-hex contract, while `src/consensus_sync.zig` already contains baked defaults for the three supported networks; the executable path does not yet expose any of this publicly
- source IDs: `LIGHT-01`, `LIGHT-02`, `LIGHT-03`
- contradiction IDs: `C-011`

## Status Surface

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
  "lastCheckpoint": "0x4065c2509eaa15dbe60e1f80cff5205a532aa95aaa1d73c1c286f7f8535555d4",
  "optimisticSlot": "0x0",
  "finalizedSlot": "0x0"
}
```

Field rules:

- `ready`: boolean gate for proof-backed reads
- `status`: `syncing`, `synced`, or `error`
- `network`: selected light network
- `checkpointSource`: `explicit`, `persisted`, or `default`
- `lastCheckpoint`: most recent accepted checkpoint hash or `null`
- `optimisticSlot`: current optimistic slot
- `finalizedSlot`: current finalized slot

Availability rules:

- in trusted mode this method fails with the ZEVM mode-gating error
- in light mode it remains callable even while the light client is still syncing

- current repo reality: `src/consensus_sync.zig` already exposes `status`, `lastCheckpoint()`, `optimisticSlot()`, and `finalizedSlot()`, but no public RPC method is wired
- source IDs: `LIGHT-04`
- contradiction IDs: `C-012`

## Proof-Backed Read Boundary

Light mode supports these reads:

- `eth_chainId`
- `eth_blockNumber`
- `eth_getBalance`
- `eth_getCode`
- `eth_getStorageAt`
- `eth_getTransactionCount`

Read rules:

- reads must verify the relevant proof against a synced execution root
- `latest` resolves to the latest verified optimistic execution head
- `safe` resolves to a consensus-backed safe head
- `finalized` resolves to the consensus-finalized head
- `pending` is unsupported
- while `ready = false`, proof-backed reads fail with `-32011`
- proof verification failure maps to `-32014`
- malformed upstream data maps to `-32015`

- current repo reality: consensus verification substrate exists, but there is no proof-backed execution-read bridge in `src/`; trusted-mode helper code still aliases `safe` and `finalized` to the local head because light-mode query bridging does not exist yet
- source IDs: `LIGHT-05`, `RPC-03`
- contradiction IDs: `C-007`, `C-012`
