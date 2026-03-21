# Light Client Mode And Proof-Verified Reads

## Verified Gap

- `consensus_sync`, `consensus_verifier`, `beacon_api`, and `checkpoint` provide library-level light-client functionality, but `main` has no light-client mode.
- There are no CLI/runtime flags for network selection, checkpoint input/output, checkpoint-age policy, or light-client readiness.
- There is no proof acquisition layer for execution-state reads, no verified account/storage/code proof path, and no bridge from synced execution roots to `eth_*` RPC responses.
- `safe` / `finalized` semantics on the normal read surface are not backed by consensus sync.
- Checkpoint persistence is minimal: a raw file write/load with no atomic write, versioning, network validation, or corruption handling.
- Test coverage is library-only: helper/apply logic is exercised, but there is no runnable sync, no verified-read path, and no startup/resume coverage.

## Evidence

- `src/main.zig`
- `src/consensus_sync.zig`
- `src/consensus_verifier.zig`
- `src/beacon_api.zig`
- `src/checkpoint.zig`
- `src/rpc/handlers/eth_read.zig`
- `src/consensus_sync_test.zig`
- `src/consensus_verifier_test.zig`
- `src/beacon_api_test.zig`

## Resolution Verification

- A dedicated light-client mode boots from checkpoint, selects mainnet/sepolia/holesky, syncs, persists progress, and resumes cleanly.
- Readiness/sync-status is exposed so clients can distinguish bootstrapping from verified-serving states.
- Account/code/storage reads verify proofs against the synced execution root before returning data.
- Invalid signatures, invalid Merkle proofs, malformed Beacon responses, stale checkpoints, and proof mismatches all fail safely.
- Checkpoint files are written atomically, validated for network correctness, and survive restart/corruption scenarios.
