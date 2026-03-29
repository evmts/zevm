# ZEVM Internal Support: State Fork And Snapshot Semantics

Last updated: 2026-03-27

## Local State And Fork Layering

### Intended behavior

Trusted mode owns writable local execution state.

Forking rules:

- Forking is configuration of trusted mode, not a separate mode.
- Fork reads come from the upstream fork backend.
- Local reads resolve local overlay first and remote fork backing second.
- Local writes live in a trusted-mode overlay and remain local-only.
- Snapshots and revert act on the local overlay and ZEVM-owned metadata, not on the remote source.
- `chainId` remains a trusted-mode startup setting; it is not inferred from `fork.url`.
- Canonical nonstandard controls use the `zevm_*` namespace.
- The exact accepted compatibility-alias set from `docs/specs/json-rpc-contract.md` is accepted in trusted mode only.
- `zevm_*` is an authoritative product-contract rule, not a docs convention.
- `zevm_reset([forkConfig])` is a fork-source control: it resets trusted mode and may replace the upstream fork configuration.
- `zevm_setRpcUrl([url])` is a fork-source control: it updates the upstream fork endpoint.
- These fork-source controls are separate from overlay-state semantics and do not redefine the snapshot boundary.

### Observed code constraints

- `src/node/runtime.zig` still initializes `StateManager` with `null`, so fork-backed startup is not reachable from the executable path.
- The startup path exposes no fork flags.
- No executable runtime path wires `ForkBackend`.
- `src/rpc/dev_runtime.zig` is a partial prototype helper that captures only state snapshot id, block number, and a narrow node config; it is not the trusted-mode runtime model.

### Unresolved ambiguity

- None about the layering model.
- The unresolved work is startup integration.

### Affected public pages

- `mintlify/docs/concepts/state-fork-and-snapshots.mdx`
- `mintlify/docs/quickstart/forked-dev-node.mdx`
- `mintlify/docs/reference/configuration/trusted-mode.mdx`
- `mintlify/docs/concepts/trusted-mode.mdx`

### Source IDs

- `TRUST-09`
- `BOOT-07`

### Contradiction IDs

- `C-010`

## Snapshot Boundary

### Intended behavior

The trusted-mode snapshot contract captures:

- state journal checkpoint or local overlay
- canonical local chain head
- receipt and log indexes derived from local canonical blocks
- pending txpool state
- mining configuration
- block-environment overrides
- impersonation state
- time controls

The snapshot does not capture:

- consensus or light-mode checkpoint-sync state
- the remote fork source itself

### Observed code constraints

- The prototype snapshot helper in `src/rpc/dev_runtime.zig` captures only a narrower subset of state and is not the shipping contract.
- As rechecked on 2026-03-27, that helper stores only a state snapshot id, block number, and the narrow `NodeDevConfig` fields `coinbase`, `next_block_base_fee_per_gas`, and `block_gas_limit`.
- As rechecked on 2026-03-27, `revertSnapshot` restores only that stored state snapshot id, reverts the blockchain to the stored block number, restores the narrow `NodeDevConfig`, and prunes newer snapshot ids; it is not evidence of txpool, receipt or log-index, impersonation, time-control, or broader runtime-metadata capture.
- It does not currently capture txpool state, receipt or log indexes, impersonation state, time controls, or broader trusted-runtime metadata.
- That code path is not on the executable path.

### Unresolved ambiguity

- The snapshot boundary is contractually settled, and the public method namespace is documented through the `zevm_*` contract and compatibility aliases.
- None about the public snapshot/revert naming contract.

### Affected public pages

- `mintlify/docs/concepts/state-fork-and-snapshots.mdx`
- `mintlify/docs/reference/json-rpc/dev-controls.mdx`
- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/reference/json-rpc/transactions-and-mining.mdx`

### Source IDs

- `TRUST-10`
- `TRUST-11`

### Contradiction IDs

- `C-009`

## Dev Controls Beyond Snapshot/Revert

### Intended behavior

Trusted mode also owns:

- canonical `zevm_*` state-mutation, impersonation, time, mining, and environment controls
- the exact accepted compatibility-alias set from `docs/specs/json-rpc-contract.md`
- phase-3 trace and logging tooling, which remains deferred rather than phase-1 shipping
- the fork-source controls `zevm_reset([forkConfig])` and `zevm_setRpcUrl([url])`, which adjust the upstream source rather than the local overlay
- local import/export controls such as `zevm_dumpState` and `zevm_loadState`, which serialize or hydrate local trusted-mode state and are separate from both snapshot/revert and fork-source selection

Resolved config shapes:

- `mode.trusted.mining`: `{ "type": "auto" }`, `{ "type": "manual" }`, or `{ "type": "interval", "blockTime": <seconds> }`
- `mode.trusted.fork`: `null`, `{ "url": "https://..." }`, or `{ "url": "https://...", "blockNumber": <u64> }`
- `mode.trusted.chainId` stays outside the fork object

### Observed code constraints

- Some state-mutation handlers exist.
- Impersonation and time-control implementations were not found.
- Mining controls are still disconnected from startup and runtime.

### Unresolved ambiguity

- None. The method namespace and config shapes are settled for public docs.

### Affected public pages

- `mintlify/docs/concepts/state-fork-and-snapshots.mdx`
- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/reference/json-rpc/transactions-and-mining.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`

### Source IDs

- `TRUST-11`
- `TRUST-10`
- `TRUST-07`

### Contradiction IDs

- `C-006`
- `C-009`

### Internal support docs

- `docs/specs/json-rpc-contract.md`
- `docs/specs/internal/runtime-modes-and-boundaries.md`
- `docs/specs/internal/trusted-mode-semantics.md`

### Notes

- Fork, snapshot, and revert are trusted-mode-only contract rules; the exact alias inventory is closed-world in `docs/specs/json-rpc-contract.md`.
