# ZEVM Internal Support: Trusted Mode Semantics

Last updated: 2026-03-27

## Defaults And Managed Accounts

### Intended behavior

Trusted mode is a local dev chain with these intended defaults:

- chain ID `31337`
- mnemonic `test test test test test test test test test test test junk`
- derivation path root `m/44'/60'/0'/0/`
- initial HD index `0`
- 10 deterministic managed dev accounts
- initial balance `10000 ETH` per managed account
- coinbase index `0`
- gas price `2000000000`
- base fee `1000000000`
- blob base fee `1`
- max priority fee per gas `1000000000`
- block gas limit `30000000`
- mining mode `auto`
- canonical nonstandard methods use the `zevm_*` namespace
- the exact accepted compatibility-alias set from `docs/specs/json-rpc-contract.md` is accepted in trusted mode only
- `zevm_*` is an authoritative product-contract rule, not a docs convention

Exact managed-account table:

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

### Observed code constraints

- `src/node/runtime.zig` provides the fee and balance defaults and most of the canonical addresses, but it omits the private-key table and hardcodes a different account `#7`.
- `src/genesis.zig` provides a mnemonic, banner, and private-key table, but its account `#7` and private-key table do not match this documented contract.
- `src/node/runtime.zig` is the authoritative trusted-mode runtime/config model in source; `src/rpc/dev_runtime.zig` is only a narrow snapshot helper prototype and must not be read as the runtime contract.
- This is a contradiction, not an ambiguity: the public contract stays exact even while current code drifts from it.

### Unresolved ambiguity

- None in the published managed-account contract.
- The account table is settled; the current repo mismatch is implementation drift.

### Affected public pages

- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/reference/configuration/trusted-mode.mdx`
- `mintlify/docs/reference/json-rpc/core-reads.mdx`
- `mintlify/docs/reference/json-rpc/transactions-and-mining.mdx`

### Source IDs

- `TRUST-01`
- `TRUST-02`
- `TRUST-03`

## Read Surface

### Intended behavior

Phase-1 trusted-mode reads:

- `eth_chainId`
- `eth_blockNumber`
- `eth_getBalance`
- `eth_getCode`
- `eth_getStorageAt`
- `eth_getTransactionCount`
- `eth_accounts`
- `eth_coinbase`
- `eth_gasPrice`
- `eth_maxPriorityFeePerGas`
- `eth_blobBaseFee`
- `eth_feeHistory`

Read semantics:

- Reads are against trusted local state.
- When a fork source is configured, ZEVM resolves local overlay first and remote fork backing second.
- `eth_getCode` must return deployed bytecode, not a placeholder.
- Exact request tuples, return payloads, and error behavior for these methods live in `docs/specs/json-rpc-contract.md`.

### Observed code constraints

- `eth_chainId` and `eth_blockNumber` have minimal helper coverage.
- Richer read handlers exist in `src/rpc/handlers/eth_read.zig`, but they are not on the executable path.
- `eth_getCode` currently returns `"0x"` regardless of stored code.
- `eth_getStorageAt` currently catches malformed slot quantities and returns zero instead of surfacing the intended `-32602` invalid-params failure.
- `eth_feeHistory` is still synthetic: it repeats the current base fee, zeroes `gasUsedRatio`, ignores `newestBlock` and reward-percentile behavior, and defaults malformed `blockCount` instead of surfacing the intended `-32602` failure.

### Unresolved ambiguity

- None in the intended read contract.
- The unresolved work is wiring and coverage, not the read semantics themselves.

### Affected public pages

- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/reference/json-rpc/core-reads.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`

### Source IDs

- `RPC-04`
- `TRUST-03`
- `TRUST-05`
- `RPC-ETH-FEEHISTORY`

## Execution, Submission, And Mining

### Intended behavior

Phase-1 trusted-mode execution and write surface:

- `eth_call`
- `eth_estimateGas`
- `eth_sendTransaction`
- `eth_sendRawTransaction`
- automine
- manual mining
- interval mining

Execution rules:

- `eth_call` and `eth_estimateGas` run on a checkpoint-and-revert path.
- Simulation must not mutate canonical local state.
- Simulation honors state overrides.
- `eth_sendTransaction` signs only for the canonical managed-account set above or explicitly impersonated accounts.
- `eth_sendRawTransaction` accepts pre-signed transactions.
- Pending ordering is nonce-aware.
- Canonical nonstandard control methods are documented with the `zevm_*` prefix.
- The exact accepted compatibility-alias set from `docs/specs/json-rpc-contract.md` is accepted only in trusted mode.

Resolved trusted-mode config shapes:

- `mode.trusted.mining`: `{ "type": "auto" }`, `{ "type": "manual" }`, or `{ "type": "interval", "blockTime": <seconds> }`
- `mode.trusted.fork`: `null`, `{ "url": "https://..." }`, or `{ "url": "https://...", "blockNumber": <u64> }`
- `mode.trusted.chainId` remains a trusted-mode setting and is not inferred from `fork.url`

### Observed code constraints

- No `eth_call` or `eth_estimateGas` implementation exists.
- Transaction submission and mining logic live only in disconnected prototypes.
- Tests under `src/rpc/handlers/tx_submission_test.zig` reference runtime members that do not exist in `src/node/runtime.zig`.

### Unresolved ambiguity

- None. The canonical namespace, alias policy, and trusted-mode config shapes are settled for public docs.

### Affected public pages

- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/reference/json-rpc/transactions-and-mining.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`
- `mintlify/docs/concepts/state-fork-and-snapshots.mdx`

### Source IDs

- `TRUST-06`
- `TRUST-07`
- `TRUST-11`

## Tag And Query Semantics

### Intended behavior

Trusted-mode tags:

- `latest`, `pending`, `safe`, and `finalized` resolve to the current canonical local head.
- `earliest` resolves to block `0`.
- Numeric quantities resolve exact local blocks.

Important documentation rule:

- Trusted-mode `pending`, `safe`, and `finalized` are compatibility aliases only.
- They do not provide real finality.
- Real `safe` and `finalized` semantics belong to light mode.

Phase-1 canonical query surface:

- `eth_getBlockByNumber`
- `eth_getBlockByHash`
- `eth_getTransactionByHash`
- `eth_getTransactionReceipt`
- `eth_getBlockReceipts`
- `eth_getLogs`

### Observed code constraints

- Trusted-mode helper code already aliases `pending`, `safe`, and `finalized` to head.
- Query helpers remain unwired.
- `eth_getTransactionByHash` is still a stub that always returns `null`.
- Block hydration and receipt or log serialization still synthesize or drop important fields.
- Receipt and log indexes are not populated by the executable path after mining.
- Invalid log filters can still collapse to `[]` instead of surfacing the intended `-32602` failure.

### Unresolved ambiguity

- None about the intended tag split between trusted and light mode.
- The remaining gap is execution-path wiring and query completeness.

### Affected public pages

- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/concepts/light-mode.mdx`
- `mintlify/docs/reference/json-rpc/core-reads.mdx`
- `mintlify/docs/reference/json-rpc/blocks-receipts-and-logs.mdx`

### Source IDs

- `TRUST-04`
- `TRUST-08`
- `LIGHT-05`

### Internal support docs

- `docs/specs/json-rpc-contract.md`
- `docs/specs/internal/rpc-support-matrix.md`
- `docs/specs/internal/state-fork-and-snapshot-semantics.md`

### Notes

- Canonical `zevm_*` naming is a product-contract rule, and the exact alias inventory is closed-world in `docs/specs/json-rpc-contract.md`.
