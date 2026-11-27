---
title: Beacon Light Client & Proof Verification
tags: [light-client, consensus, proofs, checkpoints]
---

# Beacon Light Client & Proof Verification

See [[Overview]] and [[Architecture]].

ZEVM light mode provides trust-minimized execution reads without syncing the full chain. Remote beacon API and execution RPC responses are treated as untrusted until cryptographically verified.

## Verification Pipeline

1. **Checkpoint Resolution (`src/checkpoint.zig`, `src/light_default_checkpoints.zig`):** resolves weak-subjectivity checkpoints in strict precedence order: explicit CLI/config `--checkpoint` -> persisted `checkpointDir/checkpoint` -> baked release default (`mainnet`, `sepolia`, `holesky`, `hoodi`).
2. **Beacon Sync (`src/beacon_api.zig`, `src/consensus_sync.zig`, `src/consensus_verifier.zig`):** fetches bootstrap, sync-committee updates, finality updates, and optimistic updates; verifies BLS12-381 aggregate signatures and fork-specific SSZ Merkle branches before advancing the trusted execution header.
3. **State & Storage Proofs (`src/light_proof.zig`, `src/mpt_proof.zig`):** verifies `eth_getProof` account and storage MPT inclusion/non-inclusion proofs directly against the verified execution `state_root`.

## Checkpoint Freshness & Release Metadata

- `.github/workflows/refresh-checkpoints.yml` and `tools/refresh_light_checkpoints.js` keep baked defaults fresh.
- `src/release_metadata.zig` emits `light-default-checkpoints.json` alongside `release-tuple.json` for every tagged release, validated automatically by `.github/workflows/ci.yml` (`Published Release Asset Validation`).
