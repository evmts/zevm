# ZEVM Internal Support: Light Mode Semantics

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
- phase-1 operator-facing light-mode startup inputs are `network`, `consensusRpcUrl`, `executionRpcUrl`, `checkpoint`, `checkpointDir`, `maxCheckpointAgeSeconds`, and `strictCheckpointAge`
- `executionRpcUrl` is the execution JSON-RPC source used for proof-backed execution reads

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

Checkpoint precedence:

1. user-supplied CLI checkpoint (`--checkpoint`), when provided
2. config checkpoint (`mode.light.checkpoint`), when set
3. persisted `${resolvedCheckpointDir}/checkpoint`
4. baked network default

Precedence fallthrough is absence-driven only: ZEVM advances to a lower-precedence checkpoint source only when the higher-precedence source is absent.

Once a checkpoint source is selected by precedence, that selected source is final for that startup attempt; any validation/derivation failure for the selected source must fail startup before opening the HTTP listener, and ZEVM must not fall back to lower-precedence checkpoint sources.

Precedence scope clarification:

- this precedence applies only to startup checkpoint selection
- `checkpointDir`, `maxCheckpointAgeSeconds`, and `strictCheckpointAge` resolve independently per field as: user-supplied CLI value > config value > mode default
- persisted `${resolvedCheckpointDir}/checkpoint` does not set or override `checkpointDir`, `maxCheckpointAgeSeconds`, or `strictCheckpointAge`

Path resolution for persisted checkpoint input:

- `checkpointDir` default template is `.zevm/checkpoints/<network>`; `<network>` expands from resolved startup `network` after CLI/config merge
- after CLI/config merge and `<network>` expansion, any relative `checkpointDir` value (including the default `.zevm/checkpoints/<network>`) is resolved against the process current working directory at startup
- persisted checkpoint startup input path is `${resolvedCheckpointDir}/checkpoint`, where `resolvedCheckpointDir` is the absolute path after that resolution step

If CLI checkpoint, config checkpoint, and persisted `${resolvedCheckpointDir}/checkpoint` are all absent, ZEVM selects the baked network default checkpoint and `checkpointSource = "default"`.

Baked default checkpoints are precedence inputs, not frozen public compatibility hashes.

Baked default checkpoint values are ZEVM bundled release/build inputs. For a given ZEVM release/build artifact and network, the selected baked default is deterministic.

Baked defaults are implementation-defined and may rotate across releases/builds.

Canonical release metadata artifact for baked defaults:

- `releaseIdentifier` must exactly equal the GitHub release tag name that carries metadata assets; tag-based identifiers match `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`, and commit-based identifiers match `^commit-[0-9a-f]{40}$`
- each ZEVM `releaseIdentifier` publishes exactly one machine-readable `light-default-checkpoints.json` asset at `https://github.com/evmts/zevm/releases/download/<releaseIdentifier>/light-default-checkpoints.json`
- `light-default-checkpoints.json` top-level fields are exactly `schemaVersion`, `releaseIdentifier`, and `defaults`
- `schemaVersion` is `zevm-light-default-checkpoints.v1`
- `releaseIdentifier` matches the publishing `releaseIdentifier`
- `defaults` contains exactly `mainnet`, `sepolia`, and `holesky`; each value is a `0x`-prefixed 32-byte hash (`Hash32`) equal to that release/build's bundled baked default for the network
- values are immutable per published release identifier; corrections publish a new release identifier with its own `light-default-checkpoints.json`
- correction releases include one release-notes supersession note under heading `## ZEVM Supersession Note` with required lines: `schemaVersion`, `supersedesReleaseIdentifier`, `correctedArtifacts`, and `reason`
- publication-time validation gate is mandatory for canonical publication claims: before a release is treated or announced as canonical under this contract, CI/release automation validates both required artifacts (`release-tuple.json`, `light-default-checkpoints.json`) from published release assets against PRD section 3.4 requirements
- publication-time gate failure on either required artifact (missing, duplicate, unreadable, malformed, schema-mismatched, or value-mismatched) blocks canonical publication claims for that `releaseIdentifier`; correction requires a new `releaseIdentifier` (no in-place repair)
- operators deterministically discover per-network baked defaults from that artifact; runtime probing via `zevm_lightSyncStatus` is optional verification
- deterministic baked-default discovery from release metadata is defined only for published release identifiers
- for unreleased commit builds without published `light-default-checkpoints.json`, baked defaults remain implementation-defined and are not contract-discoverable from metadata
- operators that require deterministic checkpoint selection for unreleased commit builds must provide an explicit checkpoint via CLI/config instead of relying on baked defaults

Persisted checkpoint file contract:

- file path: `${resolvedCheckpointDir}/checkpoint`, where `resolvedCheckpointDir` is derived from merged `checkpointDir` by applying `<network>` expansion and then resolving relative paths against startup current working directory
- if `${resolvedCheckpointDir}/checkpoint` is missing, persisted checkpoint input is treated as absent and precedence falls through
- content: exactly 64 hex chars (32-byte hash, no `0x` prefix)
- trimmed whitespace is ignored on read
- this format split is intentional: CLI/config checkpoint inputs use `0x`-prefixed 32-byte hashes, while persisted `${resolvedCheckpointDir}/checkpoint` uses 64 hex chars without `0x`
- if the file exists but is unreadable, startup fails before opening the HTTP listener
- if the file is readable but trimmed content is malformed, startup fails before opening the HTTP listener
- in phase 1, ZEVM treats `${resolvedCheckpointDir}/checkpoint` as startup input only and does not create, update, or delete this file during runtime
- `lastCheckpoint` runtime progression is not persisted to `${resolvedCheckpointDir}/checkpoint` in phase 1
- operators may update `${resolvedCheckpointDir}/checkpoint` between restarts; startup precedence is re-evaluated on each process start

Age policy:

- `age` is ZEVM's startup-time freshness value for the selected startup checkpoint
- `age` is evaluated once during startup, after checkpoint selection and before stale-policy decision
- `age` is measured in whole seconds: `age = max(0, startupTimeSeconds - checkpointTimeSeconds)`
- `startupTimeSeconds` is sampled at age-check time
- `checkpointTimeSeconds` is derived deterministically from Beacon API data for the selected startup checkpoint hash on the selected network, using `consensusRpcUrl` and not filesystem metadata/local file times
- derivation steps are exact:
  1. call `GET <consensusRpcUrl>/eth/v1/beacon/genesis`, require HTTP `200`, parse `data.genesis_time` as decimal unsigned integer `genesisTimeSeconds`
  2. call `GET <consensusRpcUrl>/eth/v1/beacon/headers/{selectedCheckpointHash}`, require HTTP `200`, parse `data.root` as `Hash32` and require equality with `selectedCheckpointHash`, then parse `data.header.message.slot` as decimal unsigned integer `checkpointSlot`
  3. use `SECONDS_PER_SLOT = 12` for phase-1 supported light networks and compute `checkpointTimeSeconds = genesisTimeSeconds + (checkpointSlot * SECONDS_PER_SLOT)` with integer arithmetic
  4. use computed `checkpointTimeSeconds` as integer Unix seconds in age evaluation
- any request failure, non-`200`, missing/malformed required field, checkpoint-root mismatch, or arithmetic overflow in this derivation is inability to resolve `checkpointTimeSeconds` and is startup failure before listening
- `age == maxCheckpointAgeSeconds` is valid
- only `age > maxCheckpointAgeSeconds` is stale
- stale + `strictCheckpointAge = false`: emit one operator-facing startup warning before listening, then continue startup
- non-strict stale warnings must be surfaced on startup logs via process `stderr` and must not rely on JSON-RPC visibility
- phase 1 defines no dedicated CLI/config controls for startup log level, log file paths, or alternative startup log sinks
- the non-strict stale warning must include: selected checkpoint hash, `checkpointSource`, `checkpointTimeSeconds`, `startupTimeSeconds`, computed `age`, `maxCheckpointAgeSeconds`, and `strictCheckpointAge = false`
- stale + `strictCheckpointAge = true`: startup failure before listening
- inability to resolve `checkpointTimeSeconds` for the selected startup checkpoint is startup failure before listening

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
  - `default`: selected from ZEVM bundled release/build default checkpoint for the selected network (deterministic for that release/build artifact; may rotate across releases/builds and is published in that release's required `light-default-checkpoints.json`)
- `lastCheckpoint` is always present as `Hash32` after listener startup
- `optimisticSlot`, `safeSlot`, and `finalizedSlot` are always present as `QuantityHex` values (not `null`)
- `finalizedSlot <= safeSlot <= optimisticSlot`
- while `status = "syncing"`, slot values may remain `0x0` until headers are available
- when `status = "error"`, slot fields keep the last known values and are not nullified

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
