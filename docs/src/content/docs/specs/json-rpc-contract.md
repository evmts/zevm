---
title: "ZEVM JSON-RPC Contract"
---

# ZEVM JSON-RPC Contract

This file is the exact ZEVM JSON-RPC API contract.

It defines:

- request tuples
- request-object fields
- return payload shapes
- mode gating
- selector resolution
- error behavior
- trusted-mode canonical `zevm_*` methods and accepted aliases

## 1. Common Types

| Type | Contract |
| --- | --- |
| `QuantityHex` | `0x`-prefixed unsigned integer, minimal hex encoding except `0x0` |
| `Address` | `0x`-prefixed 20-byte hex |
| `Hash32` | `0x`-prefixed 32-byte hex |
| `Bytes32` | `0x`-prefixed 32-byte hex |
| `HexData` | `0x`-prefixed byte string hex; `0x` means empty |
| `BlockTag` | `latest`, `earliest`, `pending`, `safe`, `finalized`, or numeric quantity |
| `TrustedBlockSelector` | any `BlockTag` |
| `LightBlockSelector` | `latest`, `earliest`, `pending`, `safe`, `finalized`, or numeric quantity; `pending` is rejected for light proof-backed reads with `-32010` |
| `ReceiptSelector` | one `BlockTag` or one `Hash32` block hash |

## 2. Chain ID Rules

| Runtime | Source | `eth_chainId` result |
| --- | --- | --- |
| trusted mode | configured `chainId` | configured value as `QuantityHex` |
| light mode + `mainnet` | fixed mapping | `0x1` |
| light mode + `sepolia` | fixed mapping | `0xaa36a7` |
| light mode + `holesky` | fixed mapping | `0x4268` |

## 3. Transport

- HTTP only
- JSON-RPC endpoint path is `/` only
- request method for JSON-RPC endpoint is `POST` only
- request path other than `/` -> HTTP `404` with no JSON-RPC body
- non-`POST` request to `/` -> HTTP `405` with no JSON-RPC body
- `POST /` request content type must be `application/json` (media-type parameters allowed); unsupported or missing content type -> HTTP `415` with no JSON-RPC body
- JSON-RPC success responses -> HTTP `200`
- JSON-RPC error responses -> HTTP `200`
- notification-only request or notification-only batch -> HTTP `204` with empty body
- request body limit is `1,048,576` bytes; larger bodies return HTTP `413` with no JSON-RPC body
- HTTP header read buffer limit is `8,192` bytes; oversized or malformed headers close the connection without a JSON-RPC body
- listener accepts up to `64` active TCP connections; slow clients are isolated at the connection layer and do not block other accepted clients
- accepted connections use `15,000` ms read and write socket timeouts
- handler dispatch is serialized within a ZEVM process so concurrent transport connections cannot race the runtime state
- one canonical ZEVM-owned HTTP transport/parser stack is the shipping path for request parsing and envelope dispatch; divergent production parser stacks are out of contract for phase 1
- whenever a JSON-RPC body is returned, content type is `application/json`

## 4. JSON-RPC Envelope

- protocol: JSON-RPC `2.0`
- single requests: supported
- batches: supported
- empty batch `[]`: invalid request and returns HTTP `200` with exactly:

```json
{
  "jsonrpc": "2.0",
  "id": null,
  "error": {
    "code": -32600,
    "message": "Invalid Request"
  }
}
```

- notification = request object with no `id`
- ZEVM sends no JSON-RPC response for notifications
- mixed batches return responses only for entries that had `id`, preserving the input order of those entries
- `"id": null` is not a notification and receives a response

## 5. Errors

### 5.1 Standard codes

| Condition | Code |
| --- | --- |
| parse error | `-32700` |
| invalid request | `-32600` |
| method not found | `-32601` |
| invalid params | `-32602` |
| internal error | `-32603` |

### 5.2 ZEVM runtime codes

| Condition | Code |
| --- | --- |
| method unsupported in active mode | `-32010` |
| light mode not ready for proof-backed reads | `-32011` |
| reserved: selected checkpoint too old under strict startup policy | `-32012` |
| reserved: checkpoint input or persisted checkpoint is malformed/corrupt | `-32013` |
| proof verification failed | `-32014` |
| malformed data from upstream proof source | `-32015` |

### 5.3 Shared error rules

- malformed addresses, quantities, hex bytes, selectors, filters, tuple lengths, or invalid object field combinations -> `-32602`
- well-formed requests for methods defined by this contract but unavailable in active mode -> `-32010`
- well-formed requests that use deferred/out-of-contract JSON-RPC method names (section 14) -> `-32601`
- trusted block/tx lookup miss -> `null`
- `eth_getLogs` no matches -> `[]`
- selected light checkpoint is stale only when `age > maxCheckpointAgeSeconds`; `age == maxCheckpointAgeSeconds` is valid
- `age` is ZEVM's startup-time freshness value for the selected startup checkpoint
- `age` is evaluated once during startup, after checkpoint selection and before stale-policy decision
- `age` is measured in whole seconds: `age = max(0, startupTimeSeconds - checkpointTimeSeconds)`
- `startupTimeSeconds` is sampled at age-check time
- selected startup checkpoint hash must resolve on the selected network via the configured consensus source (`consensusRpcUrl`); network mismatch is startup failure before listening
- `checkpointTimeSeconds` is derived deterministically from Beacon API data for the selected startup checkpoint hash and is anchored to that checkpoint, not to filesystem metadata or local file/write times
- derivation steps are exact:
  1. call `GET <consensusRpcUrl>/eth/v1/beacon/genesis`, require HTTP `200`, parse `data.genesis_time` as decimal unsigned integer `genesisTimeSeconds`
  2. call `GET <consensusRpcUrl>/eth/v1/beacon/headers/{selectedCheckpointHash}`, require HTTP `200`, parse `data.root` as `Hash32` and require equality with `selectedCheckpointHash`, then parse `data.header.message.slot` as decimal unsigned integer `checkpointSlot`
  3. use `SECONDS_PER_SLOT = 12` for phase-1 supported light networks and compute `checkpointTimeSeconds = genesisTimeSeconds + (checkpointSlot * SECONDS_PER_SLOT)` with integer arithmetic
  4. use computed `checkpointTimeSeconds` as integer Unix seconds in age evaluation
- any request failure, non-`200`, missing/malformed required field, checkpoint-root mismatch, or arithmetic overflow in this derivation is inability to resolve `checkpointTimeSeconds` and is startup failure before listening
- stale selected checkpoint + `strictCheckpointAge = false`: emit one operator-facing startup warning before listening, then continue startup
- non-strict stale warnings must be surfaced on startup logs via process `stderr` and must not be surfaced via JSON-RPC
- phase 1 defines no dedicated CLI/config controls for startup log level, log file paths, or alternative startup log sinks
- the non-strict stale warning must include: selected checkpoint hash, `checkpointSource`, `checkpointTimeSeconds`, `startupTimeSeconds`, computed `age`, `maxCheckpointAgeSeconds`, and `strictCheckpointAge = false`
- stale selected checkpoint + `strictCheckpointAge = true`: startup failure before listening
- inability to resolve `checkpointTimeSeconds` for the selected startup checkpoint is startup failure before listening
- checkpoint startup input format split is intentional: CLI/config startup checkpoint input must be `Hash32` (`0x` + 64 hex chars), while persisted `${resolvedCheckpointDir}/checkpoint` content must be 64 hex chars without `0x`
- persisted checkpoint startup input path is `${resolvedCheckpointDir}/checkpoint`, where `resolvedCheckpointDir` is derived from startup `checkpointDir` by applying `<network>` expansion and then resolving relative paths against startup current working directory
- if `${resolvedCheckpointDir}` is missing at startup (including missing expanded `<network>` subdirectory), persisted checkpoint input is treated as absent and startup precedence continues
- if `${resolvedCheckpointDir}/checkpoint` is missing, persisted checkpoint input is treated as absent and startup precedence continues
- startup checkpoint precedence fallthrough is absence-driven only; once a checkpoint source is selected, any validation/derivation failure for that selected source is startup failure before listening and must not trigger fallback to lower-precedence sources
- if `${resolvedCheckpointDir}/checkpoint` exists but is unreadable, startup fails before listening
- malformed initial checkpoint input or malformed readable persisted checkpoint file is startup failure before listening
- ZEVM does not auto-create `${resolvedCheckpointDir}` during startup
- in phase 1, `${resolvedCheckpointDir}/checkpoint` is startup input only; ZEVM does not create, update, or delete this file after the HTTP listener has started
- `-32012` and `-32013` remain reserved at runtime and are not emitted after the HTTP listener has started

## 6. Selector And Mode Semantics

### 6.1 Trusted selectors

| Selector | Meaning |
| --- | --- |
| `latest` | current canonical local head |
| `pending` | alias of `latest` |
| `safe` | alias of `latest` |
| `finalized` | alias of `latest` |
| `earliest` | block `0` |
| numeric quantity | exact local block number |

`pending`, `safe`, and `finalized` in trusted mode are compatibility aliases only.

Pending-alias rule in trusted mode:

- there is no separate pending block view for selector-based queries
- any trusted-mode method that accepts a block selector and receives `pending` must resolve it exactly as `latest`
- methods that need trusted state snapshots may further constrain selectors to the current head; those method-specific constraints are documented in the method section

### 6.2 Light selectors and retained history

| Selector | Meaning |
| --- | --- |
| `latest` | latest verified optimistic execution head |
| `safe` | consensus-backed safe execution head |
| `finalized` | consensus-finalized execution head |
| `earliest` | block `0` |
| numeric quantity | block `0` or a retained numeric block inside the moving verified-history window |
| `pending` | unsupported -> `-32010` |

Retained-history window contract:

- constant window size: `8191` verified execution blocks
- let `H` be current `latest` block number when `ready = true`
- retained numeric range excluding genesis is `[max(1, H - 8190), H]`
- accepted numeric selector set in light mode when ready is:
  - `{0}` union `[max(1, H - 8190), H]`
- numeric selector outside that set -> `-32602`
- selector token `pending` is recognized but unsupported for light proof-backed reads and returns `-32010` (it never aliases `latest`)
- selector `pending` rejection occurs before readiness gating and before retained-window numeric validation
- ZEVM does not promise archive reads outside retained history

Readiness contract:

- proof-backed reads are callable only when `ready = true`
- when `ready = false`, all proof-backed reads fail with `-32011`
- `eth_blockNumber` also fails with `-32011` while not ready
- `eth_chainId` and `zevm_lightSyncStatus` are callable regardless of readiness (`zevm_lightSyncStatus` remains light-mode only)
- `ready` may transition from `false` to `true` only when `status` transitions to `synced` after ZEVM has accepted verified optimistic, safe, and finalized heads for the selected network
- while `ready = true`, `zevm_lightSyncStatus` slot coherence must hold: `finalizedSlot <= safeSlot <= optimisticSlot`
- selector semantics are unchanged: `latest` resolves to the optimistic execution head, `safe` resolves to the consensus-backed safe execution head, and `finalized` resolves to the consensus-finalized execution head
- if `status` leaves `synced` or slot coherence cannot be maintained, ZEVM must set `ready = false` in the same state transition before serving subsequent gated RPC calls

Proof failure contract when ready:

- selector is supported but proof cannot be verified against resolved state root -> `-32014`
- upstream proof response malformed -> `-32015`

## 7. Shared Objects

### 7.1 TransactionRequest (phase 1)

`TransactionRequest` is used by `eth_call`, `eth_estimateGas`, and `eth_sendTransaction`.

Allowed fields only:

| Field | Type | Rule |
| --- | --- | --- |
| `from` | `Address` | required for `eth_sendTransaction`; optional for `eth_call` and `eth_estimateGas` |
| `to` | `Address` or `null` | omitted or `null` for create |
| `gas` | `QuantityHex` | optional |
| `gasPrice` | `QuantityHex` | optional |
| `value` | `QuantityHex` | optional |
| `nonce` | `QuantityHex` | optional |
| `data` | `HexData` | optional |
| `input` | `HexData` | optional alias of `data` |

Field rules:

- `data` and `input` may both be omitted
- if both are present they must be byte-identical, else `-32602`
- any field not listed above is invalid and fails with `-32602`

Fee-model and tx-type constraints:

- phase-1 request fee field is `gasPrice`
- `maxFeePerGas`, `maxPriorityFeePerGas`, `maxFeePerBlobGas`, `blobVersionedHashes`, `accessList`, `authorizationList`, `type`, and `chainId` are unsupported in `TransactionRequest` and fail with `-32602`
- if `eth_sendTransaction` omits `gasPrice`, ZEVM uses trusted-mode node gas price (`eth_gasPrice`) at submission time

### 7.2 Supported transaction envelope types

Submission contract:

- only legacy transaction type `0x0` is supported in phase 1
- `eth_sendTransaction` produces legacy `0x0` transactions
- `eth_sendRawTransaction` accepts only legacy raw transactions
- typed EIP-2718 envelopes (`0x1`, `0x2`, `0x3`, or unknown type byte) are unsupported and fail with `-32602`
- transaction admission computes intrinsic gas and EIP-3860 initcode limits from the runtime-owned hardfork policy configured at trusted startup

### 7.3 StateOverrideSet

Object keyed by address; each value may include:

| Field | Type |
| --- | --- |
| `balance` | `QuantityHex` |
| `nonce` | `QuantityHex` |
| `code` | `HexData` |
| `storage` | object mapping `Bytes32` slot -> `Bytes32` value |

### 7.4 FeeHistoryResult

`FeeHistoryResult` shape:

```json
{
  "oldestBlock": "0x0",
  "baseFeePerGas": ["0x3b9aca00", "0x3b9aca00"],
  "gasUsedRatio": [0.0],
  "reward": [["0x0"]]
}
```

Field rules:

- `oldestBlock`: `QuantityHex`
- `baseFeePerGas`: length `N + 1`
- `gasUsedRatio`: length `N`
- `reward`: optional; when present, length `N`, each inner array length equals requested percentile count
- `N` is the number of returned blocks after truncation (see `eth_feeHistory`)

### 7.5 Transaction object

```json
{
  "type": "0x0",
  "hash": "0x...",
  "nonce": "0x0",
  "blockHash": "0x...",
  "blockNumber": "0x0",
  "transactionIndex": "0x0",
  "from": "0x...",
  "to": "0x...",
  "value": "0x0",
  "gas": "0x5208",
  "input": "0x"
}
```

Rules:

- `type` is always `0x0` in phase 1
- `to` may be `null` for create
- for current phase-1 trusted query methods, `blockHash`, `blockNumber`, and `transactionIndex` are non-null because txpool-only pending entries are not surfaced by `eth_getTransactionByHash`
- transaction objects in this contract must not include a nonstandard `blockTimestamp` field

### 7.6 Block object

```json
{
  "hash": "0x...",
  "parentHash": "0x...",
  "sha3Uncles": "0x...",
  "miner": "0x...",
  "stateRoot": "0x...",
  "transactionsRoot": "0x...",
  "receiptsRoot": "0x...",
  "logsBloom": "0x...",
  "number": "0x0",
  "gasLimit": "0x0",
  "gasUsed": "0x0",
  "timestamp": "0x0",
  "extraData": "0x",
  "mixHash": "0x...",
  "nonce": "0x0000000000000000",
  "size": "0x0",
  "transactions": [],
  "uncles": [],
  "difficulty": "0x0",
  "totalDifficulty": "0x0",
  "baseFeePerGas": "0x0",
  "withdrawalsRoot": "0x...",
  "blobGasUsed": "0x0",
  "excessBlobGas": "0x0",
  "parentBeaconBlockRoot": "0x..."
}
```

Rules:

- `transactions` is array of `Hash32` when `fullTransactions=false`
- `transactions` is array of transaction objects when `fullTransactions=true`
- `hash` and `number` are non-null for returned canonical blocks
- `nonce` is `HexData` encoding exactly 8 bytes (`0x` + 16 hex chars)
- fork-era fields may be omitted when not applicable

Field contract:

| Field | Required | Type | Nullability / rule |
| --- | --- | --- | --- |
| `hash` | yes | `Hash32` | non-null for returned block objects |
| `parentHash` | yes | `Hash32` | non-null |
| `sha3Uncles` | yes | `Hash32` | non-null |
| `miner` | yes | `Address` | non-null |
| `stateRoot` | yes | `Hash32` | non-null |
| `transactionsRoot` | yes | `Hash32` | non-null |
| `receiptsRoot` | yes | `Hash32` | non-null |
| `logsBloom` | yes | `HexData` | non-null bloom bytes |
| `number` | yes | `QuantityHex` | non-null for returned block objects |
| `gasLimit` | yes | `QuantityHex` | non-null |
| `gasUsed` | yes | `QuantityHex` | non-null |
| `timestamp` | yes | `QuantityHex` | non-null |
| `extraData` | yes | `HexData` | non-null |
| `mixHash` | yes | `Hash32` | non-null |
| `nonce` | yes | `HexData` | exactly 8-byte value |
| `size` | yes | `QuantityHex` | non-null |
| `transactions` | yes | array | element type depends on `fullTransactions` |
| `uncles` | yes | array of `Hash32` | non-null (empty array allowed) |
| `difficulty` | yes | `QuantityHex` | non-null |
| `totalDifficulty` | yes | `QuantityHex` | non-null |
| `baseFeePerGas` | conditional | `QuantityHex` | omitted when not applicable |
| `withdrawalsRoot` | conditional | `Hash32` | omitted when not applicable |
| `blobGasUsed` | conditional | `QuantityHex` | omitted when not applicable |
| `excessBlobGas` | conditional | `QuantityHex` | omitted when not applicable |
| `parentBeaconBlockRoot` | conditional | `Hash32` | omitted when not applicable |

### 7.7 Receipt object

```json
{
  "transactionHash": "0x...",
  "transactionIndex": "0x0",
  "blockHash": "0x...",
  "blockNumber": "0x0",
  "from": "0x...",
  "to": "0x...",
  "cumulativeGasUsed": "0x0",
  "gasUsed": "0x0",
  "contractAddress": null,
  "logs": [],
  "logsBloom": "0x...",
  "status": "0x1",
  "root": null,
  "effectiveGasPrice": "0x0",
  "type": "0x0",
  "blobGasUsed": null,
  "blobGasPrice": null
}
```

Field contract:

| Field | Required | Type | Nullability / rule |
| --- | --- | --- | --- |
| `transactionHash` | yes | `Hash32` | non-null |
| `transactionIndex` | yes | `QuantityHex` | non-null |
| `blockHash` | yes | `Hash32` | non-null |
| `blockNumber` | yes | `QuantityHex` | non-null |
| `from` | yes | `Address` | non-null |
| `to` | yes | `Address` or `null` | `null` only for create transactions |
| `cumulativeGasUsed` | yes | `QuantityHex` | non-null |
| `gasUsed` | yes | `QuantityHex` | non-null |
| `contractAddress` | yes | `Address` or `null` | non-null only for create transactions |
| `logs` | yes | array of log objects | non-null (empty array allowed) |
| `logsBloom` | yes | `HexData` | non-null bloom bytes |
| `status` | yes | `QuantityHex` | must be `0x0` or `0x1` in phase 1 |
| `root` | yes | `Hash32` or `null` | `null` in phase 1 |
| `effectiveGasPrice` | yes | `QuantityHex` | non-null |
| `type` | yes | `QuantityHex` | always `0x0` in phase 1 |
| `blobGasUsed` | yes | `QuantityHex` or `null` | `null` in phase 1 |
| `blobGasPrice` | yes | `QuantityHex` or `null` | `null` in phase 1 |

Rules:

- receipt objects in this contract must not include a nonstandard `blockTimestamp` field

### 7.8 Log object

```json
{
  "removed": false,
  "logIndex": "0x0",
  "transactionIndex": "0x0",
  "transactionHash": "0x...",
  "blockHash": "0x...",
  "blockNumber": "0x0",
  "address": "0x...",
  "data": "0x",
  "topics": []
}
```

Field contract:

| Field | Required | Type | Nullability / rule |
| --- | --- | --- | --- |
| `removed` | yes | boolean | always `false` for canonical ZEVM responses |
| `logIndex` | yes | `QuantityHex` | non-null |
| `transactionIndex` | yes | `QuantityHex` | non-null |
| `transactionHash` | yes | `Hash32` | non-null |
| `blockHash` | yes | `Hash32` | non-null |
| `blockNumber` | yes | `QuantityHex` | non-null |
| `address` | yes | `Address` | non-null |
| `data` | yes | `HexData` | non-null |
| `topics` | yes | array of `Hash32` | non-null (empty array allowed) |

Rules:

- log objects in this contract must not include a nonstandard `blockTimestamp` field

### 7.9 LogFilter for `eth_getLogs`

Allowed fields:

| Field | Type |
| --- | --- |
| `fromBlock` | `TrustedBlockSelector` |
| `toBlock` | `TrustedBlockSelector` |
| `blockHash` | `Hash32` |
| `address` | `Address` or array of `Address` |
| `topics` | array of `null`, `Hash32`, or array of `Hash32` |

Rules:

- `blockHash` is mutually exclusive with `fromBlock` and `toBlock`
- if both `fromBlock` and `toBlock` are present, resolved `fromBlock <= toBlock` is required
- if `blockHash` is provided, ZEVM searches only that canonical block's logs
- if `blockHash` is omitted, default `fromBlock` is `latest` and default `toBlock` is `latest`
- when `blockHash` is omitted, `fromBlock` and `toBlock` are resolved with trusted selector semantics (`pending`, `safe`, `finalized` alias `latest`)
- address filtering:
  - omitted `address` matches all emitters
  - single `address` matches exact emitter address
  - address array is OR semantics across provided addresses
- topics filtering:
  - topic positions are ANDed by index
  - each topic position entry is either wildcard `null`, one exact topic, or an OR-array of exact topics
- result ordering is deterministic ascending: `blockNumber`, then `transactionIndex`, then `logIndex`
- malformed filters fail with `-32602`

### 7.10 Light sync status object

`zevm_lightSyncStatus` result:

```json
{
  "ready": true,
  "status": "synced",
  "network": "mainnet",
  "checkpointSource": "explicit",
  "lastCheckpoint": "0x...",
  "optimisticSlot": "0x1234",
  "safeSlot": "0x1232",
  "finalizedSlot": "0x1230"
}
```

Field rules:

- `ready`: boolean; true only when proof-backed reads are available
- `status`: `syncing`, `synced`, or `error`
- `network`: `mainnet`, `sepolia`, or `holesky`
- `checkpointSource`: startup checkpoint-selection source and stable for process lifetime:
  - `explicit`: selected from user-provided checkpoint input (CLI `--checkpoint` or config `mode.light.checkpoint`)
  - `persisted`: selected from `${resolvedCheckpointDir}/checkpoint` (section 5.3)
  - `default`: selected from ZEVM bundled release/build default checkpoint for the selected network (deterministic for that release/build artifact, may rotate across releases/builds, and is not a frozen API hash)
- `lastCheckpoint`: `Hash32`, non-null after listener startup
- `optimisticSlot`: `QuantityHex`, non-null
- `safeSlot`: `QuantityHex`, non-null
- `finalizedSlot`: `QuantityHex`, non-null
- `finalizedSlot <= safeSlot <= optimisticSlot`
- effective release/build defaults are auditable by startup with no explicit or persisted checkpoint override; in that case `checkpointSource = "default"` and `lastCheckpoint` is the selected default
- release metadata provenance policy for release/build default claims is defined in PRD section 3.4 (`docs/specs/prd.md`) and applies unchanged here

Lifecycle contract by `status`:

| `status` | `ready` | `optimisticSlot` / `safeSlot` / `finalizedSlot` |
| --- | --- | --- |
| `syncing` | must be `false` | all required `QuantityHex`; may be `0x0` until corresponding headers are available |
| `synced` | must be `true` | all required `QuantityHex` representing current optimistic/safe/finalized slots |
| `error` | must be `false` | all required `QuantityHex` representing last known slots at/just before failure; not nullified |

Readiness and head-coherence invariants:

- `ready` may transition from `false` to `true` only when `status` transitions to `synced` after ZEVM has accepted verified optimistic, safe, and finalized heads for the selected network
- while `ready = true`, slot coherence must hold: `finalizedSlot <= safeSlot <= optimisticSlot`
- if `status` leaves `synced` or slot coherence cannot be maintained, ZEVM must set `ready = false` in the same state transition before serving subsequent gated RPC calls

`lastCheckpoint` semantics:

- `lastCheckpoint` is the most recently accepted checkpoint root in the local light-sync state
- after successful startup checkpoint selection and validation, it equals the selected startup checkpoint
- it updates whenever ZEVM accepts a newer checkpoint during sync progression
- it is not pinned to the configured checkpoint once sync has advanced
- `checkpointSource` does not track later `lastCheckpoint` updates and remains the startup source (`explicit`, `persisted`, or `default`)

## 8. Trusted-Mode Standard Methods

### 8.1 Core reads

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `eth_chainId` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params |
| `eth_blockNumber` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params |
| `eth_getBalance` | `[address, block]` | `QuantityHex` | `-32602` for malformed address or selector |
| `eth_getCode` | `[address, block]` | `HexData` | `-32602` for malformed address or selector |
| `eth_getStorageAt` | `[address, slot, block]` | `Bytes32` | `-32602` for malformed address, slot, or selector |
| `eth_getStorageValues` | `[storageRequest, block]` | object keyed by `Address`, each value an array of `Bytes32` in requested slot order | `-32602` for malformed request, empty request, malformed address, slot, or selector |
| `eth_getProof` | `[address, storageKeys, block]` | account proof object with live account fields and requested storage values | `-32602` for malformed address, storage key, or selector |
| `eth_getTransactionCount` | `[address, block]` | `QuantityHex` | `-32602` for malformed address or selector |
| `eth_accounts` | `[]` or omitted | array of the 10 managed trusted-mode addresses in ascending index order | `-32602` for non-empty params |
| `eth_coinbase` | `[]` or omitted | `Address` | `-32602` for non-empty params |
| `eth_gasPrice` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params |
| `eth_maxPriorityFeePerGas` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params |
| `eth_blobBaseFee` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params |
| `eth_feeHistory` | `[blockCount, newestBlock]` or `[blockCount, newestBlock, rewardPercentiles]` | `FeeHistoryResult` | `-32602` on malformed count, selector, or percentiles |

Trusted-mode state-backed reads (`eth_getBalance`, `eth_getCode`, `eth_getStorageAt`, `eth_getStorageValues`, `eth_getProof`, and `eth_getTransactionCount`) are current-head only. `latest`, `pending`, `safe`, and `finalized` are accepted because they alias the head; `earliest` is accepted only while the current head is genesis; numeric selectors are accepted only when equal to the current head. Other resolved non-head selectors return `-32602`.

### 8.2 Simulation

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `eth_call` | `[tx, block]` or `[tx, block, stateOverrides]` | `HexData` | `-32602` for malformed tx/selectors/overrides; `-32603` for runtime execution failure |
| `eth_estimateGas` | `[tx]`, `[tx, block]`, or `[tx, block, stateOverrides]` | `QuantityHex` | `-32602` for malformed tx/selectors/overrides; `-32603` for runtime execution failure |
| `eth_createAccessList` | `[tx]` or `[tx, block]` | object with `accessList` and `gasUsed` | `-32602` for malformed tx/selector; `-32603` for unrecoverable runtime execution failure |
| `eth_simulateV1` | `[payload]` or `[payload, block]` | array of simulated block result objects | `-32602` for malformed payload/selector; per-call execution failures are returned inside the call result |
| `testing_buildBlockV1` | `[parentHash, payloadAttributes, transactions|null, extraData]` | engine API builder payload envelope | `-32602` for malformed params; `-32000` when supplied transactions cannot be applied |

Simulation semantics:

- checkpoint-and-revert execution path
- no canonical state mutation
- success path:
  - `eth_call` returns `HexData`
  - `eth_estimateGas` returns `QuantityHex`
  - `eth_createAccessList` returns a generated access-list envelope; the current trusted implementation returns an empty list when no local tracer-derived entries are available
  - `eth_simulateV1` returns block-scoped call result objects using checkpointed execution and reverts all canonical state changes at the end of the request
- runtime execution failure path (for example revert/out-of-gas/invalid execution in simulation context): JSON-RPC error `-32603` with message `Internal error`, no `result`, and no revert-data result payload
- omitted transaction field defaults:
  - `from`: trusted runtime coinbase
  - `gas`: selected simulation block gas limit
  - `gasPrice`: trusted runtime gas price
  - `value`: `0x0`
  - `nonce`: no nonce check
  - `data`/`input`: empty bytes
- create semantics:
  - omitted `to` or `to: null` executes the request as contract creation
  - create simulations use the sender's current nonce for CREATE address and collision semantics
  - created code and the temporary sender nonce increment are reverted before the response
- gas estimation:
  - computes intrinsic gas for the runtime-owned active hardfork and whether the request is create or call
  - uses the explicit `gas` value as the upper bound when present; otherwise uses the selected simulation block gas limit
  - rejects upper bounds below intrinsic gas or above the selected block gas limit with `-32603`
  - requires the upper bound to execute successfully, then binary-searches for the lowest successful gas limit in `[intrinsic, upperBound]`
- block environment:
  - current-head simulations use the trusted runtime chain ID, coinbase, head block number, head timestamp, gas limit, base fee, blob base fee, and active one-shot block-environment overrides
  - state-backed simulation is current-head only; selectors that resolve to a non-head block return `-32602`
  - omitted `gas` defaults to the selected simulation block gas limit

### 8.3 Submission

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `eth_sendTransaction` | `[tx]` (`TransactionRequest`) | `Hash32` | `-32602` malformed request/unsupported fields; `-32603` runtime rejection |
| `eth_sendRawTransaction` | `[rawTx]` | `Hash32` | `-32602` malformed hex/decode/unsupported tx type; `-32603` runtime rejection |

Submission outcome semantics:

- success: ZEVM accepts submission into trusted runtime and returns the tx hash as `result` (the tx may be pending or already mined depending on mining mode)
- runtime rejection: ZEVM returns JSON-RPC error `-32603`
- runtime rejection must not include a tx hash result (`result` is absent)
- `eth_sendTransaction` signer scope is managed trusted accounts plus currently impersonated accounts; unmanaged non-impersonated `from` is a runtime rejection (`-32603`)
- unmanaged impersonated `eth_sendTransaction` uses an unsigned legacy envelope plus explicit sender metadata in the trusted txpool/receipt indexes; txpool content, mined transaction queries, block full-transaction hydration, and receipts must report that metadata sender rather than recovering from zero signature fields
- phase-1 implementation-defined for runtime rejection: exact reason classification and `error.message` text

### 8.4 Queries

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `eth_getBlockByNumber` | `[block, fullTransactions]` | block object or `null` | `-32602` malformed selector/boolean |
| `eth_getBlockByHash` | `[blockHash, fullTransactions]` | block object or `null` | `-32602` malformed hash/boolean |
| `eth_getBlockTransactionCountByHash` | `[blockHash]` | `QuantityHex` or `null` | `-32602` malformed hash |
| `eth_getBlockTransactionCountByNumber` | `[block]` | `QuantityHex` or `null` | `-32602` malformed selector |
| `eth_getUncleCountByBlockHash` | `[blockHash]` | `QuantityHex` | `-32602` malformed hash |
| `eth_getUncleCountByBlockNumber` | `[block]` | `QuantityHex` | `-32602` malformed selector |
| `eth_getTransactionByHash` | `[transactionHash]` | tx object or `null` | `-32602` malformed hash |
| `eth_getTransactionByBlockHashAndIndex` | `[blockHash, index]` | tx object or `null` | `-32602` malformed hash/index |
| `eth_getTransactionByBlockNumberAndIndex` | `[block, index]` | tx object or `null` | `-32602` malformed selector/index |
| `eth_getTransactionReceipt` | `[transactionHash]` | receipt object or `null` | `-32602` malformed hash |
| `eth_getBlockReceipts` | `[block]` (`ReceiptSelector`) | receipt array or `null` | `-32602` malformed selector |
| `eth_getLogs` | `[filter]` | log array | `-32602` malformed filter |

Query selector behavior:

- for trusted selector-based queries, `pending` resolves exactly as `latest` (compatibility alias only)
- `eth_getBlockByNumber("pending", ...)`, `eth_getBlockTransactionCountByNumber("pending")`, `eth_getUncleCountByBlockNumber("pending")`, `eth_getTransactionByBlockNumberAndIndex("pending", ...)`, and `eth_getBlockReceipts("pending")` therefore query the current canonical head block, not a separate mempool/pending block
- `eth_getBlockTransactionCountByHash`, `eth_getBlockTransactionCountByNumber`, `eth_getTransactionByBlockHashAndIndex`, and `eth_getTransactionByBlockNumberAndIndex` return `null` when the referenced canonical block is not found
- `eth_getUncleCountByBlockHash` and `eth_getUncleCountByBlockNumber` return `0x0` for unknown blocks and for all ZEVM-produced post-Merge blocks
- `eth_getTransactionByBlockHashAndIndex` and `eth_getTransactionByBlockNumberAndIndex` return `null` when `index` is out of range for a found block
- `eth_getTransactionByHash` is canonical-mined only and returns `null` for txpool-only pending entries
- `eth_getTransactionReceipt` is mined-only and returns `null` until inclusion

### 8.5 Compatibility utility and txpool methods

These methods are intentionally exposed in trusted mode as compatibility helpers. They are trusted-only in phase 1; in light mode, well-formed requests return `-32010`.

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `web3_clientVersion` | `[]` or omitted | implementation version string | `-32602` for non-empty params |
| `web3_sha3` | `[HexData]` | Keccak-256 `Hash32` | `-32602` for malformed hex data |
| `net_version` | `[]` or omitted | decimal chain-id string | `-32602` for non-empty params |
| `net_listening` | `[]` or omitted | `true` | `-32602` for non-empty params |
| `net_peerCount` | `[]` or omitted | `QuantityHex` peer count; phase-1 trusted mode returns `0x0` | `-32602` for non-empty params |
| `eth_mining` | `[]` or omitted | boolean; `true` when mining mode is not manual | `-32602` for non-empty params |
| `eth_syncing` | `[]` or omitted | `false` in trusted mode | `-32602` for non-empty params |
| `eth_protocolVersion` | `[]` or omitted | protocol version string; phase-1 trusted mode returns `0x41` | `-32602` for non-empty params |
| `txpool_content` | `[]` or omitted | geth-style pending/queued txpool content object | `-32602` for non-empty params |
| `txpool_contentFrom` | `[address]` | geth-style pending/queued txpool content object filtered to one sender | `-32602` for malformed address or tuple length |
| `txpool_status` | `[]` or omitted | object with `pending` and `queued` `QuantityHex` counts | `-32602` for non-empty params |
| `txpool_inspect` | `[]` or omitted | geth-style pending/queued summary object | `-32602` for non-empty params |

### 8.6 Debug/raw inspection methods

These methods are trusted-mode only. In light mode, well-formed requests return `-32010`.

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `debug_getBadBlocks` | `[]` or omitted | bad-block array; phase-1 trusted mode returns `[]` | `-32602` for non-empty params |
| `debug_getRawBlock` | `[blockNumber]` | raw RLP block `HexData` or `null` | `-32602` for malformed block number |
| `debug_getRawHeader` | `[blockNumber]` | raw RLP header `HexData` or `null` | `-32602` for malformed block number |
| `debug_getRawReceipts` | `[blockNumber]` | array of raw receipt `HexData` values or `null` when block is unknown | `-32602` for malformed block number |
| `debug_getRawTransaction` | `[transactionHash]` | raw transaction `HexData` or `null` | `-32602` for malformed transaction hash |

### 8.7 Engine API listener methods

The Engine API listener is trusted-mode only and disabled unless startup config enables `engineRpc` or CLI `--engine-host` / `--engine-port`.

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `engine_exchangeCapabilities` | `[capabilities]` where `capabilities` is an array of strings | array of implemented Engine method names | `-32602` for malformed params |
| `engine_exchangeTransitionConfigurationV1` | `[config]` where `config` is an object | object echo of the supplied transition config | `-32602` for malformed params |
| `engine_forkchoiceUpdatedV1` / `engine_forkchoiceUpdatedV2` / `engine_forkchoiceUpdatedV3` | `[forkchoiceState]` or `[forkchoiceState, null]` | `{ payloadStatus, payloadId: null }` | `-32602` for malformed params or non-null payload attributes |
| `engine_newPayloadV1` / `engine_newPayloadV2` | `[executionPayload]` | `PayloadStatusV1`; current trusted implementation returns `SYNCING` without importing the payload | `-32602` for malformed params |
| `engine_newPayloadV3` | `[executionPayload, expectedBlobVersionedHashes, parentBeaconBlockRoot]` | `PayloadStatusV1`; current trusted implementation returns `SYNCING` without importing the payload | `-32602` for malformed params |
| `engine_newPayloadV4` / `engine_newPayloadV5` | `[executionPayload, expectedBlobVersionedHashes, parentBeaconBlockRoot, executionRequests]` | `PayloadStatusV1`; current trusted implementation returns `SYNCING` without importing the payload | `-32602` for malformed params |
| `engine_getPayloadV1` / `engine_getPayloadV2` / `engine_getPayloadV3` / `engine_getPayloadV4` / `engine_getPayloadV5` / `engine_getPayloadV6` | `[payloadId]` where `payloadId` is 8 bytes of `HexData` | payload envelope when known | `-38001` for unknown payload id; `-32602` for malformed params |
| `engine_getPayloadBodiesByHashV1` | `[blockHashes]` where `blockHashes` is an array of `Hash32` values | array of payload body objects or `null` for unknown hashes | `-32602` for malformed params or more than 1024 hashes |
| `engine_getPayloadBodiesByRangeV1` | `[startBlockNumber, count]` | array of payload body objects or `null` for unknown numbers | `-32602` for malformed params, zero count, more than 1024 bodies, or range overflow |
| `engine_getBlobsV1` / `engine_getBlobsV2` | `[versionedHashes]` where `versionedHashes` is an array of `Hash32` values | array of blob records or `null` for unknown hashes; phase-1 trusted mode returns `null` per requested hash | `-32602` for malformed params or more than 1024 hashes |

`forkchoiceState` must include `headBlockHash`, `safeBlockHash`, and `finalizedBlockHash` as `Hash32` strings. `safeBlockHash` and `finalizedBlockHash` may be zero hashes. A known local `headBlockHash` returns `VALID` and updates the canonical head; unknown referenced hashes return `SYNCING`. Payload-building storage remains minimal in phase 1: get-payload methods report unknown payload ids with `-38001`, and new-payload methods validate request shape but do not import execution payloads into canonical history.

## 9. Trusted-Mode `zevm_*` Methods

### 9.1 Alias rule

Accepted aliases in this section are alternative method names for the same ZEVM behavior and payload contract.

### 9.2 Objects

`AccountState`:

```json
{
  "balance": "0x0",
  "nonce": "0x0",
  "code": "0x",
  "storage": {
    "0x0000000000000000000000000000000000000000000000000000000000000000": "0x0000000000000000000000000000000000000000000000000000000000000000"
  }
}
```

Field contract:

| Field | Required | Type | Nullability / rule |
| --- | --- | --- | --- |
| `balance` | yes | `QuantityHex` | non-null |
| `nonce` | yes | `QuantityHex` | non-null |
| `code` | yes | `HexData` | non-null |
| `storage` | yes | object mapping `Bytes32` -> `Bytes32` | non-null (empty object allowed) |

`StateBlob`:

`zevm_dumpState` returns `HexData` whose decoded bytes are UTF-8 JSON with this shape:

```json
{
  "version": 1,
  "accounts": {
    "0x0000000000000000000000000000000000000000": {
      "balance": "0x0",
      "nonce": "0x0",
      "code": "0x",
      "storage": {}
    }
  }
}
```

Field contract:

| Field | Required | Type | Nullability / rule |
| --- | --- | --- | --- |
| `version` | yes | integer | must be `1` |
| `accounts` | yes | object mapping `Address` -> `AccountState` | non-null; empty object allowed |

Rules:

- dump output is sorted by address for stable blobs
- `zevm_loadState` replaces local account/code/storage state-manager caches with the blob contents
- `zevm_loadState` does not mutate fork config, chain metadata, mining config, pending txs, snapshots, receipts, logs, or canonical blocks

`MinedBlockSummary`:

```json
{
  "number": "0x1",
  "hash": "0x...",
  "timestamp": "0x1"
}
```

Field contract:

| Field | Required | Type | Nullability / rule |
| --- | --- | --- | --- |
| `number` | yes | `QuantityHex` | non-null |
| `hash` | yes | `Hash32` | non-null |
| `timestamp` | yes | `QuantityHex` | non-null |

`NodeMetadata`:

```json
{
  "mode": "trusted",
  "chainId": "0x7a69",
  "forking": false,
  "forkUrl": null,
  "forkBlockNumber": null
}
```

Field contract:

| Field | Required | Type | Nullability / rule |
| --- | --- | --- | --- |
| `mode` | yes | string literal | always `"trusted"` |
| `chainId` | yes | `QuantityHex` | non-null |
| `forking` | yes | boolean | non-null |
| `forkUrl` | yes | string or `null` | must be `null` when `forking=false` |
| `forkBlockNumber` | yes | `QuantityHex` or `null` | must be `null` when `forking=false` |

`NodeInfo`:

```json
{
  "chainId": "0x7a69",
  "coinbase": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "blockNumber": "0x0",
  "managedAccounts": [
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  ],
  "mining": {
    "type": "auto",
    "blockTime": null
  },
  "fork": {
    "enabled": false,
    "url": null,
    "blockNumber": null
  }
}
```

Field contract:

| Field | Required | Type | Nullability / rule |
| --- | --- | --- | --- |
| `chainId` | yes | `QuantityHex` | non-null |
| `coinbase` | yes | `Address` | non-null |
| `blockNumber` | yes | `QuantityHex` | non-null |
| `managedAccounts` | yes | array of `Address` | non-null; addresses are returned in managed index order |
| `mining` | yes | object | non-null; see nested contract below |
| `fork` | yes | object | non-null; see nested contract below |

`NodeInfo.mining` nested contract:

| Field | Required | Type | Nullability / rule |
| --- | --- | --- | --- |
| `type` | yes | string enum | `auto`, `manual`, or `interval` |
| `blockTime` | yes | `QuantityHex` or `null` | non-null only when `type = "interval"` |

`NodeInfo.fork` nested contract:

| Field | Required | Type | Nullability / rule |
| --- | --- | --- | --- |
| `enabled` | yes | boolean | non-null |
| `url` | yes | string or `null` | non-null only when `enabled = true` |
| `blockNumber` | yes | `QuantityHex` or `null` | `null` means fork head; may be non-null only when `enabled = true` |

### 9.3 Canonical methods and accepted aliases

| Canonical method | Exact params | Exact result | Exact accepted aliases |
| --- | --- | --- | --- |
| `zevm_getAccount` | `[address]` or `[address, block]` | `AccountState` | none |
| `zevm_setAccount` | `[address, accountState]` | `true` | none |
| `zevm_dumpState` | `[]` or omitted | `HexData` state blob | `anvil_dumpState` |
| `zevm_loadState` | `[stateBlob]` | `true` | `anvil_loadState` |
| `zevm_setBalance` | `[address, balance]` | `true` | `anvil_setBalance`, `hardhat_setBalance` |
| `zevm_addBalance` | `[address, delta]` | `true` | `anvil_addBalance` |
| `zevm_setCode` | `[address, code]` | `true` | `anvil_setCode`, `hardhat_setCode` |
| `zevm_setNonce` | `[address, nonce]` | `true` | `anvil_setNonce`, `hardhat_setNonce` |
| `zevm_setStorageAt` | `[address, slot, value]` | `true` | `anvil_setStorageAt`, `hardhat_setStorageAt` |
| `zevm_setChainId` | `[chainId]` | `true` | `anvil_setChainId` |
| `zevm_getAutomine` | `[]` or omitted | boolean | `anvil_getAutomine`, `hardhat_getAutomine` |
| `zevm_setAutomine` | `[enabled]` | `true` | `anvil_setAutomine`, `evm_setAutomine` |
| `zevm_getIntervalMining` | `[]` or omitted | `QuantityHex` seconds, `0x0` when disabled | `anvil_getIntervalMining` |
| `zevm_setIntervalMining` | `[seconds]` | `true` | `anvil_setIntervalMining`, `evm_setIntervalMining` |
| `zevm_mine` | `[]`, `[count]`, or `[count, intervalSeconds]` | `true` | `anvil_mine`, `hardhat_mine`, `evm_mine` |
| `zevm_mineDetailed` | `[]`, `[count]`, or `[count, intervalSeconds]` | array of `MinedBlockSummary` | `anvil_mineDetailed` |
| `zevm_dropTransaction` | `[transactionHash]` | boolean | `anvil_dropTransaction`, `hardhat_dropTransaction` |
| `zevm_dropAllTransactions` | `[]` or omitted | `QuantityHex` removed count | `anvil_dropAllTransactions` |
| `zevm_removePoolTransactions` | `[transactionHashes]` | `QuantityHex` removed count | `anvil_removePoolTransactions` |
| `zevm_snapshot` | `[]` or omitted | `QuantityHex` snapshot id | `anvil_snapshot`, `evm_snapshot` |
| `zevm_revert` | `[snapshotId]` | boolean | `anvil_revert`, `evm_revert` |
| `zevm_impersonateAccount` | `[address]` | `true` | `anvil_impersonateAccount`, `hardhat_impersonateAccount` |
| `zevm_stopImpersonatingAccount` | `[address]` | `true` | `anvil_stopImpersonatingAccount`, `hardhat_stopImpersonatingAccount` |
| `zevm_autoImpersonateAccount` | `[enabled]` | `true` | `anvil_autoImpersonateAccount` |
| `zevm_increaseTime` | `[seconds]` | `QuantityHex` accumulated offset | `anvil_increaseTime`, `evm_increaseTime` |
| `zevm_setNextBlockTimestamp` | `[timestamp]` | `true` | `anvil_setNextBlockTimestamp`, `evm_setNextBlockTimestamp` |
| `zevm_setTime` | `[timestamp]` | `QuantityHex` effective current timestamp | `anvil_setTime` |
| `zevm_setBlockTimestampInterval` | `[seconds]` | `true` | `anvil_setBlockTimestampInterval` |
| `zevm_removeBlockTimestampInterval` | `[]` or omitted | `true` | `anvil_removeBlockTimestampInterval` |
| `zevm_reset` | `[]` or omitted, or `[forkConfig]` where `forkConfig` is `null`, `{ "url": "https://..." }`, or `{ "url": "https://...", "blockNumber": "0x..." }` | `true` | `anvil_reset`, `hardhat_reset` |
| `zevm_setRpcUrl` | `[url]` | `true` | `anvil_setRpcUrl` |
| `zevm_setCoinbase` | `[address]` | `true` | `anvil_setCoinbase`, `hardhat_setCoinbase` |
| `zevm_setBlockGasLimit` | `[gasLimit]` | `true` | `anvil_setBlockGasLimit`, `evm_setBlockGasLimit` |
| `zevm_setNextBlockBaseFeePerGas` | `[baseFee]` | `true` | `anvil_setNextBlockBaseFeePerGas`, `hardhat_setNextBlockBaseFeePerGas` |
| `zevm_setMinGasPrice` | `[gasPrice]` | `true` | `anvil_setMinGasPrice`, `hardhat_setMinGasPrice` |
| `zevm_deal` | `[address, value]` | `true` | `anvil_deal` |
| `zevm_dealErc20` | `[token, address, value]` | `true` | `anvil_dealErc20` |
| `zevm_setErc20Allowance` | `[token, owner, spender, value]` | `true` | `anvil_setErc20Allowance` |
| `zevm_metadata` | `[]` or omitted | `NodeMetadata` | `anvil_metadata`, `hardhat_metadata` |
| `zevm_nodeInfo` | `[]` or omitted | `NodeInfo` | `anvil_nodeInfo` |

Parameter token typing contract (applies to the `Exact params` column above):

| Param token | Type | Contract |
| --- | --- | --- |
| `address`, `token`, `owner`, `spender` | `Address` | section 1 `Address` |
| `block` | `TrustedBlockSelector` | section 1 `TrustedBlockSelector` |
| `accountState` | `AccountState` | section 9.2 `AccountState` object |
| `stateBlob`, `code` | `HexData` | section 1 `HexData` |
| `slot` | `Bytes32` | section 1 `Bytes32` |
| `transactionHash` | `Hash32` | section 1 `Hash32` |
| `transactionHashes` | array of `Hash32` | each element must satisfy section 1 `Hash32` |
| `enabled` | boolean | JSON boolean |
| `seconds`, `count`, `intervalSeconds`, `chainId`, `balance`, `delta`, `nonce`, `snapshotId`, `timestamp`, `gasLimit`, `baseFee`, `gasPrice`, `value` | `QuantityHex` | section 1 `QuantityHex` |
| `url` | string | non-empty `http://` or `https://` URL string |
| `forkConfig` | `null` or object | exact forms: `null`, `{ "url": "https://..." }`, or `{ "url": "https://...", "blockNumber": "0x..." }`; when present, `blockNumber` is `QuantityHex` |

Rules:

- methods in this section are trusted-mode only -> `-32010` in light mode
- malformed params -> `-32602`
- `zevm_revert` returns `false` for unknown snapshot id
- `zevm_dropTransaction` returns `false` if tx is absent
- `zevm_setIntervalMining(["0x0"])` disables interval mining
- `zevm_reset` uses `QuantityHex` for `forkConfig.blockNumber`; startup CLI/config fork block numbers use decimal `u64` (example: startup decimal `1000000` corresponds to JSON-RPC `"blockNumber": "0xf4240"`)
- `zevm_autoImpersonateAccount([enabled])` toggles automatic impersonation mode; signer-scope interaction with manual impersonation is defined in section 9.6
- snapshot/revert boundary:
  - `zevm_snapshot`/`zevm_revert` capture and restore trusted local runtime state (local chain/state/journal, receipt/log indexes, pending tx pool, mining/block-environment overrides, impersonation, and time controls)
  - `zevm_snapshot`/`zevm_revert` do not capture light-mode consensus/checkpoint-sync state and do not mutate remote fork-source state

### 9.4 `zevm_reset` semantics

- call forms:
  - `[]` or omitted: reset trusted runtime state while keeping current fork configuration unchanged
  - `[null]`: reset trusted runtime state and disable fork backing
  - `[forkConfig]` object: reset trusted runtime state and replace fork backing with the provided URL and optional pinned block
- successful reset always:
  - sets canonical local chain back to trusted genesis (`0x0`)
  - clears pending transaction pool
  - invalidates previously created snapshot IDs
  - clears impersonation state and one-shot time/timestamp overrides
  - keeps configured startup `chainId` unchanged
  - keeps the startup/configured hardfork policy unchanged
- fork config object semantics:
  - `{ "url": "https://..." }`: enable fork backing at upstream head
  - `{ "url": "https://...", "blockNumber": "0x..." }`: enable fork backing pinned to that block
- if fork initialization fails (for example unreachable upstream or invalid fork block), call fails with `-32603`

### 9.5 `zevm_setRpcUrl` semantics

- exact params: `[url]` with non-empty `http://` or `https://` URL string
- precondition: fork backing is currently enabled; otherwise call fails with `-32603`
- effect: updates the active fork upstream URL in place
- non-effects: does not reset local chain state, does not clear pending pool, and does not invalidate snapshots
- current fork block pin behavior:
  - if current fork config has `blockNumber = null`, backing remains at upstream head semantics
  - if current fork config has a pinned `blockNumber`, that same pin remains active after URL update

### 9.6 Impersonation semantics

- `eth_sendTransaction` signer scope is the union of:
  - managed trusted accounts
  - manual impersonation set (`zevm_impersonateAccount` adds, `zevm_stopImpersonatingAccount` removes)
  - all addresses when auto impersonation is enabled
- `zevm_autoImpersonateAccount([true])` enables automatic impersonation for any `from` address
- `zevm_autoImpersonateAccount([false])` disables automatic impersonation; signer scope then falls back to managed accounts plus the current manual impersonation set
- toggling `zevm_autoImpersonateAccount` does not clear or mutate manual impersonation entries
- `zevm_stopImpersonatingAccount` affects only the manual impersonation set; while auto impersonation is enabled, sends from that address remain allowed
- unmanaged impersonated `eth_sendTransaction` persists explicit sender metadata for an unsigned legacy envelope, and all txpool, mined transaction, block hydration, and receipt responses must use that metadata sender

## 10. Trusted Mining Semantics

### 10.1 Pending pool and inclusion

- pending ordering is nonce-aware per sender
- when a block is mined, ZEVM includes executable pending transactions in canonical order up to block gas limit
- non-executable queued transactions remain pending

### 10.2 Mining mode triggers

- `auto`:
  - trigger: accepting an executable transaction via `eth_sendTransaction` or `eth_sendRawTransaction`
  - effect: immediate single-block mining pass
  - empty blocks: not produced by automine trigger
- `manual`:
  - trigger: explicit mine RPC only (`zevm_mine`, `zevm_mineDetailed`, aliases)
  - effect: no background mining on tx submission
  - empty blocks: allowed during explicit mine calls
- `interval`:
  - trigger: periodic timer every configured `blockTime` seconds
  - effect: one block per tick
  - empty blocks: allowed and expected when no executable tx is pending
  - lifecycle: startup interval config and `zevm_setIntervalMining` own exactly one runtime timer; switching to auto/manual or setting interval `0` stops it

Explicit mine calls are valid in all mining modes and mine immediately.

### 10.3 Explicit mine call semantics

For `zevm_mine`/`zevm_mineDetailed`:

- default params (`[]`) -> mine exactly 1 block
- `[count]` -> mine exactly `count` blocks
- `[count, intervalSeconds]` -> mine exactly `count` blocks and increment timestamp by `intervalSeconds` between consecutive mined blocks in that call
- if pending txs are exhausted before `count` blocks are mined, remaining blocks are empty

### 10.4 Timestamp progression

Timestamp invariants:

- every new block must satisfy `timestamp > parent.timestamp`
- timer-mined interval blocks advance by interval cadence
- explicit multi-block mine calls advance timestamp for each mined block

Timestamp precedence for the next mined block:

1. one-shot `zevm_setNextBlockTimestamp` override (must be greater than parent)
2. explicit `intervalSeconds` argument for current `zevm_mine`/`zevm_mineDetailed` call
3. `zevm_setBlockTimestampInterval` override if enabled
4. interval-mining `blockTime` when block comes from interval tick
5. otherwise `max(parent.timestamp + 1, effective_current_time)`

`effective_current_time` includes active time offset from `zevm_increaseTime` and `zevm_setTime`.

## 11. `eth_feeHistory` Exact Behavior

Method: `eth_feeHistory`

Supported params:

- `[blockCount, newestBlock]`
- `[blockCount, newestBlock, rewardPercentiles]`

Validation:

- tuple length must be 2 or 3, else `-32602`
- `blockCount` must decode as `QuantityHex` and be `>= 1`, else `-32602`
- `newestBlock` is resolved as a trusted selector
  - `pending`, `safe`, `finalized` resolve as `latest`
  - `earliest` resolves as `0`
  - numeric selector must resolve to an existing canonical block number, else `-32602`
- if `rewardPercentiles` is present:
  - must be an array
  - length must be `<= 100`
  - each item must be finite numeric `0 <= p <= 100`
  - array must be non-decreasing
  - otherwise `-32602`

Bounds and truncation:

- maximum effective `blockCount` is `1024`
- `effectiveCount = min(requestedBlockCount, 1024)`
- result range ends at resolved `newestBlock`
- range is truncated at genesis if needed
- no error is raised for either truncation

Returned range computation:

- `newest = resolved newest block number`
- `returnedCount = min(effectiveCount, newest + 1)`
- `oldest = newest + 1 - returnedCount`

Result construction:

- `oldestBlock = oldest`
- `baseFeePerGas` has `returnedCount + 1` items:
  - one per block in `[oldest, newest]`
  - plus the next-block base fee after `newest`
- `gasUsedRatio` has `returnedCount` items, one per block in `[oldest, newest]`
- `reward` behavior:
  - omitted entirely when `rewardPercentiles` param is absent
  - present when `rewardPercentiles` is provided (including empty array)
  - outer length is `returnedCount`
  - each inner array length equals `rewardPercentiles.length`
  - for empty blocks, all reward entries are `0x0`

## 12. Deferred Trusted Helpers

These are outside the exact phase-1 contract:

| Canonical deferred helper | Deferred accepted aliases |
| --- | --- |
| `zevm_enableTraces` | `anvil_enableTraces` |
| `zevm_addCompilationResult` | `hardhat_addCompilationResult` |
| `zevm_setPrevRandao` | `hardhat_setPrevRandao` |

`hardhat_setLoggingEnabled` is deferred as a compatibility alias of `zevm_enableTraces`.

## 13. Light-Mode Methods

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `zevm_lightSyncStatus` | `[]` or omitted | light sync status object | `-32010` in trusted mode; `-32602` for non-empty params |
| `eth_chainId` | `[]` or omitted | `QuantityHex` from network mapping (`0x1`, `0xaa36a7`, `0x4268`) | `-32602` for non-empty params |
| `eth_blockNumber` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params; `-32011` while not ready |
| `eth_getBalance` | `[address, block]` where `block` is `LightBlockSelector` | `QuantityHex` | `-32602`, `-32010`, `-32011`, `-32015`, `-32014` |
| `eth_getCode` | `[address, block]` where `block` is `LightBlockSelector` | `HexData` | `-32602`, `-32010`, `-32011`, `-32015`, `-32014` |
| `eth_getStorageAt` | `[address, slot, block]` where `block` is `LightBlockSelector` | `Bytes32` | `-32602`, `-32010`, `-32011`, `-32015`, `-32014` |
| `eth_getTransactionCount` | `[address, block]` where `block` is `LightBlockSelector` | `QuantityHex` | `-32602`, `-32010`, `-32011`, `-32015`, `-32014` |

Rules:

- unsupported in light mode (-> `-32010`) includes:
  - `eth_call` (trusted-only in phase 1; deferred light-mode proof-backed target)
  - `eth_estimateGas`
  - `eth_createAccessList`
  - `eth_simulateV1`
  - `testing_buildBlockV1`
  - `eth_getProof`
  - `eth_feeHistory`
  - `eth_sendTransaction`, `eth_sendRawTransaction`
  - `eth_getBlockByNumber`, `eth_getBlockByHash`
  - `eth_getBlockTransactionCountByHash`, `eth_getBlockTransactionCountByNumber`
  - `eth_getTransactionByHash`, `eth_getTransactionByBlockHashAndIndex`, `eth_getTransactionByBlockNumberAndIndex`, `eth_getTransactionReceipt`
  - `eth_getBlockReceipts`, `eth_getLogs`
  - all trusted-mode `zevm_*` mutation, mining, snapshot/revert, and impersonation controls
- proof-backed read evaluation order in light mode is exact:
  1. malformed tuple/field/encoding input (including malformed selector token) -> `-32602`
  2. selector `pending` -> `-32010`
  3. `ready = false` -> `-32011` for all remaining selectors, including numeric selectors that would be outside retained history
  4. when `ready = true`, numeric selector outside retained set `{0}` union `[max(1, H - 8190), H]` -> `-32602`
  5. when `ready = true`, malformed upstream proof payload -> `-32015`
  6. when `ready = true`, well-formed proof payload that fails verification against resolved state root -> `-32014`
- while not ready: proof-backed reads and `eth_blockNumber` fail with `-32011` after input validation and selector-support checks
- once ready: `eth_blockNumber` returns light-mode `latest` head number
- light-mode numeric selector acceptance is exactly the retained-history rule in section 6.2
- in phase 1, `${resolvedCheckpointDir}/checkpoint` is startup input only; `lastCheckpoint` runtime progression is not persisted to this file
- phase-1 operator-facing light-mode startup inputs are `network`, `consensusRpcUrl`, `executionRpcUrl`, `checkpoint`, `checkpointDir`, `maxCheckpointAgeSeconds`, and `strictCheckpointAge`
- `executionRpcUrl` is the execution JSON-RPC source used for proof-backed execution reads
- deferred/out-of-contract method families (for example subscriptions and debug tracing) are listed in section 14
- deferred/out-of-contract method names return JSON-RPC `-32601` (method not found), not `-32010`
- WebSocket transport is unsupported at transport layer (section 3) and is not a JSON-RPC method mapping

## 14. Unsupported Public Surface

Not part of the current contract:

- debug tracing methods
- subscriptions
- WebSocket transport

JSON-RPC mapping for this deferred/out-of-contract surface:

- requesting a deferred/out-of-contract JSON-RPC method name returns `-32601` (method not found)
- WebSocket remains transport-level unsupported (section 3) rather than a JSON-RPC method-level mapping
