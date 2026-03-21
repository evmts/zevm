# ZEVM Internal Support: Transport And Error Semantics

Last updated: 2026-03-21

## HTTP Transport Contract

Canonical intended transport:

- transport: HTTP
- path: `/`
- request method: `POST`
- success and JSON-RPC error responses: HTTP `200`
- content type: `application/json`
- non-`POST` requests: HTTP `405`
- notification-only requests and notification-only batches: HTTP `204` with empty body

Canonical implementation direction:

- intended shipping path: `src/rpc/server.zig` plus `src/rpc/dispatcher.zig`
- non-canonical prototype path: `src/rpc/envelope.zig` plus `src/rpc/router.zig`

- current repo reality: the newer path is the executable direction but does not build cleanly; the older local path remains in-tree; both paths violate notification semantics
- source IDs: `RPC-01`, `RPC-02`
- contradiction IDs: `C-002`, `C-010`

## Notification Semantics

Notification rules:

- notification = JSON-RPC request object with no `id` member
- ZEVM sends no response for notifications
- mixed batches emit responses only for the requests that included an `id`
- `"id": null` is not a notification and receives a response with `id: null`

- current repo reality: `src/rpc/server.zig`, `src/rpc/dispatcher.zig`, `src/rpc/envelope.zig`, and `src/rpc/router.zig` all still serialize a response for notification-shaped requests
- documentation rule: this is a concrete contract violation, not an open wording choice
- source IDs: `RPC-02`
- contradiction IDs: `C-002`

## Error Contract

Standard JSON-RPC error mapping:

| Condition | Code |
| --- | --- |
| parse error | `-32700` |
| invalid request | `-32600` |
| method not found | `-32601` |
| invalid params | `-32602` |
| internal error | `-32603` |

ZEVM-specific runtime errors:

| Condition | Code |
| --- | --- |
| method unsupported in the active mode | `-32010` |
| light mode not ready | `-32011` |
| checkpoint too old under strict policy | `-32012` |
| invalid or corrupt checkpoint | `-32013` |
| proof verification failure | `-32014` |
| malformed upstream response | `-32015` |

- current repo reality: current dispatcher validation is shallow, and the repo does not yet implement the ZEVM-specific runtime error layer
- source IDs: `RPC-03`
- contradiction IDs: `C-002`, `C-012`
