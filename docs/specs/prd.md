# ZEVM Product Requirements

## 1. Purpose

ZEVM is one Zig binary (`zevm`) with two runtime modes:

1. trusted mode: writable local Ethereum dev node
2. light mode: read-only proof-backed client

Forking is configuration inside trusted mode, not a third mode.

## 2. Normative Documents

The ZEVM product contract is defined by:

1. this PRD for product scope and behavior
2. `docs/specs/json-rpc-contract.md` for exact JSON-RPC API tuples, payloads, and errors

If wording differs, `docs/specs/json-rpc-contract.md` is authoritative for API-level details.

## 3. Product Scope

In this PRD, phase-1 scope is declared in sections 3.1, 3.3, 3.4, and 3.5, with detailed normative runtime/transport/method/ownership semantics for those in-scope surfaces defined in sections 4 through 12; section 3.2 remains out of scope for phase 1.

### 3.1 In scope

- startup and configuration for trusted and light mode
- HTTP JSON-RPC 2.0 transport
- phase-1 trusted-mode JSON-RPC inventory includes standard reads (`eth_chainId`, `eth_blockNumber`, account/code/storage reads, pricing/fee reads including `eth_feeHistory`), simulation (`eth_call`, `eth_estimateGas`), submission (`eth_sendTransaction`, `eth_sendRawTransaction`), canonical block/receipt/log queries, and trusted controls under canonical `zevm_*` methods (mining, snapshot/revert, state mutation, impersonation, and time controls); canonical tuples/errors are under `Trusted-Mode Standard Methods` and `Trusted-Mode zevm_* Methods` in `docs/specs/json-rpc-contract.md`
- phase-1 light-mode JSON-RPC inventory is exactly `zevm_lightSyncStatus`, `eth_chainId`, `eth_blockNumber`, `eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, and `eth_getTransactionCount`; canonical tuples/errors are under `Light-Mode Methods` in `docs/specs/json-rpc-contract.md`
- in this PRD, "proof-backed reads" means exactly `eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, and `eth_getTransactionCount` in light mode; it does not include `eth_chainId`, `zevm_lightSyncStatus`, or `eth_blockNumber`
- while light mode is not ready, proof-backed reads and `eth_blockNumber` are readiness-gated (`-32011`) as defined in sections 4.2 and 10
- in phase 1, `eth_call` and `eth_estimateGas` are trusted-only and return `-32010` in light mode; `eth_call` remains a deferred light-mode proof-backed target, and light-mode unsupported reads also include `eth_feeHistory` plus canonical block/receipt/log query methods (all mode-unsupported as `-32010`, per section 10)
- phase-1 sequencing is trusted-first: trusted mode is the primary runtime surface while light mode ships the limited phase-1 read subset and expands in later phases
- phase-1 installation contract limited to source-build installation

### 3.2 Out of scope

- WebSocket transport and subscriptions
- filter lifecycle APIs beyond `eth_getLogs`
- debug tracing APIs
- proof-backed `eth_call` in light mode
- `eth_estimateGas` in light mode
- `eth_feeHistory` and canonical block/receipt/log queries in light mode
- expanded light-mode features beyond the phase-1 read subset
- packaged binary distribution and installer/distribution-channel guarantees

### 3.3 Phase-1 source-build installation contract

Phase 1 installation scope is source-build only.

- canonical build command: `zig build`
- minimum Zig version: `0.15.2`
- required sibling path dependencies at repository-parent level: `../voltaire` and `../guillotine-mini`
- phase-1 architecture/dependency boundary: ZEVM is built as one `zevm` binary from this repository plus those sibling dependencies
- source-build reproducibility for this contract requires one explicit pin tuple: `(zevmGitRevision, voltaireGitRevision, guillotineMiniGitRevision, zigVersion)`
- required pin format is full immutable git commit IDs for the three repositories plus one exact Zig toolchain version string
- release metadata artifacts and operator provenance requirements for this pin tuple are defined in section 3.4
- operators obtain/install the pinned Zig version from official Zig distributions and build from the ZEVM repository root with siblings present at `../voltaire` and `../guillotine-mini`
- phase 1 defines reproducibility as reproducing ZEVM behavior from the same pin tuple; byte-identical binary hashes across hosts are out of scope
- successful canonical build installs one artifact at `zig-out/bin/zevm`
- ZEVM guarantees this repository source-build path that produces one `zevm` binary from source
- repository build instructions and declared build-toolchain requirements are part of this phase-1 contract
- when source-build succeeds, the resulting `zevm` binary must satisfy this PRD and `docs/specs/json-rpc-contract.md`
- out of scope for this contract: packaged binaries, installers/package-manager channels, signing/notarization, byte-identical reproducible-build hash guarantees, cross-compilation guarantees, and host/toolchain provisioning automation

### 3.4 Release metadata and provenance contract

Release-metadata artifacts are part of phase-1 source-build reproducibility.

- this contract's metadata-backed reproducibility boundary applies only to published `releaseIdentifier` values (GitHub release tags) that publish required release metadata artifacts in GitHub releases
- unreleased commit builds (source checkouts with no matching published release metadata entry) remain valid source builds but are outside that metadata-backed reproducibility boundary
- phase-1 source-build provenance has exactly two states: metadata-backed published-release provenance and operator-recorded unreleased-commit provenance; operators must classify each build into one of these states
- operators must not claim metadata-backed reproducibility for an unreleased commit build or for a published `releaseIdentifier` that is metadata-invalid under this section

Release identifier and publication location contract:

- `releaseIdentifier` is the canonical ZEVM release-metadata identifier and must exactly equal the GitHub release tag name that carries required metadata assets
- tag-based `releaseIdentifier` values must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` and must not match the commit-based format below
- commit-based `releaseIdentifier` values must match `^commit-[0-9a-f]{40}$`; the 40-hex suffix is lowercase and must equal `zevmGitRevision` in that release's `release-tuple.json`
- required metadata files are published as GitHub release assets under canonical download URL pattern `https://github.com/evmts/zevm/releases/download/<releaseIdentifier>/<assetFileName>`

Release tuple artifact (`release-tuple.json`):

- each ZEVM `releaseIdentifier` must publish exactly one machine-readable release tuple asset named `release-tuple.json` at `https://github.com/evmts/zevm/releases/download/<releaseIdentifier>/release-tuple.json`
- `release-tuple.json` must be valid UTF-8 JSON and must contain exactly these required fields (no additional fields): `schemaVersion`, `releaseIdentifier`, `zevmGitRevision`, `voltaireGitRevision`, `guillotineMiniGitRevision`, `zigVersion`
- `schemaVersion` must be the literal string `zevm-release-tuple.v1`
- `releaseIdentifier` must exactly equal the publishing `releaseIdentifier`
- `zevmGitRevision`, `voltaireGitRevision`, and `guillotineMiniGitRevision` must each be full immutable git commit IDs; `zigVersion` must be one exact Zig version string
- release tuple values for a published release identifier are immutable; correction is append-only and must publish a new release identifier with its own `release-tuple.json`
- operators source sibling commit pins only from the selected release `release-tuple.json`, then materialize them by checking out each repository at its pinned commit
- operators verify the tuple locally before build by confirming `git rev-parse HEAD` in `.` / `../voltaire` / `../guillotine-mini` equals the pinned commit ID for each repository and `zig version` equals the pinned `zigVersion`
- operators must preserve the exact release tuple (all four values plus the ZEVM release identifier used) in any downstream deployment manifest or runbook so the same boundary can be reconstructed later
- for unreleased commit builds, operators must self-record `(zevmGitRevision, voltaireGitRevision, guillotineMiniGitRevision, zigVersion)` from local checkout/toolchain state in downstream provenance records; release-metadata discovery is unavailable and no metadata-backed `releaseIdentifier` value exists for that record
- phase 1 deliberately does not define a runtime JSON-RPC or CLI surface to directly report `releaseIdentifier`; this is an explicit product boundary, not an unresolved gap
- release/build identity for phase 1 is established from preserved operator provenance records, and phase 1 does not require ZEVM runtime/CLI to expose or synthesize missing release metadata for unreleased commit builds

Baked default checkpoint artifact (`light-default-checkpoints.json`):

- each ZEVM `releaseIdentifier` must publish exactly one machine-readable asset named `light-default-checkpoints.json` at `https://github.com/evmts/zevm/releases/download/<releaseIdentifier>/light-default-checkpoints.json`
- `light-default-checkpoints.json` must be valid UTF-8 JSON with exactly these top-level fields (no additional top-level fields): `schemaVersion`, `releaseIdentifier`, `defaults`
- `schemaVersion` must be the literal string `zevm-light-default-checkpoints.v1`
- `releaseIdentifier` must exactly equal the publishing `releaseIdentifier`
- `defaults` must be an object with exactly these keys (no additional keys): `mainnet`, `sepolia`, `holesky`
- `defaults.mainnet`, `defaults.sepolia`, and `defaults.holesky` must each be a `0x`-prefixed 32-byte hash (`Hash32`) and must exactly equal the baked default checkpoint bundled for that network in that release/build artifact
- `light-default-checkpoints.json` values for a published release identifier are immutable; correction is append-only and must publish a new release identifier with its own `light-default-checkpoints.json`
- operators deterministically discover per-network baked defaults for a release/build from that release's `light-default-checkpoints.json`; runtime probing via `zevm_lightSyncStatus` is optional verification, not required discovery
- deterministic baked-default discovery from release metadata is defined only for published release identifiers
- for unreleased commit builds without published `light-default-checkpoints.json`, baked defaults remain implementation-defined and are not contract-discoverable from metadata
- operators that require deterministic checkpoint selection for unreleased commit builds must provide an explicit checkpoint via CLI/config instead of relying on baked defaults
- in light mode, `checkpointSource` records whether startup checkpoint selection was `explicit`, `persisted`, or `default` (section 10), providing runtime provenance for startup checkpoint selection behavior

Release metadata conformance and artifact-failure handling:

- for a published `releaseIdentifier`, metadata-backed reproducibility is valid only when both required artifacts are present exactly once (`release-tuple.json`, `light-default-checkpoints.json`) and both artifacts satisfy every field/schema/invariant requirement in this section
- publication-time validation gate is mandatory for canonical publication claims: before a release is treated or announced as canonical under this contract, CI/release automation must validate both required artifacts (`release-tuple.json`, `light-default-checkpoints.json`) from the published release assets against every requirement in this section
- publication-time gate failure on either required artifact (including missing, duplicate, unreadable, malformed, schema-mismatched, or value-mismatched payloads) blocks canonical publication claims for that `releaseIdentifier`
- for a published `releaseIdentifier`, any missing asset, duplicate asset, unreadable asset, malformed UTF-8/JSON payload, schema-version mismatch, `releaseIdentifier` mismatch, or value-level mismatch against this section's constraints makes that `releaseIdentifier` metadata-invalid for reproducibility purposes
- for a metadata-invalid published `releaseIdentifier`, operators must not treat that identifier as inside the metadata-backed reproducibility boundary and must not use it as authoritative deterministic metadata evidence
- metadata-invalid published identifiers remain auditable historical records only; restoration of metadata-backed reproducibility requires publishing a correction release with a new `releaseIdentifier` and corrected artifacts
- metadata-invalid release artifacts must not be repaired in place under the same `releaseIdentifier`; correction remains append-only through a new `releaseIdentifier`
- phase 1 does not require runtime/CLI discovery, repair, or reporting of metadata-invalid release artifacts; this remains an operator provenance workflow outside runtime API surfaces

Operator release/provenance flow contract:

- metadata-backed published-release flow is strict and ordered: select one published `releaseIdentifier` -> fetch both required assets from that identifier -> validate section 3.4 invariants -> materialize pinned repository commits/toolchain -> run source build
- the `releaseIdentifier` used for asset fetch, tuple validation, and provenance recording must be the same identifier; mixing assets or tuples across identifiers is invalid
- operators must persist one downstream provenance record per build containing: provenance state (`metadata-backed` or `unreleased-commit`), ZEVM `releaseIdentifier` when metadata-backed, and the full pin tuple `(zevmGitRevision, voltaireGitRevision, guillotineMiniGitRevision, zigVersion)`
- unreleased-commit flow has no release-asset discovery step: operators derive tuple values from local checkouts/toolchain state, record provenance as `unreleased-commit`, and must not populate that record with a synthesized or guessed metadata-backed `releaseIdentifier`

Correction-release supersession note contract:

- a correction release is any new `releaseIdentifier` published to supersede metadata errors in one previously published `releaseIdentifier`
- every correction release must include exactly one operator-visible supersession note in that release's GitHub release notes body under heading `## ZEVM Supersession Note`
- immediately below that heading, the note must contain exactly this four-line key set, in this order, with single-line values:

```text
schemaVersion: zevm-supersession-note.v1
supersedesReleaseIdentifier: v0.6.1
correctedArtifacts: release-tuple.json
reason: Fixed release-tuple.json zevmGitRevision value mismatch.
```

- `schemaVersion` must be the literal string `zevm-supersession-note.v1`
- `supersedesReleaseIdentifier` must be one valid previously published `releaseIdentifier` being superseded by the correction release
- `correctedArtifacts` must be exactly one of: `release-tuple.json`, `light-default-checkpoints.json`, or `both`
- `reason` must be non-empty UTF-8 text on one line and must describe the corrected metadata defect
- superseded release assets remain unchanged for auditability

### 3.5 Release qualification and verification acceptance criteria

Phase-1 release qualification requires all criteria below to pass for the candidate source state and pinned sibling/toolchain tuple.

- clean-checkout source-build verification: from a clean checkout of the pinned ZEVM/Voltaire/`guillotine-mini` commits, `zig build` and `zig build test` must both succeed without manual sibling repair, ad-hoc path rewriting, or post-checkout dependency edits
- shipped phase-1 surface definition: a shipped surface is any normative phase-1 behavior requirement in this PRD sections 3.1, 3.3, 3.4, and 4 through 12, excluding section 3.2 out-of-scope items
- assertion mapping record definition: each record must identify exactly one shipped surface and include, at minimum, `surfaceId`, `surfaceSection`, `surfaceCategory` (`startup`, `configuration`, `runtime`, `transport`, `method`, or `release-asset`), `assertionType` (`default-graph-test` or `release-asset-validation`), `assertionIdentifier`, and expected contract outcome
- default test-graph shipping coverage: the default `zig build test` graph means the tests executed by invoking `zig build test` from repository root with no additional target selection; that default graph must cover shipped executable startup/configuration/runtime/transport/method behaviors from sections 3.1 and 4 through 12
- release-qualification coverage evidence: qualification records must include assertion mapping records for every shipped phase-1 surface in sections 3.1, 3.3, 3.4, and 4 through 12; unmapped surfaces fail qualification unless they are explicitly reclassified non-shipping in this PRD
- actionable coverage category expectation: qualification records must show explicit mapping rows for startup/configuration semantics (section 5), runtime and lifecycle semantics (sections 4, 8, 9, 10, 11, 12), transport semantics (section 6), method tuple/error semantics for in-scope methods (section 7 plus `docs/specs/json-rpc-contract.md`), and release-asset semantics (sections 3.3 and 3.4)
- method-semantics mapping expectation: for each shipped method family in section 3.1 and section 7 scope, mapping records must identify at least one assertion that verifies success/unsupported/readiness/error semantics that are normative for that family
- release-metadata artifact qualification acceptance: for any candidate claiming a published `releaseIdentifier` under the section 3.4 metadata-backed reproducibility boundary, qualification must validate both required release assets (`release-tuple.json`, `light-default-checkpoints.json`) and all section 3.4 location/exactly-once/schema/value invariants from published release assets; any artifact conformance failure disqualifies that candidate from qualification under that boundary
- release-asset mapping expectation: qualification records for metadata-backed candidates must include explicit `release-asset` mapping rows for both required assets, including URL/identifier binding, schema-field conformance, and cross-field equality checks required by section 3.4
- listener/socket smoke verification: release verification must include automated smoke coverage that binds the real HTTP listener socket and validates startup/request flow for trusted mode and for light-mode startup plus restart/resume from persisted checkpoint input path
- transport/parsing shipping-path verification: release verification must assert notification-only request and notification-only batch behavior returns HTTP `204` with empty body, and the shipping path must use one canonical ZEVM-owned HTTP transport/parser stack for request parsing and envelope dispatch (section 12 ownership boundary), not divergent production parser stacks

## 4. Runtime Modes

Implementation support context (non-normative): `docs/specs/internal/runtime-modes-and-boundaries.md`, `docs/specs/internal/trusted-mode-semantics.md`, `docs/specs/internal/light-mode-semantics.md`.

### 4.1 Trusted mode

Trusted mode is the default runtime. It provides local execution and local mutation with optional fork backing.

Trusted-mode defaults:

- `chainId`: `31337` (`0x7a69`)
- 10 deterministic managed dev accounts
- `coinbaseIndex`: `0`
- `initialBalance`: `10000000000000000000000` wei per managed account (10000 ETH)
- `gasPrice`: `2000000000`
- `baseFee`: `1000000000`
- `blobBaseFee`: `1`
- `maxPriorityFeePerGas`: `1000000000`
- `blockGasLimit`: `30000000`
- mining mode: `auto`
- hardfork policy: explicit dev schedule with Cancun active from genesis and Prague/Osaka inactive until configured

Managed dev-wallet contract (exact):

- mnemonic: `test test test test test test test test test test test junk`
- derivation path root: `m/44'/60'/0'/0/`
- initial index: `0`
- account count: `10`
- `eth_accounts` returns these addresses in index order
- `eth_sendTransaction` may sign only for these managed accounts unless impersonation is active

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

Trusted block tags:

- `latest`: current local head
- `pending`, `safe`, `finalized`: aliases of `latest`
- `earliest`: block `0`
- numeric: exact local block number

Trusted runtime fork-source controls are part of product scope:

- `zevm_reset`: resets trusted local runtime state and can keep, disable, or replace fork backing depending on params
- `zevm_setRpcUrl`: updates the active fork URL in place when forking is enabled, without resetting local chain state

Trusted snapshot/revert boundary:

- `zevm_snapshot`/`zevm_revert` capture and restore trusted local runtime state (local chain/state/journal, receipt/log indexes, tx pool, mining/block-environment overrides, impersonation, and time controls)
- `zevm_snapshot`/`zevm_revert` do not capture or restore light-mode consensus/checkpoint-sync state and do not mutate remote fork-source state

### 4.2 Light mode

Light mode is read-only and proof-backed.

Supported networks and fixed chain IDs:

- `mainnet` -> `0x1`
- `sepolia` -> `0xaa36a7` (11155111)
- `holesky` -> `0x4268` (17000)

Light network-set governance:

- phase-1 light-network set is closed and exact: `mainnet`, `sepolia`, `holesky`
- any other `network` value is invalid startup input and must fail before opening the HTTP listener
- each supported light network must have all normative network-specific mappings required by this PRD: fixed chain ID mapping (this section), startup handshake `genesis_validators_root` mapping (section 5), and baked-default checkpoint eligibility in startup checkpoint precedence (section 5)
- adding, removing, or renaming a supported light network is a normative contract change and requires synchronized updates to this PRD and to JSON-RPC network-enum surfaces in `docs/specs/json-rpc-contract.md`

Light block selectors:

- `latest`: latest verified optimistic execution head
- `safe`: consensus-backed safe execution head
- `finalized`: consensus-finalized execution head
- `earliest`: block `0`
- numeric: when `ready = true`, allowed set is `{0}` union `[max(1, H - 8190), H]`, where `H` is current light `latest` (retained window size `8191`)
- `pending`: selector token is recognized but unsupported in light mode (`-32010`); it does not alias `latest`

Light readiness rule:

- readiness gating applies to proof-backed reads and `eth_blockNumber` only
- `eth_chainId` and `zevm_lightSyncStatus` are always callable in light mode regardless of `ready`
- `ready` is derived runtime state (not operator-configurable) and is defined against verified light heads
- proof-backed reads are allowed only when `ready = true`
- light-mode proof-backed read evaluation order is exact:
  1. malformed tuple/field/encoding input (including malformed selector token) -> `-32602`
  2. selector `pending` -> `-32010`
  3. `ready = false` -> `-32011` for all remaining selectors, including numeric selectors that would be outside retained history
  4. when `ready = true`, numeric selector outside retained set `{0}` union `[max(1, H - 8190), H]` -> `-32602`
  5. when `ready = true`, malformed upstream proof payload -> `-32015`
  6. when `ready = true`, well-formed proof payload that fails verification against resolved state root -> `-32014`
- `eth_blockNumber` fails with `-32011` when `ready = false`
- when `ready = true`, `eth_blockNumber` returns the light-mode `latest` head number
- for `eth_blockNumber`, non-empty params still fail first with `-32602`; readiness gating is the next check (`-32011`)
- `zevm_lightSyncStatus` fields/invariants (including `ready`/`status` coupling, `checkpointSource`, `lastCheckpoint`, slot-field constraints, and lifecycle implications) are defined canonically in section 10 and apply uniformly to light-mode behavior in this section
- phase-1 operator-facing light-mode startup inputs are `--network`, `--consensus-rpc-url`, `--execution-rpc-url`, `--checkpoint`, `--checkpoint-dir`, `--max-checkpoint-age-seconds`, and `--strict-checkpoint-age`
- `--execution-rpc-url` is the execution JSON-RPC source used for proof-backed execution reads
- no additional operator-facing proof-source tuning knobs are part of the phase-1 public contract

Light sync lifecycle (`status`/`ready`):

- listener-start state must be `status = "syncing"` and `ready = false`
- `syncing -> synced`: initial light sync has accepted verified optimistic, safe, and finalized heads; this transition must also set `ready = true`
- `syncing -> error`: light sync fails after listener startup; `ready` remains `false`
- `synced -> error`: previously synced runtime later fails to advance/verify or loses slot coherence; this transition must also set `ready = false`
- while `status = "syncing"` or `status = "error"`, proof-backed reads and `eth_blockNumber` stay gated (`-32011`)
- recovery from `status = "error"` in phase 1 requires operator action: fix upstream/configuration cause and restart ZEVM

## 5. Startup And Configuration

Implementation support context (non-normative): `docs/specs/internal/startup-and-configuration.md`.

### 5.1 Shared CLI

| Flag | Type | Default |
| --- | --- | --- |
| `--config` | JSON file path | none |
| `--mode` | `trusted` or `light` | `trusted` (effective only when neither user-supplied `--mode` nor `--config` selects mode; if `--config` is provided it must include exactly one `mode` branch, and user-supplied `--mode` must match that branch) |
| `--host` | bind host | `127.0.0.1` |
| `--port` | TCP port | `8545` |
| `--engine-host` | Engine API bind host | disabled unless Engine API is enabled |
| `--engine-port` | Engine API TCP port | `8551` when Engine API is enabled |

### 5.2 Trusted-mode CLI

| Flag | Type | Default |
| --- | --- | --- |
| `--chain-id` | `u64` | `31337` |
| `--coinbase-index` | integer `0..9` | `0` |
| `--initial-balance` | decimal wei string | `10000000000000000000000` |
| `--gas-price` | decimal wei string | `2000000000` |
| `--base-fee` | decimal wei string | `1000000000` |
| `--blob-base-fee` | decimal wei string | `1` |
| `--max-priority-fee-per-gas` | decimal wei string | `1000000000` |
| `--block-gas-limit` | `u64` | `30000000` |
| `--mining` | `auto`, `manual`, `interval` | `auto` |
| `--block-time` | seconds (`u64`) | none |
| `--fork-url` | execution RPC URL | none |
| `--fork-block-number` | `u64` | none |
| `--genesis` | genesis JSON path | none |
| `--chain-rlp` | concatenated RLP block stream path | none |
| `--engine-host` | Engine API bind host | disabled unless Engine API is enabled |
| `--engine-port` | Engine API TCP port | `8551` when Engine API is enabled |

Trusted-mode validation:

- `--block-time` is required when `--mining interval`
- `--block-time` is invalid for `auto` and `manual`
- `--fork-block-number` is invalid without `--fork-url`
- when `--fork-url` is provided and `--fork-block-number` is omitted, startup forking uses unpinned upstream-head (`latest`) semantics
- `--genesis`, `--chain-rlp`, `--engine-host`, and `--engine-port` are trusted-mode only
- Engine API is disabled unless `--engine-host`, `--engine-port`, or top-level config `engineRpc` is supplied
- trusted-only flags are invalid in light mode
- trusted startup fork block numbers use decimal `u64` in CLI/config (`--fork-block-number`, `mode.trusted.fork.blockNumber`)
- runtime `zevm_reset` uses `QuantityHex` for `forkConfig.blockNumber`; example: startup decimal `1000000` corresponds to JSON-RPC `"blockNumber": "0xf4240"`

### 5.3 Light-mode CLI

| Flag | Type | Default |
| --- | --- | --- |
| `--network` | `mainnet`, `sepolia`, `holesky` | `mainnet` |
| `--consensus-rpc-url` | Beacon API URL | required |
| `--execution-rpc-url` | Execution JSON-RPC URL with `eth_getProof`/`eth_getCode` | `--consensus-rpc-url` |
| `--checkpoint` | `0x`-prefixed 32-byte hash | none |
| `--checkpoint-dir` | directory path | `.zevm/checkpoints/<network>` |
| `--max-checkpoint-age-seconds` | `u64` | `1209600` |
| `--strict-checkpoint-age` | presence flag | `false` |

Light-mode startup naming/path bridge:

- CLI startup flags map to config keys by hyphenated-to-camelCase naming: `--network` -> `network`, `--consensus-rpc-url` -> `consensusRpcUrl`, `--execution-rpc-url` -> `executionRpcUrl`, `--checkpoint` -> `checkpoint`, `--checkpoint-dir` -> `checkpointDir`, `--max-checkpoint-age-seconds` -> `maxCheckpointAgeSeconds`, `--strict-checkpoint-age` -> `strictCheckpointAge`
- `--checkpoint-dir` default template is `.zevm/checkpoints/<network>`; `<network>` expands from resolved startup `network` after CLI/config merge
- after CLI/config merge and `<network>` expansion, any relative `checkpointDir` value (including the default `.zevm/checkpoints/<network>`) is resolved against the process current working directory at startup
- persisted checkpoint startup input path is `${resolvedCheckpointDir}/checkpoint`, where `resolvedCheckpointDir` is the absolute path after that resolution step

Light-mode validation:

- `--network`/`mode.light.network` must be one of `mainnet`, `sepolia`, or `holesky`
- `--consensus-rpc-url` is required in light mode
- `--consensus-rpc-url` must serve the same network selected by `--network`
- `--strict-checkpoint-age` CLI semantics are presence-based: present means `true`, omitted means `false`, and explicit assignment forms (for example `--strict-checkpoint-age=false`) are invalid
- checkpoint startup inputs from CLI/config are nullable for precedence selection: `--checkpoint` absent and `mode.light.checkpoint` absent or `null` are treated as absent startup inputs
- only non-null CLI/config checkpoint values (`--checkpoint`, `mode.light.checkpoint`) must be `0x`-prefixed 32-byte hashes (`Hash32`)
- selected startup checkpoint hash must resolve on the configured light network via the configured consensus source (`--consensus-rpc-url`); network mismatch is startup failure before opening the HTTP listener
- light-only flags are invalid in trusted mode

Light-mode startup consensus-network handshake (before listener):

1. resolve startup settings (`network`, `consensusRpcUrl`, selected startup checkpoint)
2. call `GET <consensusRpcUrl>/eth/v1/beacon/genesis`
3. require HTTP `200` and a parseable `data.genesis_validators_root` (`Hash32`)
4. require `data.genesis_validators_root` to match selected `--network`:
   - `mainnet` -> `0x4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95`
   - `sepolia` -> `0xd8ea171f3c94aea21ebc42a1ed61052acf3f9209c00e4efbaaddac09ed9b8078`
   - `holesky` -> `0x9143aa7c615a7f7115e2b6aac319c03529df8242ae705fba9df39b79c59fa8b1`
5. any handshake failure (request failure, non-`200`, malformed payload, missing/invalid root, root mismatch) is startup failure before opening the HTTP listener

### 5.4 Config file schema

`--config` loads one JSON file containing shared RPC settings and exactly one mode branch.

Trusted-mode example:

```json
{
  "rpc": { "host": "127.0.0.1", "port": 8545 },
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
      "mining": { "type": "auto" },
      "hardfork": {
        "cancunTimestamp": 0,
        "pragueTimestamp": 9223372036854775807,
        "osakaTimestamp": 9223372036854775807
      },
      "fork": null
    }
  }
}
```

Light-mode example:

```json
{
  "rpc": { "host": "127.0.0.1", "port": 8545 },
  "mode": {
    "light": {
      "network": "mainnet",
      "consensusRpcUrl": "https://beacon.example",
      "executionRpcUrl": "https://execution.example",
      "checkpoint": null,
      "checkpointDir": ".zevm/checkpoints/mainnet",
      "maxCheckpointAgeSeconds": 1209600,
      "strictCheckpointAge": false
    }
  }
}
```

Config rules:

- allowed top-level keys are `rpc` and `mode`; unknown top-level keys are invalid
- unknown keys inside `rpc`, `mode`, `mode.trusted`, `mode.light`, and trusted structured objects (`mining`, `hardfork`, `fork`) are invalid
- `rpc` is optional; when omitted, shared defaults apply (`host = 127.0.0.1`, `port = 8545`)
- when `rpc` is present, `host` and `port` default independently if omitted
- `mode` must contain exactly one of `trusted` or `light`
- config containing both branches is invalid
- config containing neither branch is invalid
- an explicitly user-supplied `--mode` must match the config mode branch when both are present

Trusted config object sub-shapes (exact):

- `mode.trusted.mining` must be exactly one of `{ "type": "auto" }`, `{ "type": "manual" }`, or `{ "type": "interval", "blockTime": <u64> }`
- for `mode.trusted.mining`, `blockTime` is required only for `type = "interval"` and invalid for `type = "auto"` and `type = "manual"`
- `mode.trusted.hardfork` is an optional object of decimal `u64` activation overrides; allowed keys are `homesteadBlock`, `daoBlock`, `tangerineWhistleBlock`, `spuriousDragonBlock`, `byzantiumBlock`, `petersburgBlock`, `istanbulBlock`, `muirGlacierBlock`, `berlinBlock`, `londonBlock`, `arrowGlacierBlock`, `grayGlacierBlock`, `mergeBlock`, `shanghaiTimestamp`, `cancunTimestamp`, `pragueTimestamp`, `osakaTimestamp`, and `secondsPerSlot`
- default hardfork policy is explicit: `chainId = 1` uses the mainnet activation schedule, while non-mainnet trusted defaults use a dev schedule with Cancun active from genesis and Prague/Osaka inactive until configured
- `mode.trusted.fork` must be exactly one of `null`, `{ "url": "<execution-rpc-url>" }`, or `{ "url": "<execution-rpc-url>", "blockNumber": <u64> }`
- for `mode.trusted.fork`, `blockNumber` is invalid without `url`
- for `mode.trusted.fork`, `{ "url": "<execution-rpc-url>" }` uses unpinned upstream-head (`latest`) semantics; adding `blockNumber` pins fork reads to that block

### 5.5 Precedence

Startup precedence:

1. user-supplied CLI flag values
2. config file values
3. persisted light checkpoint (light mode only)
4. mode defaults

Precedence scope clarification for light mode:

- precedence item 3 applies only to startup checkpoint selection
- `checkpointDir`, `maxCheckpointAgeSeconds`, and `strictCheckpointAge` resolve independently per field as: user-supplied CLI value > config value > mode default
- persisted `${resolvedCheckpointDir}/checkpoint` does not set or override `checkpointDir`, `maxCheckpointAgeSeconds`, or `strictCheckpointAge`

CLI/config merge rules:

- only user-supplied CLI flags participate in precedence over config
- parser-provided CLI defaults are applied only after CLI/config merge to fill unset fields
- parser-provided CLI defaults are not treated as user overrides and do not create mode conflicts
- mode conflict exists only when user-supplied `--mode` disagrees with the config mode branch

Structured trusted-setting resolution:

- `mining` resolves as one unit from CLI `--mining` and `--block-time`; if either flag is present, ZEVM builds `mining` from CLI and ignores `mode.trusted.mining`
- `hardfork` has no phase-1 CLI flags; ZEVM starts from the default schedule for the resolved `chainId`, then applies any `mode.trusted.hardfork` field overrides
- `fork` resolves as one unit from CLI `--fork-url` and `--fork-block-number`; if either flag is present, ZEVM builds `fork` from CLI and ignores `mode.trusted.fork`
- when no related CLI flags are present for that unit, ZEVM uses config value for that unit, then mode default
- resolved trusted `fork` with `url` and no `blockNumber` uses unpinned upstream-head (`latest`) semantics; resolved trusted `fork` with `blockNumber` is pinned to that block

Checkpoint selection precedence in light mode:

1. user-supplied CLI checkpoint (`--checkpoint`), when provided and non-null
2. config checkpoint (`mode.light.checkpoint`), when set to a non-null value
3. persisted `${resolvedCheckpointDir}/checkpoint`
4. baked network default checkpoint

This precedence is strict: CLI checkpoint > config checkpoint > persisted checkpoint file > baked default.

Precedence fallthrough is absence-driven only: ZEVM advances to a lower-precedence checkpoint source only when the higher-precedence source is absent. For CLI/config checkpoint inputs, absence includes omitted values and config `null`.

Once a checkpoint source is selected by precedence, that selected source is final for that startup attempt; any selected-source unreadable, malformed, network-mismatch, or derivation failure must fail startup before opening the HTTP listener, and ZEVM must not fall back to lower-precedence checkpoint sources. Staleness is evaluated separately by section 5.7 and only fails startup when `strictCheckpointAge = true`.

Reporting terms used in this section:

- `checkpointSource` and `lastCheckpoint` are `zevm_lightSyncStatus` fields; canonical definitions and invariants are in section 10

If CLI checkpoint, config checkpoint, and persisted `${resolvedCheckpointDir}/checkpoint` are all absent, ZEVM selects the baked network default checkpoint and `checkpointSource = "default"`. Here, "absent" includes config `mode.light.checkpoint = null`.

Baked default checkpoints are precedence inputs, not frozen public compatibility hashes.

Baked default checkpoint values are ZEVM bundled release/build inputs. For a given ZEVM release/build artifact and network, the selected baked default is deterministic.

For each supported light network, each ZEVM release/build artifact must bundle one baked default checkpoint value that can win checkpoint precedence when no higher-precedence checkpoint input is present.

Baked defaults are implementation-defined and may rotate across releases/builds.

Canonical release metadata artifact requirements and provenance boundaries for baked defaults are defined in section 3.4 and apply unchanged here.

### 5.6 Persisted checkpoint file contract

Persisted checkpoint input contract in light mode:

- file path: `${resolvedCheckpointDir}/checkpoint`, where `resolvedCheckpointDir` is derived from merged `checkpointDir` by applying `<network>` expansion and then resolving relative paths against startup current working directory
- if `${resolvedCheckpointDir}` does not exist at startup (including a missing expanded `<network>` directory), persisted checkpoint input is treated as absent and precedence falls through
- if `${resolvedCheckpointDir}/checkpoint` is missing, persisted checkpoint input is treated as absent and precedence falls through
- file content is read as text and trimmed for leading/trailing whitespace before validation
- trimmed content must be exactly 64 hex characters (32-byte hash) with no `0x` prefix
- this format split is intentional: CLI/config checkpoint inputs use `0x`-prefixed 32-byte hashes, while persisted `${resolvedCheckpointDir}/checkpoint` uses 64 hex characters without `0x`
- `lastCheckpoint` referenced below is the `zevm_lightSyncStatus` runtime field defined canonically in section 10
- if the file exists but is unreadable, startup fails before opening the HTTP listener
- if the file is readable but trimmed content is malformed, startup fails before opening the HTTP listener (`-32013`, reserved startup code)
- ZEVM does not auto-create `${resolvedCheckpointDir}` (including `<network>` directory expansion targets) during startup
- in phase 1, ZEVM treats `${resolvedCheckpointDir}/checkpoint` as startup input only and does not create, update, or delete this file during runtime
- seeding and management are operator-only workflows: operators seed `${resolvedCheckpointDir}/checkpoint` by creating/updating it before process start or between restarts
- ZEVM does not seed `${resolvedCheckpointDir}/checkpoint` from baked defaults, explicit startup checkpoint inputs, or `lastCheckpoint` at startup, runtime, or shutdown
- startup reads `${resolvedCheckpointDir}/checkpoint` once as part of precedence resolution; runtime writes or external file changes after listener start do not change the active process checkpoint source
- `lastCheckpoint` progression reported by `zevm_lightSyncStatus` is process-local runtime state and is not persisted to `${resolvedCheckpointDir}/checkpoint` in phase 1
- operators may manage `${resolvedCheckpointDir}/checkpoint` between restarts; startup checkpoint precedence is re-evaluated on every process start

### 5.7 Checkpoint age policy

Checkpoint staleness policy in light mode:

- `age` is ZEVM's startup-time freshness value for the selected startup checkpoint
- `age` is evaluated once during startup, after checkpoint selection and before stale-policy decision
- `age` is measured in whole seconds: `age = max(0, startupTimeSeconds - checkpointTimeSeconds)`
- `startupTimeSeconds` is sampled at age-check time
- `checkpointTimeSeconds` is derived deterministically from Beacon API data for the selected startup checkpoint hash on the selected network, using the configured consensus source (`--consensus-rpc-url`) and not filesystem metadata/local file times
- derivation steps are exact:
  1. call `GET <consensusRpcUrl>/eth/v1/beacon/genesis`, require HTTP `200`, parse `data.genesis_time` as decimal unsigned integer `genesisTimeSeconds`
  2. call `GET <consensusRpcUrl>/eth/v1/beacon/headers/{selectedCheckpointHash}`, require HTTP `200`, parse `data.root` as `Hash32` and require it to equal `selectedCheckpointHash`, then parse `data.header.message.slot` as decimal unsigned integer `checkpointSlot`
  3. use `SECONDS_PER_SLOT = 12` for phase-1 supported light networks (`mainnet`, `sepolia`, `holesky`) and compute `checkpointTimeSeconds = genesisTimeSeconds + (checkpointSlot * SECONDS_PER_SLOT)` with integer arithmetic
  4. use computed `checkpointTimeSeconds` as integer Unix seconds in age evaluation
- any request failure, non-`200`, missing/malformed required field, checkpoint-root mismatch, or arithmetic overflow in this derivation is inability to resolve `checkpointTimeSeconds` and is startup failure before opening the HTTP listener
- `age == maxCheckpointAgeSeconds` is valid
- only `age > maxCheckpointAgeSeconds` is stale
- stale + `strictCheckpointAge = false`: emit one operator-facing startup warning before opening the HTTP listener, then continue startup
- this non-strict stale warning must be emitted on process `stderr` during startup and must not rely on JSON-RPC visibility
- the non-strict stale warning must include: selected checkpoint hash, `checkpointSource`, `checkpointTimeSeconds`, `startupTimeSeconds`, computed `age`, `maxCheckpointAgeSeconds`, and `strictCheckpointAge = false`
- stale + `strictCheckpointAge = true`: startup failure before opening the HTTP listener (`-32012`, reserved startup code)

### 5.8 Startup failure behavior

ZEVM must fail before opening the HTTP listener for invalid startup input, including:

- unknown flags
- missing flag values
- invalid integer or wei values
- explicit `--mode` mismatch with config mode branch
- invalid trusted/light flag mixing
- missing required light-mode consensus URL
- light-mode consensus endpoint/network mismatch
- light-mode startup consensus-network handshake failure (`GET /eth/v1/beacon/genesis` request failure, non-`200`, malformed payload, missing/invalid `data.genesis_validators_root`, or root mismatch with selected network)
- selected startup checkpoint/network mismatch
- invalid mining option combinations
- invalid fork option combinations
- invalid `coinbaseIndex`
- stale selected checkpoint when `strictCheckpointAge = true` (`-32012`, reserved startup code)
- inability to resolve `checkpointTimeSeconds` for the selected startup checkpoint
- malformed checkpoint input or malformed checkpoint file (`-32013`, reserved startup code)
- once a checkpoint source is selected by startup precedence, selected-source unreadable, malformed, network-mismatch, and derivation failures are terminal for that startup attempt and must not trigger fallback to lower-precedence checkpoint sources; staleness is evaluated by section 5.7 and only fails startup when `strictCheckpointAge = true`
- `-32012` and `-32013` are startup-phase reserved checkpoint codes and are not emitted after the HTTP listener has started
- `--config` load failure (missing file, unreadable file, or malformed JSON): startup fails before opening the HTTP listener, exits non-zero, reports an operator-facing error naming the config path and failure class, and does not fall back to defaults
- startup-failure errors in this section are operator-facing startup logs emitted on process `stderr`

### 5.9 Startup logging surface

- operator-facing startup warnings and startup-failure errors are emitted via process `stderr`
- phase 1 does not define dedicated CLI/config controls for startup log level, log file paths, or alternative log sinks
- any capture/routing of startup `stderr` output is external process/shell responsibility

### 5.10 Runtime observability surface

- runtime logs are JSON records on process `stderr`
- request telemetry uses `scope = "rpc"` and message fields: `rpc_request`, `method`, `id_present`, `batch_size`, `status`, `error_code`, `duration_us`, and `mode`
- listener lifecycle logs use `scope = "rpc"` for bind/stop, accept failures, connection accept/close, timeout setup failures, and connection-level failures
- mining logs use `scope = "mining"` for interval-mining lifecycle/tick failures and mined blocks (`number`, `hash`, `tx_count`, `gas_used`, `pool_pending`, `pool_queued`, `mode`)
- tx submission logs use `scope = "txpool"` for accepted transactions (`source`, `hash`, `sender`, `nonce`, `gas_limit`, `pool_pending`, `pool_queued`, `mining_mode`)
- light sync logs use `scope = "consensus_sync"` for checkpoint selection, stale checkpoint warnings, sync status transitions, upstream request failures, proof verification failures, checkpoint advancement, and sync failures
- trusted fork upstream failures use `scope = "fork"` and include method/error context without logging upstream URLs or request params
- runtime logs must not include raw JSON-RPC bodies, request params, private keys, raw transaction bytes, auth-bearing upstream URLs, or proof payload bodies by default

## 6. JSON-RPC Transport

Implementation support context (non-normative): `docs/specs/internal/transport-and-error-semantics.md`.

Transport requirements:

- HTTP only; JSON-RPC is served only on `POST /`
- no built-in TLS termination or JSON-RPC authentication in phase 1
- request path other than `/`: HTTP `404` with no JSON-RPC body
- non-`POST` to `/`: HTTP `405` with no JSON-RPC body
- `POST /` request content type must be `application/json` (media-type parameters allowed); otherwise HTTP `415` with no JSON-RPC body
- JSON-RPC success and error envelopes: HTTP `200`
- notification-only request/batch: HTTP `204`, empty body
- batch responses preserve the input order of batch entries that include `id`
- request bodies larger than `1,048,576` bytes: HTTP `413`, empty body
- phase-1 transport limits are fixed: `8,192` byte HTTP header buffer, `64` active TCP connections, `15,000` ms read timeout, and `15,000` ms write timeout
- slow clients must not block unrelated accepted clients; JSON-RPC handler dispatch remains serialized within one ZEVM process to avoid runtime-state races
- production server lifecycle must expose a stop hook that stops accepting, shuts down active connection sockets, and waits for active handlers before listener deinit returns
- one canonical ZEVM-owned HTTP transport/parser stack is the shipping path for request parsing and envelope dispatch; divergent production parser stacks are out of contract for phase 1
- JSON-RPC envelope semantics (single requests, batches, empty-batch behavior, notifications, mixed batches, ordering, and `id` handling) are defined in `docs/specs/json-rpc-contract.md` and are authoritative

## 7. JSON-RPC Method Surface

The exact method surface (methods, params, results, aliases, and error mappings) is defined canonically in `docs/specs/json-rpc-contract.md`.

Light-mode availability and selector handling remain governed by this PRD:

- readiness gating in section 4.2 applies to proof-backed reads and `eth_blockNumber`
- numeric selector/window rules in section 10 apply when light mode is ready
- phase-1 transaction/receipt/log payload contract excludes nonstandard `blockTimestamp` extension fields (see `docs/specs/json-rpc-contract.md`)

## 8. Trusted-Mode Mining Semantics

Trusted mining modes are exact:

- `auto`: each accepted executable transaction triggers immediate sealing of one block; no timer-based empty blocks
- `manual`: transactions queue only; blocks seal only through explicit mine RPC
- `interval`: a timer seals one block every `blockTime` seconds, including empty blocks

Timestamp rules:

- block timestamps must be strictly increasing (`child.timestamp > parent.timestamp`)
- interval-mined blocks progress by interval cadence
- manually mined multi-block calls advance timestamp per mined block

Detailed RPC-level mining behavior is defined in `docs/specs/json-rpc-contract.md`.

## 9. Fee Model And Transaction Types

Phase-1 transaction request and submission contract:

- accepted request-object fields are the `TransactionRequest` fields in `docs/specs/json-rpc-contract.md`
- unsupported tx-request fields fail with `-32602`
- only legacy transaction type `0x0` is supported for submission in phase 1
- typed EIP-2718 envelopes (`0x1`, `0x2`, `0x3`, or unknown types) are unsupported and fail with `-32602`

## 10. Light-Mode Checkpoint And History Semantics

Implementation support context (non-normative): `docs/specs/internal/light-mode-semantics.md`.

- retained verified execution history is a bounded moving window defined in `docs/specs/json-rpc-contract.md`
- retained numeric selector set when light mode is ready is `{0}` union `[max(1, H - 8190), H]`, where `H` is current light `latest` (window size `8191`)
- numeric light selectors outside the retained window fail with `-32602` when light mode is otherwise ready
- for light-mode proof-backed reads, error precedence is exact: malformed input `-32602` -> selector `pending` unsupported `-32010` -> readiness gate `-32011` -> ready-only retained-window numeric check `-32602` -> malformed upstream proof payload `-32015` -> proof verification failure `-32014`
- phase-1 canonical `zevm_lightSyncStatus` fields are `status`, `ready`, `network`, `checkpointSource`, `lastCheckpoint`, `optimisticSlot`, `safeSlot`, and `finalizedSlot`
- `status`/`ready` coupling is exact: `status = "syncing"` implies `ready = false`; `status = "synced"` implies `ready = true`; `status = "error"` implies `ready = false`
- lifecycle implications for `zevm_lightSyncStatus`: listener-start state is `status = "syncing"` with `ready = false`; first successful initial sync transition is `syncing -> synced`; failure after listener startup yields `syncing -> error` or `synced -> error`; phase-1 recovery from `error` requires operator action (fix cause + restart)
- while `status != "synced"` (equivalently `ready = false`), proof-backed reads and `eth_blockNumber` remain readiness-gated as defined in section 4.2
- `checkpointSource` in `zevm_lightSyncStatus` reflects the startup checkpoint winner and remains stable for the process lifetime:
  - `explicit`: selected from user-provided checkpoint input (CLI `--checkpoint` or config `mode.light.checkpoint`)
  - `persisted`: selected from `${resolvedCheckpointDir}/checkpoint`
  - `default`: selected from ZEVM bundled release/build default checkpoint for the selected network (deterministic for that release/build artifact; may rotate across releases/builds and is published in that release's required `light-default-checkpoints.json`)
- `lastCheckpoint` in `zevm_lightSyncStatus` is the most recently accepted checkpoint root, not the originally configured checkpoint unless no newer checkpoint has been accepted
- `lastCheckpoint` is runtime-required and non-null once the HTTP listener is active
- `optimisticSlot`, `safeSlot`, and `finalizedSlot` in `zevm_lightSyncStatus` are required non-null `QuantityHex` values and satisfy `finalizedSlot <= safeSlot <= optimisticSlot`
- `safeSlot` reports the consensus-backed safe execution head slot and makes the `safe` selector state observable/testable via `zevm_lightSyncStatus`
- in phase 1, `eth_call` and `eth_estimateGas` are trusted-only and return `-32010` in light mode; `eth_call` remains a deferred light-mode proof-backed target, and light-mode unsupported reads also include `eth_feeHistory` plus canonical block/receipt/log query methods (all mode-unsupported as `-32010`)

## 11. Compatibility Namespace Policy

Canonical nonstandard trusted-mode methods use the `zevm_*` namespace.

Accepted compatibility aliases (`anvil_*`, selected `hardhat_*`, selected legacy `evm_*`) are exactly the aliases listed in `docs/specs/json-rpc-contract.md`. Any alias not listed there is not part of the ZEVM contract.

## 12. Architecture And Ownership Boundaries

ZEVM is an integration shell with a deliberate upstream-ownership split:

- Voltaire ownership: execution primitives, JSON-RPC shared types, state manager/journal foundations, blockchain/fork-backend storage structures, and execution-layer utility primitives
- `guillotine-mini` ownership: EVM interpreter, execution host integration, and tracing substrate foundations
- ZEVM ownership: product composition, CLI/config and mode selection, runtime lifecycle orchestration, HTTP JSON-RPC transport/dispatch, mode-aware method gating, checkpoint orchestration/readiness reporting, and canonical nonstandard method naming (`zevm_*`)
- ZEVM light-mode ownership is explicit: ZEVM owns startup checkpoint source precedence and selected-source failure handling, persisted-checkpoint input contract enforcement, checkpoint-age policy enforcement, readiness/status derivation and lifecycle transitions, and mapping proof-path outcomes to contract-visible runtime behavior/codes
- upstream ownership remains explicit: Voltaire and `guillotine-mini` provide execution/interpreter/proof-related primitives consumed by ZEVM composition, while this product contract defines ZEVM-owned composition/orchestration boundaries

Runtime composition boundary:

- trusted mode: local writable execution runtime (optional fork-backed reads) with ZEVM-managed dev-node controls
- light mode: read-only consensus-anchored runtime serving proof-backed read methods with readiness gating

ZEVM does not redefine upstream execution internals in this contract; ZEVM defines how those upstream components are composed into one product surface.
