# ZEVM Internal Support: Startup And Configuration

This page supports `docs/specs/prd.md` and `docs/specs/json-rpc-contract.md`.

## 1. Startup Model

- one binary: `zevm`
- default runtime: trusted mode
- alternate runtime: light mode
- runtime selected by user-supplied `--mode` or config `mode` branch (config must include exactly one of `mode.trusted` or `mode.light`)
- parser-provided CLI defaults are applied after CLI/config merge and do not create mode conflicts
- if user-supplied `--mode` and config `mode` are both present, they must agree

## 2. Shared CLI

| Flag | Type | Default |
| --- | --- | --- |
| `--config` | JSON path | none |
| `--mode` | `trusted` or `light` | `trusted` (effective only when neither user-supplied `--mode` nor `--config` selects mode; if `--config` is provided it must include exactly one `mode` branch, and user-supplied `--mode` must match that branch) |
| `--host` | bind host | `127.0.0.1` |
| `--port` | TCP port | `8545` |
| `--engine-host` | Engine API bind host | disabled unless Engine API is enabled |
| `--engine-port` | Engine API TCP port | `8551` when Engine API is enabled |

## 3. Trusted CLI And Config

Trusted CLI flags:

- `--chain-id`
- `--coinbase-index`
- `--initial-balance`
- `--gas-price`
- `--base-fee`
- `--blob-base-fee`
- `--max-priority-fee-per-gas`
- `--block-gas-limit`
- `--mining`
- `--block-time`
- `--fork-url`
- `--fork-block-number`
- `--genesis`
- `--chain-rlp`
- `--engine-host`
- `--engine-port`

Trusted config branch: `mode.trusted`

Resolved config sub-shapes:

- top-level `engineRpc`: optional `{ "host": "127.0.0.1", "port": 8551 }`; enables a trusted-mode Engine API listener
- `mining`: `{ "type": "auto" }`, `{ "type": "manual" }`, or `{ "type": "interval", "blockTime": <u64> }`
- `hardfork`: object of optional activation overrides using camelCase keys (`homesteadBlock`, `daoBlock`, `tangerineWhistleBlock`, `spuriousDragonBlock`, `byzantiumBlock`, `petersburgBlock`, `istanbulBlock`, `muirGlacierBlock`, `berlinBlock`, `londonBlock`, `arrowGlacierBlock`, `grayGlacierBlock`, `mergeBlock`, `shanghaiTimestamp`, `cancunTimestamp`, `pragueTimestamp`, `osakaTimestamp`, `secondsPerSlot`)
- `fork`: `null`, `{ "url": "https://..." }`, or `{ "url": "https://...", "blockNumber": <u64> }`
- `genesis`: `null` or a path to a genesis JSON file whose top-level `alloc` object seeds trusted-mode state
- `chainRlp`: `null` or a path to a concatenated RLP block stream imported after genesis as query-only block history

Validation:

- `blockTime` required only for interval mining
- `blockTime` invalid for auto and manual mining
- `forkBlockNumber` requires `forkUrl`
- providing `forkUrl` without `forkBlockNumber` uses unpinned upstream-head (`latest`) fork semantics at startup
- `coinbaseIndex` must be `0..9`
- trusted startup fork block numbers use decimal `u64` in CLI/config (`--fork-block-number`, `mode.trusted.fork.blockNumber`)
- runtime `zevm_reset` uses `QuantityHex` for `forkConfig.blockNumber`; example: startup decimal `1000000` corresponds to JSON-RPC `"blockNumber": "0xf4240"`
- trusted hardfork activation values use decimal `u64` in config; omitted `hardfork` fields inherit from the resolved chain default
- default hardfork policy is explicit: `chainId = 1` uses the mainnet activation schedule, while non-mainnet trusted defaults use a dev schedule with Cancun active from genesis and Prague/Osaka inactive until configured
- trusted `genesis` paths resolve by field precedence (`--genesis` over `mode.trusted.genesis`); when present, ZEVM imports account `balance`/`wei`, `nonce`, `code`, and `storage` from the file instead of pre-funding the deterministic dev accounts
- trusted `chainRlp` paths resolve by field precedence (`--chain-rlp` over `mode.trusted.chainRlp`); when present, ZEVM imports the stream after genesis as query-only block history, sets the canonical head to the last imported block, and does not materialize imported state, receipts, or logs
- trusted Engine API is disabled unless `--engine-host`, `--engine-port`, or top-level `engineRpc` is supplied; it is invalid in light mode

## 4. Light CLI And Config

Light CLI flags:

- `--network` (`mainnet`, `sepolia`, `holesky`)
- `--consensus-rpc-url`
- `--execution-rpc-url`
- `--checkpoint`
- `--checkpoint-dir`
- `--max-checkpoint-age-seconds` (default `1209600`)
- `--strict-checkpoint-age` presence flag (default `false`)

Light config branch: `mode.light`

Checkpoint-age defaults for light mode:

- `mode.light.maxCheckpointAgeSeconds` defaults to `1209600`
- `mode.light.strictCheckpointAge` defaults to `false`
- normative source: [`docs/specs/prd.md` section 5.3 (Light-mode CLI)](../prd.md#53-light-mode-cli)

Naming/path bridge for light startup inputs:

- hyphenated CLI flags map to camelCase config keys: `--network` -> `network`, `--consensus-rpc-url` -> `consensusRpcUrl`, `--execution-rpc-url` -> `executionRpcUrl`, `--checkpoint` -> `checkpoint`, `--checkpoint-dir` -> `checkpointDir`, `--max-checkpoint-age-seconds` -> `maxCheckpointAgeSeconds`, `--strict-checkpoint-age` -> `strictCheckpointAge`
- checkpoint-dir default template is `.zevm/checkpoints/<network>`; `<network>` expands from resolved startup `network` after CLI/config merge
- after CLI/config merge and `<network>` expansion, any relative `checkpointDir` value is resolved against the process current working directory at startup
- persisted checkpoint startup input path is `${resolvedCheckpointDir}/checkpoint`, where `resolvedCheckpointDir` is the absolute path after that resolution step

Validation:

- `consensusRpcUrl` is required in light mode
- `network` must be one of `mainnet`, `sepolia`, `holesky`
- `consensusRpcUrl` must serve the same network selected by `network`
- `executionRpcUrl` must serve execution JSON-RPC for the same network when proof-backed reads are used
- `--strict-checkpoint-age` CLI semantics are presence-based: present means `true`, omitted means `false`, and explicit assignment forms (for example `--strict-checkpoint-age=false`) are invalid
- checkpoint startup inputs from CLI/config are nullable for precedence selection: `--checkpoint` absent and `mode.light.checkpoint` absent or `null` are treated as absent startup inputs
- only non-null CLI/config checkpoint values (`--checkpoint`, `mode.light.checkpoint`) must be `0x`-prefixed 32-byte hashes (`Hash32`)
- selected startup checkpoint hash must resolve on the configured `network` via `consensusRpcUrl`; network mismatch is startup failure before opening the HTTP listener

Startup consensus-network handshake (before listener):

1. resolve `network`, `consensusRpcUrl`, and selected startup checkpoint from startup precedence
2. call `GET <consensusRpcUrl>/eth/v1/beacon/genesis`
3. require HTTP `200` and parse `data.genesis_validators_root` as `Hash32`
4. require root match for selected `network`:
   - `mainnet` -> `0x4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95`
   - `sepolia` -> `0xd8ea171f3c94aea21ebc42a1ed61052acf3f9209c00e4efbaaddac09ed9b8078`
   - `holesky` -> `0x9143aa7c615a7f7115e2b6aac319c03529df8242ae705fba9df39b79c59fa8b1`
5. if handshake fails (request failure, non-`200`, malformed payload, missing/invalid root, or root mismatch), ZEVM must fail before opening the HTTP listener

## 5. Config File Rules

- allowed top-level keys are `rpc` and `mode`; unknown top-level keys are invalid
- unknown keys inside `rpc`, `mode`, `mode.trusted`, `mode.light`, and trusted structured objects (`mining`, `hardfork`, `fork`) are invalid
- `rpc` is optional; when omitted, defaults are `host = 127.0.0.1`, `port = 8545`
- when `rpc` is present, `host` and `port` default independently if omitted
- `mode` must contain exactly one of `trusted` or `light`
- config with both is invalid
- config with neither is invalid
- explicit `--config` load failure (missing file, unreadable file, malformed JSON, schema failure, or validation failure) is startup failure
- explicit `--config` load failures must emit one startup error record on process `stderr` naming the config path and failure class before exiting non-zero

## 6. Precedence

Startup precedence:

1. user-supplied CLI flag values
2. config file values
3. persisted light checkpoint (light mode only)
4. mode defaults

Precedence scope clarification for light mode:

- precedence item 3 applies only to startup checkpoint selection
- `checkpointDir`, `maxCheckpointAgeSeconds`, and `strictCheckpointAge` resolve independently per field as: user-supplied CLI value > config value > mode default
- persisted `${resolvedCheckpointDir}/checkpoint` does not set or override `checkpointDir`, `maxCheckpointAgeSeconds`, or `strictCheckpointAge`

Merge clarifications:

- only user-supplied CLI flags override config
- parser-provided CLI defaults fill missing fields only after CLI/config merge
- parser-provided CLI defaults are not treated as user overrides and cannot cause mode conflicts

Structured trusted-setting resolution:

- `mining` resolves as one unit from CLI `--mining` and `--block-time`; if either flag is present, ZEVM builds `mining` from CLI and ignores `mode.trusted.mining`
- `hardfork` has no phase-1 CLI flags; ZEVM starts from the default schedule for the resolved `chainId`, then applies any `mode.trusted.hardfork` field overrides
- `fork` resolves as one unit from CLI `--fork-url` and `--fork-block-number`; if either flag is present, ZEVM builds `fork` from CLI and ignores `mode.trusted.fork`
- `genesis` resolves as one field from CLI `--genesis`, then config `mode.trusted.genesis`, then absent
- `chainRlp` resolves as one field from CLI `--chain-rlp`, then config `mode.trusted.chainRlp`, then absent
- when no related CLI flags are present for that unit, ZEVM uses config value for that unit, then mode default
- resolved trusted `fork` with `url` and no `blockNumber` uses unpinned upstream-head (`latest`) semantics; resolved trusted `fork` with `blockNumber` is pinned to that block

Light checkpoint selection precedence:

1. user-supplied CLI checkpoint (`--checkpoint`), when provided and non-null
2. config checkpoint (`mode.light.checkpoint`), when set to a non-null value
3. persisted `${resolvedCheckpointDir}/checkpoint`
4. baked network default

Precedence fallthrough is absence-driven only: ZEVM advances to a lower-precedence checkpoint source only when the higher-precedence source is absent. For CLI/config checkpoint inputs, absence includes omitted values and config `null`.

Once a checkpoint source is selected by precedence, that selected source is final for that startup attempt; any validation/derivation failure for the selected source must fail startup before opening the HTTP listener, and ZEVM must not fall back to lower-precedence checkpoint sources.

If CLI checkpoint, config checkpoint, and persisted `${resolvedCheckpointDir}/checkpoint` are all absent, ZEVM selects the baked network default checkpoint and `checkpointSource = "default"`. Here, "absent" includes config `mode.light.checkpoint = null`.

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
- phase 1 does not define a runtime JSON-RPC or CLI surface to directly report `releaseIdentifier`; operators identify release/build boundaries from preserved provenance records
- phase-1 source-build provenance has exactly two states: metadata-backed published-release provenance and operator-recorded unreleased-commit provenance
- metadata-backed published-release flow is strict and ordered: select one `releaseIdentifier` -> fetch required assets for that identifier -> validate PRD section 3.4 invariants -> materialize pinned commits/toolchain -> build
- unreleased-commit flow has no release-asset discovery step; operators derive and record `(zevmGitRevision, voltaireGitRevision, guillotineMiniGitRevision, zigVersion)` from local state
- operators must not mix metadata assets across `releaseIdentifier` values and must not claim metadata-backed reproducibility for metadata-invalid identifiers or unreleased commit builds

Persisted checkpoint startup-input contract:

- `${resolvedCheckpointDir}/checkpoint` is read-only startup input in phase 1 (`resolvedCheckpointDir` is derived from merged `checkpointDir` by applying `<network>` expansion and then resolving relative paths against startup current working directory)
- if `${resolvedCheckpointDir}` does not exist at startup (including a missing expanded `<network>` directory), persisted checkpoint input is treated as absent and precedence falls through
- if `${resolvedCheckpointDir}/checkpoint` is missing, persisted checkpoint input is treated as absent and precedence falls through
- if `${resolvedCheckpointDir}/checkpoint` exists but is unreadable, startup fails before opening the HTTP listener
- if the file is readable but trimmed content is malformed, startup fails before opening the HTTP listener
- ZEVM does not auto-create `${resolvedCheckpointDir}` (including `<network>` directory expansion targets) during startup
- ZEVM does not create, update, or delete `${resolvedCheckpointDir}/checkpoint` after listener startup
- seeding and management are operator-only workflows: operators seed `${resolvedCheckpointDir}/checkpoint` by creating/updating it before process start or between restarts
- ZEVM does not seed `${resolvedCheckpointDir}/checkpoint` from baked defaults, explicit startup checkpoint inputs, or `zevm_lightSyncStatus.lastCheckpoint`
- startup reads `${resolvedCheckpointDir}/checkpoint` once during precedence resolution; runtime writes or external file changes after listener startup do not change the active process checkpoint source
- `zevm_lightSyncStatus.lastCheckpoint` progression is runtime state only and is not persisted to `${resolvedCheckpointDir}/checkpoint` in phase 1
- operators may update `${resolvedCheckpointDir}/checkpoint` between restarts; startup precedence is re-evaluated on each process start

Checkpoint age policy for the selected startup checkpoint:

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
- non-strict stale warnings must be emitted on process `stderr` during startup and must not rely on JSON-RPC visibility
- the non-strict stale warning must include: selected checkpoint hash, `checkpointSource`, `checkpointTimeSeconds`, `startupTimeSeconds`, computed `age`, `maxCheckpointAgeSeconds`, and `strictCheckpointAge = false`
- stale + `strictCheckpointAge = true`: startup failure before listening

Startup logging surface (phase 1):

- operator-facing startup warnings and startup-failure errors are emitted via process `stderr`
- phase 1 does not define dedicated CLI/config controls for startup log level, log file paths, or alternative log sinks
- capture/routing of startup `stderr` output is external process/shell responsibility

## 7. Startup Failure Contract

ZEVM must fail before opening the HTTP listener for invalid startup input, including:

- unknown flags
- missing flag values
- malformed numeric or wei values
- malformed checkpoint input or malformed checkpoint file
- explicit `--mode` mismatch with config mode branch
- trusted-only flags in light mode
- light-only flags in trusted mode
- missing required light consensus URL
- light consensus endpoint/network mismatch
- light startup consensus-network handshake failure (`GET /eth/v1/beacon/genesis` request failure, non-`200`, malformed payload, missing/invalid `data.genesis_validators_root`, or root mismatch with selected network)
- selected startup checkpoint/network mismatch
- invalid mining/fork combinations
- invalid `coinbaseIndex`
- stale selected checkpoint when `strictCheckpointAge = true`
- explicit assignment form `--strict-checkpoint-age=false`
- inability to resolve `checkpointTimeSeconds` for the selected startup checkpoint
- once a checkpoint source is selected by startup precedence, any selected-source validation/derivation failure is terminal for that startup attempt and must not trigger fallback to lower-precedence checkpoint sources
- startup-failure errors in this section are operator-facing startup logs emitted on process `stderr`
- `--config` load failure (missing file, unreadable file, or invalid JSON): startup fails before opening the HTTP listener, exits non-zero, reports an operator-facing error naming the config path and failure class, and does not fall back to defaults

For exact field-level and RPC-level behavior, use `docs/specs/json-rpc-contract.md`.
