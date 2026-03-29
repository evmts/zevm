# ZEVM Internal Support: Startup And Configuration

Last updated: 2026-03-29

## Shared Startup Contract

### Intended behavior

- ZEVM ships as one binary, `zevm`, and starts in trusted mode by default.
- Shared startup accepts `--config`, `--mode`, `--host`, and `--port`.
- Shared JSON config has `rpc.host`, `rpc.port`, and exactly one runtime branch under `mode`.
- `--config` is optional and is loaded before CLI overrides.
- If `--config` points to a missing file, an unreadable file, or malformed JSON, ZEVM fails startup before opening the listener, exits non-zero, reports an operator-facing error that names the path and failure class, and does not fall back to defaults.
- The active runtime may be selected directly by CLI `--mode` or by the config-file `mode` branch. `--mode light` is a direct light-mode selection path, not merely a confirmation of config, and when both sources are present they must agree.
- Default shared listener values are `127.0.0.1` for `--host` and `8545` for `--port`.
- Source-build installation is the public contract for phase 1; do not promise packaged binaries.

### Default startup behavior

- The default runtime is trusted mode.
- Light mode is explicit through either `--mode light` or the `mode.light` config branch, and `--mode light` itself selects light mode.
- The shared config shape is independent from the default runtime. A valid config file still must contain exactly one runtime branch under `mode`.

### Observed code constraints

- On 2026-03-29, `src/main.zig` still only forwards argv to `src/rpc/server.zig`.
- On 2026-03-29, `src/rpc/server.zig::parseConfig` still accepts only `--host` and `--port`; it rejects any other argument, including `--mode` and `--config`.
- On 2026-03-29, that same parser still returns `error.UnknownArgument` for any unsupported CLI flag, so current `HEAD` already hard-fails unknown arguments even though it does not implement the intended full startup surface.
- On 2026-03-29, `src/main.zig` still has no executable `--config` loader, `--mode` selector, or mode-dispatch path.
- The current executable path therefore does not yet exercise the CLI-selection contract, even though the product contract allows `--mode light` to select light mode directly.
- On 2026-03-29, `src/node/runtime.zig` still carries the authoritative trusted-mode runtime/config model in source; `src/rpc/dev_runtime.zig` is only a partial snapshot helper prototype.
- Current startup cannot enforce the one-branch mode contract before listener creation.

### Unresolved ambiguity

- None remains for installation posture; `DEC-011` resolved phase-1 install guidance to source-build only.
- No other ambiguity is accepted for the shared startup contract.

### Affected public pages

- `mintlify/docs/index.mdx`
- `mintlify/docs/quickstart/installation.mdx`
- `mintlify/docs/reference/configuration/overview.mdx`
- `mintlify/docs/quickstart/run-trusted-mode.mdx`
- `mintlify/docs/quickstart/forked-dev-node.mdx`
- `mintlify/docs/concepts/runtime-modes.mdx`

### Source IDs

- `BOOT-01`
- `BOOT-04`
- `BOOT-08`
- `PROC-01`

### Contradiction IDs

- `C-001`
- `C-002`

## Trusted-Mode CLI/Config

### Intended behavior

- Trusted mode is the default runtime and the phase-1 local dev-node surface.
- Canonical trusted-mode nonstandard methods are `zevm_*`.
- Exact accepted compatibility aliases are defined in `docs/specs/json-rpc-contract.md`.
- Trusted-mode CLI covers `--chain-id`, `--coinbase-index`, `--initial-balance`, `--gas-price`, `--base-fee`, `--blob-base-fee`, `--max-priority-fee-per-gas`, `--block-gas-limit`, `--mining`, `--block-time`, `--fork-url`, and `--fork-block-number`.
- Unknown CLI flags, missing values, invalid integer literals, and invalid wei literals are startup failures.
- Trusted-mode config lives under `mode.trusted`.
- `mode.trusted.mining` accepts exactly these JSON shapes:
  - `{ "type": "auto" }`
  - `{ "type": "manual" }`
  - `{ "type": "interval", "blockTime": <seconds> }`
- `blockTime` is an integer number of seconds and is valid only when `type = "interval"`.
- `mode.trusted.fork` accepts exactly these JSON shapes:
  - `null`
  - `{ "url": "https://rpc.example" }`
  - `{ "url": "https://rpc.example", "blockNumber": <u64> }`
- `fork.url` mirrors CLI `--fork-url`.
- `fork.blockNumber` mirrors CLI `--fork-block-number`.
- Omitting `fork.blockNumber` means fork from the upstream latest block.
- `chainId` remains top-level under `mode.trusted`; `fork` does not implicitly change it.
- Forking stays inside trusted mode and does not create a third product mode.
- `coinbaseIndex` selects from the managed-account table and must be within `0..9`.
- This section is the authoritative trusted-mode runtime/config model; `src/rpc/dev_runtime.zig` only carries prototype snapshot bookkeeping.

### Observed code constraints

- On 2026-03-29, there is still no executable trusted-mode startup path.
- On 2026-03-29, `src/node/runtime.zig` contains trusted defaults and helper logic, but startup does not ingest them.
- Fork startup remains unwired.
- Managed-account and mining behavior still diverge between runtime helpers and the published contract.
- The public trusted-mode namespace is not yet wired through startup, so the `zevm_*` surface and compatibility aliases remain a product contract, not a shipped entrypoint.

### Unresolved ambiguity

- None remains for the trusted-mode JSON subshapes or the public trusted-mode namespace.

### Affected public pages

- `mintlify/docs/quickstart/run-trusted-mode.mdx`
- `mintlify/docs/quickstart/forked-dev-node.mdx`
- `mintlify/docs/reference/configuration/trusted-mode.mdx`
- `mintlify/docs/reference/configuration/overview.mdx`
- `mintlify/docs/concepts/trusted-mode.mdx`

### Source IDs

- `BOOT-02`
- `BOOT-07`
- `TRUST-01`
- `TRUST-02`
- `TRUST-03`
- `TRUST-09`
- `TRUST-11`

### Contradiction IDs

- `C-001`
- `C-008`
- `C-010`

## Light-Mode CLI/Config

### Intended behavior

- Light mode is explicit and is the phase-2 read-only runtime.
- Light-mode CLI covers `--network`, `--consensus-rpc-url`, `--checkpoint`, `--checkpoint-dir`, `--max-checkpoint-age-seconds`, and `--strict-checkpoint-age`.
- `network` accepts exactly `mainnet`, `sepolia`, or `holesky`; any other value is invalid and fails startup.
- Light-mode config lives under `mode.light`.
- `consensusRpcUrl` is required in light mode.
- `checkpoint` may be supplied explicitly, then falls back to persisted checkpoint, then to the baked network default.
- The public contract guarantees that baked network defaults exist and participate in checkpoint precedence, but their exact literal hashes remain implementation defaults rather than frozen compatibility guarantees.
- Persisted checkpoint lives at `checkpointDir/checkpoint` and must be exactly 64 hex characters.
- A checkpoint whose age is exactly `maxCheckpointAgeSeconds` is still valid; the stale-checkpoint check is strictly greater-than.
- If the selected checkpoint is older than `maxCheckpointAgeSeconds` and `strictCheckpointAge = false`, ZEVM logs a warning and continues.
- If the selected checkpoint is older than `maxCheckpointAgeSeconds` and `strictCheckpointAge = true`, ZEVM fails startup.

### Observed code constraints

- On 2026-03-29, consensus and checkpoint helpers still exist, but `src/main.zig` has no light-mode startup branch.
- On 2026-03-29, no executable path wires network selection, checkpoint persistence, or readiness gating from startup.
- On 2026-03-29, the checkpoint helpers in `src/checkpoint.zig` and `src/consensus_sync.zig` are not surfaced through the startup contract.

### Unresolved ambiguity

- No unresolved semantic question is opened for the light-mode config shape here.
- If public install text ever needs a light-mode note, keep it aligned with the resolved source-build-only posture, but do not turn that into a startup rule.

### Affected public pages

- `mintlify/docs/concepts/light-mode.mdx`
- `mintlify/docs/reference/configuration/light-mode.mdx`
- `mintlify/docs/reference/configuration/overview.mdx`
- `mintlify/docs/concepts/runtime-modes.mdx`

### Source IDs

- `BOOT-03`
- `LIGHT-01`
- `LIGHT-02`
- `LIGHT-03`

### Contradiction IDs

- `C-011`
- `C-012`

## Precedence

### Intended behavior

- CLI flags win over config-file values for non-mode fields.
- Startup resolves values in this order: CLI flags, config-file fields from `--config`, persisted light-mode checkpoint if applicable, baked defaults in the selected mode.
- The active runtime may be selected directly by CLI `--mode` or by the config-file `mode` branch. `--mode light` can select light mode directly, and if config is present the resulting runtime must match it.
- In light mode, explicit checkpoint wins over persisted checkpoint, which wins over the baked network default.
- `--mode` is a direct runtime selector; when config is present it must resolve to the same runtime and it may not conflict with the resulting runtime.

### Observed code constraints

- On 2026-03-29, `src/main.zig` still does not implement config loading or precedence resolution.
- On 2026-03-29, no startup path merges CLI values with config-file values because config parsing is absent.
- On 2026-03-29, light checkpoint selection still exists in helper code, but it is not connected to executable startup.

### Unresolved ambiguity

- None remains on trusted-mode JSON subshapes; precedence does not change the resolved shapes above.
- No additional precedence ambiguity is acceptable in public docs.

### Affected public pages

- `mintlify/docs/reference/configuration/overview.mdx`
- `mintlify/docs/reference/configuration/trusted-mode.mdx`
- `mintlify/docs/reference/configuration/light-mode.mdx`
- `mintlify/docs/quickstart/forked-dev-node.mdx`
- `mintlify/docs/quickstart/run-trusted-mode.mdx`

### Source IDs

- `BOOT-05`
- `LIGHT-03`

### Contradiction IDs

- `C-001`
- `C-011`

## Invalid Combinations

### Intended behavior

- Startup must fail before opening the listener when input is invalid.
- Invalid combinations include: unknown CLI flag, missing value, invalid integer or wei literal, invalid `--network` or `mode.light.network` value outside `mainnet` / `sepolia` / `holesky`, conflicting `--mode` and config mode, both mode branches in config, neither mode branch in config, trusted-only flags in light mode, light-only flags in trusted mode, missing `--consensus-rpc-url` in light mode, missing `--block-time` for interval mining, `--block-time` outside interval mining, `--fork-block-number` without `--fork-url`, `coinbaseIndex` outside `0..9`, and malformed checkpoint hex.
- `--fork-url` does not implicitly change `chainId`.
- `--consensus-rpc-url` is required for light mode.

### Observed code constraints

- Current executable startup does not implement these validation gates.
- The current binary only parses `--host` and `--port`.
- In current `HEAD`, `src/rpc/server.zig::parseConfig` already hard-fails unknown CLI arguments and malformed `--port` values, but no executable path yet exercises the broader invalid-integer, invalid-wei, or invalid-network contract.
- Invalid-combination behavior is therefore specified by the PRD, not by `HEAD`.

### Unresolved ambiguity

- None remains for trusted-mode JSON subshapes.
- Do not infer additional invalid combinations from prototype code.

### Affected public pages

- `mintlify/docs/reference/configuration/overview.mdx`
- `mintlify/docs/reference/configuration/trusted-mode.mdx`
- `mintlify/docs/reference/configuration/light-mode.mdx`
- `mintlify/docs/quickstart/run-trusted-mode.mdx`
- `mintlify/docs/quickstart/forked-dev-node.mdx`

### Source IDs

- `BOOT-06`
- `BOOT-02`
- `BOOT-03`

### Contradiction IDs

- `C-001`
- `C-011`
