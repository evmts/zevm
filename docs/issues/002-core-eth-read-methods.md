# Core Eth Read Methods

> **Archived / non-normative:** This issue is historical context only. Current normative sources: [docs/specs/prd.md](../specs/prd.md) and [docs/specs/json-rpc-contract.md](../specs/json-rpc-contract.md).


## Verified Gap

- The executable does not expose the read helpers at all; the live dispatcher still returns `Method not found`.
- `eth_getCode` discards real code and always returns `"0x"`.
- `eth_getStorageAt` returns quantity-style hex, not 32-byte storage data, and malformed slots silently collapse to zero.
- `eth_feeHistory` is synthetic: it repeats the current base fee, uses zero gas-used ratios, and ignores `newest_block`.
- `latest`, `pending`, `safe`, and `finalized` all alias the current head, and the resolved block number is then ignored by the read handlers.
- `eth_accounts` is hardcoded from `DEFAULT_DEV_ACCOUNTS`, not derived from a managed-account runtime.

## Evidence

- `src/main.zig`
- `src/rpc/dispatcher.zig`
- `src/rpc/handlers/eth_read.zig`
- `src/rpc/handlers/block_spec.zig`
- `src/node/runtime.zig`
- `src/rpc/handlers/eth_read_test.zig`

## Resolution Verification

- All PRD read methods are callable over the runnable HTTP path.
- `eth_getCode` returns exact deployed bytecode and `"0x"` only for empty accounts.
- `eth_getStorageAt` returns 32-byte values and rejects malformed slots with `-32602`.
- `eth_feeHistory` reflects real mined history rather than shaped constants.
- `latest`, `pending`, `earliest`, `safe`, `finalized`, and explicit block numbers have explicit, tested semantics.
- Helper and HTTP-path tests for this surface are on the default test graph.
