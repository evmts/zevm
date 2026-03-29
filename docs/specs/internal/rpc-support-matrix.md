# ZEVM Internal Support: RPC Support Matrix

Last updated: 2026-03-29

This file is a support-layer summary. The exact contract lives in `../json-rpc-contract.md`.

## Canonical Transport

### Intended behavior

- HTTP JSON-RPC 2.0 listener rooted at `/`
- `POST` only
- success and JSON-RPC error responses use HTTP `200`
- notification requests and notification-only batches use HTTP `204` with an empty body
- non-`POST` requests use HTTP `405`

### Observed code constraints

- `src/rpc/server.zig` plus `src/rpc/dispatcher.zig` is the intended shipping path
- `src/rpc/server.zig` does not inspect the request target and therefore does not enforce the documented `/` path
- the older `src/rpc/envelope.zig` plus `src/rpc/router.zig` stack is still present in-tree but is stale and non-shipping
- current helper tests exercise response-bearing helper entry points and codify the wrong notification behavior instead of the HTTP `204` no-body contract
- prototype code rejects empty batch `[]` as invalid request, but the canonical transport path still sits inside the broader `C-003` transport contradiction and is not release-ready on current `HEAD`

### Affected public pages

- `mintlify/docs/reference/json-rpc/overview.mdx`
- `mintlify/docs/quickstart/installation.mdx`

### Source IDs

- `RPC-01`
- `RPC-02`

### Contradiction IDs

- `C-003`

## Error Semantics

### Intended behavior

- standard JSON-RPC codes are exact
- ZEVM runtime codes are exact
- method-specific malformed requests fail with `-32602`
- active-mode gating fails with `-32010`
- exact method-level error mapping is defined in `../json-rpc-contract.md`

### Observed code constraints

- current validation is shallow
- current dispatcher failures commonly collapse into `-32603`

### Affected public pages

- `mintlify/docs/reference/json-rpc/overview.mdx`
- `mintlify/docs/reference/json-rpc/core-reads.mdx`
- `mintlify/docs/reference/json-rpc/simulation.mdx`
- `mintlify/docs/reference/json-rpc/transactions-and-mining.mdx`
- `mintlify/docs/reference/json-rpc/blocks-receipts-and-logs.mdx`
- `mintlify/docs/reference/json-rpc/dev-controls.mdx`
- `mintlify/docs/reference/json-rpc/verified-light-mode-reads.mdx`
- `mintlify/docs/reference/json-rpc/unsupported-and-deferred.mdx`

### Source IDs

- `RPC-03`
- `RPC-04`

### Contradiction IDs

- `C-003`

## Trusted-Mode Method Support

### Intended behavior

- core standard methods are `eth_chainId`, `eth_blockNumber`, `eth_accounts`, `eth_coinbase`, `eth_gasPrice`, `eth_maxPriorityFeePerGas`, `eth_blobBaseFee`, and `eth_feeHistory`
- trusted execution reads are `eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, and `eth_getTransactionCount`
- trusted simulation is `eth_call` and `eth_estimateGas`
- trusted submission and mining are `eth_sendTransaction`, `eth_sendRawTransaction`, automine, manual mining, and interval mining
- trusted canonical queries are block, receipt, log, and transaction lookup methods, including `eth_getLogs`
- canonical ZEVM nonstandard namespace is `zevm_*`
- accepted compatibility aliases are the exact `anvil_*`, `hardhat_*`, and `evm_*` inventories captured in `../json-rpc-contract.md`
- no legacy namespace is part of the ZEVM public contract
- `eth_getLogs` is part of the supported trusted canonical query surface and is not deferred

### Observed code constraints

- `src/main.zig` still constructs an empty `dispatcher.HandlerRegistry`, and `src/rpc/server.zig` still parses only `--host` and `--port`, so helper coverage is not wired through executable startup
- `eth_getLogs` already has trusted-mode handler coverage in `src/rpc/handlers/block_query_handlers.zig` and `src/rpc/block_queries.zig`
- `eth_getCode` still returns `"0x"` in current helper code
- `eth_getStorageAt` still catches malformed slot parsing and returns zero instead of surfacing `-32602`
- `eth_feeHistory` still synthesizes history instead of reflecting mined blocks: it repeats the current base fee, zeroes `gasUsedRatio`, ignores `newestBlock` and reward-percentile behavior, and defaults malformed `blockCount` instead of surfacing `-32602`
- `eth_call` and `eth_estimateGas` are still unwired
- transaction submission and mining coordination are disconnected from startup
- canonical trusted queries still carry live `C-007` defects: `eth_getTransactionByHash` remains a stub, block hydration and receipt or log serialization remain placeholder-backed or lossy, receipt and log indexes are not populated by the executable path after mining, and invalid log filters can still collapse to `[]`
- the canonical `zevm_*` namespace is a docs contract right now, not a shipping listener surface

### Affected public pages

- `mintlify/docs/reference/json-rpc/dev-controls.mdx`
- `mintlify/docs/reference/json-rpc/transactions-and-mining.mdx`
- `mintlify/docs/reference/json-rpc/overview.mdx`
- `mintlify/docs/reference/json-rpc/core-reads.mdx`
- `mintlify/docs/reference/json-rpc/simulation.mdx`
- `mintlify/docs/reference/json-rpc/blocks-receipts-and-logs.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`
- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/quickstart/run-trusted-mode.mdx`

### Source IDs

- `TRUST-05`
- `TRUST-06`
- `TRUST-07`
- `TRUST-08`
- `TRUST-09`
- `TRUST-10`
- `TRUST-11`
- `RPC-04`
- `RPC-ETH-FEEHISTORY`

### Contradiction IDs

- `C-004`
- `C-005`
- `C-006`
- `C-007`
- `C-008`
- `C-009`

## Light-Mode Method Support

### Intended behavior

- `zevm_lightSyncStatus` is available in light mode and reports readiness plus sync state
- `ready = true` only when `status = "synced"` and ZEVM can serve proof-backed reads
- `eth_chainId` is available in light mode
- `eth_blockNumber` is available in light mode, fails with `-32011` while `ready = false`, and once ready returns the block number of the light-mode `latest` head
- `eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, and `eth_getTransactionCount` are available only when backed by verified proofs
- `safe` and `finalized` block tags are consensus-derived in light mode
- `earliest` is block `0`
- while `ready = false`, ZEVM serves no proof-backed reads and fails them with `-32011`
- once ready, numeric selectors are supported only for block `0` and for exact blocks inside the retained verified-history window containing the most recent `8191` verified execution blocks when ZEVM can verify the exact execution block and the requested proof-backed read against that block's state root
- if light mode is ready in general but the requested numeric block is outside that retained verified-history window, the request fails with `-32602`
- proof verification failures for otherwise-supported reads fail with `-32014`
- malformed upstream proof data fails with `-32015`
- light mode does not promise arbitrary checkpoint-to-head historical archive reads
- exact request and response details are defined in `../json-rpc-contract.md`

### Observed code constraints

- `src/main.zig` exposes no light-mode startup path or mode selector
- there is no public RPC method for `zevm_lightSyncStatus`
- there is no proof-backed read bridge and no light-mode RPC routing for verified reads or not-ready errors
- there is no light-mode RPC route that could currently demonstrate a settled public `eth_blockNumber` contract

### Affected public pages

- `mintlify/docs/concepts/light-mode.mdx`
- `mintlify/docs/concepts/runtime-modes.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`
- `mintlify/docs/reference/json-rpc/verified-light-mode-reads.mdx`

### Source IDs

- `LIGHT-01`
- `LIGHT-04`
- `LIGHT-05`
- `RPC-04`
- `RPC-TAGS-LIGHT`

### Contradiction IDs

- `C-011`
- `C-012`

## Deferred Surfaces

### Intended behavior

- tracing, filter lifecycle APIs beyond `eth_getLogs`, subscriptions, and WebSocket transport stay deferred until the canonical trusted and light surfaces stabilize

In this document and in deferred-surface shorthand, "filters" means lifecycle APIs around creating, watching, or removing filter state. It does not include `eth_getLogs`, which remains part of the canonical trusted query surface and is not deferred.

### Observed code constraints

- no shipping surface was found for tracing, filter lifecycle APIs, subscriptions, or WebSocket transport
- `eth_getLogs` already has trusted-mode handler coverage in `src/rpc/handlers/block_query_handlers.zig`

### Affected public pages

- `mintlify/docs/reference/json-rpc/unsupported-and-deferred.mdx`
- `mintlify/docs/reference/json-rpc/overview.mdx`
- `mintlify/docs/concepts/runtime-modes.mdx`
- `mintlify/docs/concepts/trusted-mode.mdx`
- `mintlify/docs/concepts/method-support-by-mode.mdx`

### Source IDs

- `DEFER-01`

### Contradiction IDs

- `-`
