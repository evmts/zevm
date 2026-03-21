# ZEVM Internal Support: Startup And Configuration

Last updated: 2026-03-21

## Shared Startup Contract

Shared CLI flags:

| Flag | Default | Notes |
| --- | --- | --- |
| `--config` | none | Optional JSON config file path. |
| `--mode` | `trusted` | `trusted` or `light`. |
| `--host` | `127.0.0.1` | HTTP listener host. |
| `--port` | `8545` | HTTP listener port. |

Canonical JSON config shape:

```json
{
  "rpc": {
    "host": "127.0.0.1",
    "port": 8545
  },
  "mode": {
    "trusted": {}
  }
}
```

or

```json
{
  "rpc": {
    "host": "127.0.0.1",
    "port": 8545
  },
  "mode": {
    "light": {}
  }
}
```

Rules:

- exactly one runtime branch may appear under `mode`
- CLI overrides win over config-file values
- CLI `--mode` may not conflict with the config-file mode branch
- startup fails before opening the listener when parsing or validation fails

- current repo reality: `src/main.zig` only parses `--host` and `--port` via `src/rpc/server.zig`; there is no `--config`, `--mode`, or mode-specific validation path in the executable
- source IDs: `BOOT-01`, `BOOT-02`, `BOOT-03`
- contradiction IDs: `C-001`

## Trusted-Mode Contract

Trusted-mode flags and config fields:

| CLI flag | Config field | Default |
| --- | --- | --- |
| `--chain-id` | `mode.trusted.chainId` | `31337` |
| `--coinbase-index` | `mode.trusted.coinbaseIndex` | `0` |
| `--initial-balance` | `mode.trusted.initialBalance` | `10000000000000000000000` |
| `--gas-price` | `mode.trusted.gasPrice` | `2000000000` |
| `--base-fee` | `mode.trusted.baseFee` | `1000000000` |
| `--blob-base-fee` | `mode.trusted.blobBaseFee` | `1` |
| `--max-priority-fee-per-gas` | `mode.trusted.maxPriorityFeePerGas` | `1000000000` |
| `--block-gas-limit` | `mode.trusted.blockGasLimit` | `30000000` |
| `--mining` | `mode.trusted.mining.type` | `auto` |
| `--block-time` | `mode.trusted.mining.blockTime` | none |
| `--fork-url` | `mode.trusted.fork.url` | none |
| `--fork-block-number` | `mode.trusted.fork.blockNumber` | none |

Validation rules:

- `coinbaseIndex` must be within the managed-account range
- `blockTime` is required iff `mining.type = "interval"`
- `fork.blockNumber` requires `fork.url`
- trusted-mode fields are invalid in light mode

Managed-account publication boundary:

- deterministic managed accounts are part of the trusted-mode contract
- the exact public wallet contract is:
  - mnemonic `test test test test test test test test test test test junk`
  - derivation path root `m/44'/60'/0'/0/`
  - initial index `0`
  - count `10`
  - `coinbaseIndex` selects from that exact index-ordered account set
  - `eth_accounts` returns that exact index-ordered account set
  - `eth_sendTransaction` signs only for that exact account set unless impersonation is active

- current repo reality: `src/node/runtime.zig` contains the trusted defaults for balances and fee fields, but no executable startup path exposes them; fork startup is still unwired; `src/node/runtime.zig` and `src/genesis.zig` both contradict the canonical managed-wallet contract in different ways
- source IDs: `TRUST-01`, `TRUST-03`, `BOOT-03`
- contradiction IDs: `C-001`, `C-005`, `C-007`, `C-009`

## Light-Mode Contract

Light-mode flags and config fields:

| CLI flag | Config field | Default |
| --- | --- | --- |
| `--network` | `mode.light.network` | `mainnet` |
| `--consensus-rpc-url` | `mode.light.consensusRpcUrl` | required |
| `--checkpoint` | `mode.light.checkpoint` | none |
| `--checkpoint-dir` | `mode.light.checkpointDir` | `.zevm/checkpoints/<network>` |
| `--max-checkpoint-age-seconds` | `mode.light.maxCheckpointAgeSeconds` | `1209600` |
| `--strict-checkpoint-age` | `mode.light.strictCheckpointAge` | `false` |

Checkpoint precedence:

1. explicit user checkpoint from CLI or config
2. persisted checkpoint from `checkpointDir/checkpoint`
3. baked network default

Persisted checkpoint file contract:

- file path: `checkpointDir/checkpoint`
- contents: 64 lowercase-or-uppercase hex characters, no `0x`
- surrounding whitespace ignored on load
- malformed persisted checkpoint is a startup failure, not a silent fallback case

Validation rules:

- `consensusRpcUrl` is required in light mode
- light-mode fields are invalid in trusted mode
- malformed explicit checkpoint is a startup failure
- `strictCheckpointAge = true` converts an old checkpoint into a startup failure

Baked network defaults from `src/consensus_sync.zig`:

| Network | Chain ID | Default checkpoint |
| --- | --- | --- |
| `mainnet` | `1` | `0x9b41a80f58c52068a00e8535b8d6704769c7577a5fd506af5e0c018687991d55` |
| `sepolia` | `11155111` | `0x4065c2509eaa15dbe60e1f80cff5205a532aa95aaa1d73c1c286f7f8535555d4` |
| `holesky` | `17000` | `0xe1f575f0b691404fe82cce68a09c2c98af197816de14ce53c0fe9f9bd02d2399` |

- current repo reality: the consensus substrate exists in `src/consensus_sync.zig`, `src/beacon_api.zig`, `src/consensus_verifier.zig`, and `src/checkpoint.zig`, but no executable startup path exposes this light-mode contract yet
- source IDs: `LIGHT-01`, `LIGHT-02`, `LIGHT-03`, `BOOT-03`
- contradiction IDs: `C-011`, `C-012`
