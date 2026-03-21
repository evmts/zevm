# ZEVM Internal Support: State Fork And Snapshot Semantics

Last updated: 2026-03-21

## Local State And Fork Layering

Trusted mode owns writable local execution state.

Forking rules:

- forking is configuration of trusted mode, not a separate mode
- fork reads come from the upstream fork backend
- local writes live in a trusted-mode overlay and remain local-only
- snapshots and revert act on the local overlay and ZEVM-owned metadata, not on the remote source
- `chainId` remains a trusted-mode startup setting; it is not inferred from `fork.url`

- current repo reality: `src/node/runtime.zig` still initializes `StateManager` with `null`, so fork-backed startup is not reachable from the executable path
- source IDs: `TRUST-03`
- contradiction IDs: `C-009`

## Snapshot Boundary

The trusted-mode snapshot captures:

- state journal checkpoint or local overlay
- canonical local chain head
- receipt and log indexes derived from local canonical blocks
- pending txpool state
- mining configuration
- block-environment overrides
- impersonation state
- time controls

The snapshot does **not** capture:

- consensus or light-mode checkpoint-sync state
- the remote fork source itself

- current repo reality: `src/rpc/dev_runtime.zig` captures only a narrower subset of state and is not on the executable path
- source IDs: `TRUST-04`
- contradiction IDs: `C-008`

## Dev Controls Beyond Snapshot/Revert

Trusted mode also owns:

- Hardhat/Anvil-compatible state mutation methods
- impersonation controls
- time controls
- mining-adjacent controls that affect trusted local block production

- current repo reality: some state-mutation handlers exist, but impersonation and time-control implementations were not found; mining controls are still disconnected from startup/runtime
- source IDs: `RPC-05`, `TRUST-04`
- contradiction IDs: `C-005`, `C-008`
