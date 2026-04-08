# ZEVM Internal Support: Transport And Error Semantics

Last updated: 2026-03-31

This page is non-normative support for:

- `docs/specs/prd.md`
- `docs/specs/json-rpc-contract.md`

Use the JSON-RPC contract for exact request/response tuples and method-level error mapping.

## 1. Transport Invariants

- HTTP JSON-RPC 2.0 only
- JSON-RPC endpoint path is `/` only
- JSON-RPC method is `POST` only
- request path other than `/` returns HTTP `404` with no JSON-RPC body
- non-`POST` request to `/` returns HTTP `405` with no JSON-RPC body
- `POST /` must use content type `application/json` (media-type parameters allowed); unsupported or missing content type returns HTTP `415` with no JSON-RPC body
- JSON-RPC success and error envelopes return HTTP `200`
- notification-only request or notification-only batch returns HTTP `204` with empty body
- one canonical ZEVM-owned HTTP transport/parser stack is the shipping path for request parsing and envelope dispatch; divergent production parser stacks are outside the phase-1 contract
- whenever a JSON body is returned, content type is `application/json`

## 2. Envelope Semantics

- single requests are supported
- batches are supported
- empty batch `[]` is invalid request content and returns JSON-RPC `-32600` with `id: null`
- notification means request object without `id`
- notifications do not produce JSON-RPC response bodies
- mixed batches return responses only for entries that included `id`, in the same relative order as those entries in the request batch
- `"id": null` is not a notification and receives a response

## 3. Standard JSON-RPC Error Codes

- parse error: `-32700`
- invalid request: `-32600`
- method not found: `-32601`
- invalid params: `-32602`
- internal error: `-32603`

## 4. ZEVM Runtime Error Codes

- method or selector unsupported in active mode: `-32010`
- light mode not ready for `eth_blockNumber` or proof-backed reads (`eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, `eth_getTransactionCount`): `-32011`
- reserved startup checkpoint-age condition code (not runtime-emitted): `-32012`
- reserved startup checkpoint-malformed condition code (not runtime-emitted): `-32013`
- proof verification failed: `-32014`
- malformed data from upstream proof source: `-32015`

## 5. Shared Error Rules

- malformed addresses, selectors, quantities, hex values, tuple lengths, and invalid field combinations fail with `-32602`
- well-formed request for a method or selector defined by the contract but unavailable in active mode fails with `-32010`
- in light mode, `eth_chainId` and `zevm_lightSyncStatus` remain callable regardless of readiness; `-32011` is reserved for `eth_blockNumber` and proof-backed reads only
- well-formed request using a deferred/out-of-contract JSON-RPC method name fails with `-32601`
- trusted lookup misses for block/tx/receipt-returning methods return `null`
- `eth_getLogs` with no matches returns `[]`
- stale/malformed selected startup checkpoint failures happen before listening; `-32012` and `-32013` remain reserved and are not emitted once the listener is active
- WebSocket remains transport-level unsupported; it is not a JSON-RPC method-level error mapping

## 6. Release-Verification Summary (PRD 3.5)

- phase-1 release qualification verifies transport behavior on the shipping path using a real bound HTTP listener socket in trusted mode and in light startup/resume coverage
- notification-only single requests and notification-only batches are explicitly verified to return HTTP `204` with empty body
- release verification is expected to exercise one canonical ZEVM-owned HTTP transport/parser stack on the shipping path (no divergent production parser stacks)
