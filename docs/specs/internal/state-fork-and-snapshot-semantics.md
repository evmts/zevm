# ZEVM Internal Support: State Fork And Snapshot Semantics

Last updated: 2026-03-30

This page is non-normative support for:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

Use the JSON-RPC contract for exact RPC tuples, selector handling, canonical method names, and accepted aliases.

## 1. Trusted State And Fork Layering

- trusted mode owns writable local execution state
- forking is trusted-mode configuration, not a separate runtime mode
- reads resolve local overlay first, then remote fork backing
- writes remain local to trusted state
- `chainId` is a trusted startup/config value and is not inferred from fork URL

## 2. Snapshot Boundary

Trusted snapshot/revert captures local trusted runtime state, including:

- local state/journal checkpoint state
- local canonical chain head
- local receipt and log indexing state
- pending transaction pool state
- trusted mining and block-environment overrides
- impersonation and time-control state

Snapshot/revert does not capture:

- light-mode consensus or checkpoint-sync state
- ownership or mutation of remote fork source state

## 3. Fork-Source Controls Versus Overlay Controls

- `zevm_reset` resets trusted local runtime state and can keep, disable, or replace fork backing based on params
- `zevm_reset([])` keeps current fork config; `zevm_reset([null])` disables forking; `zevm_reset([forkConfig])` replaces fork URL and optional fork block pin
- successful `zevm_reset` resets local chain to genesis, clears pending tx pool, and invalidates prior snapshot IDs
- `zevm_setRpcUrl([url])` requires forking enabled and updates the active fork URL in place without resetting local chain state
- both methods are fork-source controls; they do not redefine snapshot boundary behavior
- local import/export controls (`zevm_dumpState`, `zevm_loadState`) remain local-state operations

## 4. Trusted Config Shape (Fork And Mining)

Trusted mining config shape:

- `{ "type": "auto" }`
- `{ "type": "manual" }`
- `{ "type": "interval", "blockTime": <seconds> }`

Trusted fork config shape:

- `null`
- `{ "url": "https://..." }`
- `{ "url": "https://...", "blockNumber": <decimal u64> }`

`chainId` remains a sibling trusted-mode setting, not part of `fork`.

Fork block-number typing boundary:

- startup CLI/config uses decimal `u64` (`--fork-block-number`, `mode.trusted.fork.blockNumber`)
- runtime `zevm_reset` params use `QuantityHex` for `forkConfig.blockNumber` (example: startup decimal `1000000` corresponds to JSON-RPC `"blockNumber": "0xf4240"`)
- see `docs/specs/json-rpc-contract.md` section 9.2 (parameter token typing for `forkConfig`) and section 9.4 (`zevm_reset` semantics)

## 5. Namespace And Alias Boundary

- canonical nonstandard trusted controls use `zevm_*`
- accepted compatibility aliases are closed-world and exactly the set listed in `docs/specs/json-rpc-contract.md`
