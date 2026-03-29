# ZEVM Internal Support: Transport And Error Semantics

Last updated: 2026-03-29

This file is a support-layer summary. The exact contract lives in `../json-rpc-contract.md`.

## HTTP Transport

### Intended behavior

- HTTP JSON-RPC requests are served at `/`
- request method is `POST`
- success and error responses use HTTP `200`
- notification requests and notification-only batches use HTTP `204` with an empty body
- non-`POST` requests use HTTP `405`

### Observed code constraints

- `src/rpc/server.zig` plus `src/rpc/dispatcher.zig` is the intended shipping path
- `src/rpc/server.zig` does not inspect the request target and therefore does not enforce the documented `/` path
- the older `src/rpc/envelope.zig` plus `src/rpc/router.zig` stack is still present in-tree but is stale and non-shipping
- both in-tree transport paths still violate notification semantics, and the current helper tests codify the wrong response-bearing behavior instead of the HTTP `204` no-body contract

### Affected public pages

- `mintlify/docs/reference/json-rpc/overview.mdx`
- `mintlify/docs/quickstart/installation.mdx`

### Source IDs

- `RPC-01`
- `RPC-02`

## Empty Batch Behavior

### Intended behavior

- Non-empty batch support is part of the intended transport contract.
- Empty batch `[]` is invalid request content.
- HTTP `POST /` with body `[]` returns HTTP `200` and a single JSON-RPC error object with `jsonrpc: "2.0"`, `id: null`, and `error: { "code": -32600, "message": "Invalid Request" }`.

### Observed code constraints

- The prototype `src/rpc/envelope.zig` path rejects `[]` with `error.InvalidRequest`, and `src/rpc/envelope_test.zig` codifies that behavior.
- The intended `src/rpc/server.zig` path delegates batch parsing to upstream `jsonrpc.envelope.parseSingleOrBatch`, but that path does not compile against the current upstream export surface.

### Affected public pages

- `mintlify/docs/reference/json-rpc/overview.mdx`

### Source IDs

- `RPC-05`

## Notification Semantics

### Intended behavior

- mixed valid and invalid items inside a batch are supported
- a notification is a JSON-RPC request object with no `id` member
- ZEVM sends no response for notifications
- mixed batches emit responses only for requests that included an `id`
- `"id": null` is not a notification and receives a response with `id: null`

### Observed code constraints

- the current repository still serializes responses for notification-shaped requests

### Affected public pages

- `mintlify/docs/reference/json-rpc/overview.mdx`

### Source IDs

- `RPC-02`

## Standard JSON-RPC Errors

### Intended behavior

- parse error maps to `-32700`
- invalid request maps to `-32600`
- method not found maps to `-32601`
- invalid params maps to `-32602`
- internal error maps to `-32603`

### Observed code constraints

- current dispatcher validation is shallow
- failure paths commonly collapse into `-32603` instead of preserving the more specific code

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

## ZEVM Runtime Errors

### Intended behavior

- `-32010` means the method is unsupported in the active mode
- `-32011` means light mode is not ready
- `-32012` is reserved for light-mode checkpoint-age failures
- `-32013` is reserved for light-mode checkpoint-validation failures
- `-32014` means proof verification failed
- `-32015` means the upstream response was malformed

### Observed code constraints

- the repository does not yet implement the ZEVM-specific runtime error layer
- the current codebase does not have public light-mode routing for readiness failures or verified-read failures
- the initial light-mode checkpoint failures documented in config remain startup failures before ZEVM listens

### Affected public pages

- `mintlify/docs/reference/json-rpc/overview.mdx`
- `mintlify/docs/reference/json-rpc/simulation.mdx`
- `mintlify/docs/reference/json-rpc/transactions-and-mining.mdx`
- `mintlify/docs/reference/json-rpc/verified-light-mode-reads.mdx`
- `mintlify/docs/reference/json-rpc/unsupported-and-deferred.mdx`

### Source IDs

- `RPC-04`
