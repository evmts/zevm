# ZEVM JSON-RPC Contract

Last updated: 2026-03-29

This file is the repo-local exact JSON-RPC backfill for ZEVM.

Use it for:

- exact request tuples
- exact request-object fields
- exact return payloads
- exact trusted-mode `zevm_*` method names
- exact accepted `anvil_*`, `hardhat_*`, and `evm_*` compatibility aliases
- exact block-tag and selector behavior
- exact mode gating
- exact JSON-RPC error behavior

Within the repo-local hierarchy, `docs/specs/prd.md` remains the authoritative intended phase-1 product definition and `docs/specs/docs-first-process.md` remains the process constraint. This file backfills exact JSON-RPC detail referenced by the product contract and may record an explicit contradiction plus public-doc stance for an affected surface, but it must not silently override the PRD or the process docs.

## Common Types

| Type | Exact contract |
| --- | --- |
| `QuantityHex` | `0x`-prefixed unsigned integer with no leading zero padding except `0x0` |
| `Address` | `0x`-prefixed 20-byte hex address |
| `Hash32` | `0x`-prefixed 32-byte hex value |
| `Bytes32` | `0x`-prefixed 32-byte hex value |
| `HexData` | `0x`-prefixed hex byte string, including `0x` for empty bytes |
| `BlockTag` | `latest`, `earliest`, `pending`, `safe`, `finalized`, or a numeric quantity |
| `TrustedBlockSelector` | any `BlockTag` |
| `LightBlockSelector` | `latest`, `earliest`, `safe`, `finalized`, or a numeric quantity |
| `ReceiptSelector` | a single `BlockTag` or a single `Hash32` block hash |

## Transport

The ZEVM transport contract is:

- HTTP only
- path `/`
- request method `POST`
- non-`POST` requests fail with HTTP `405`
- JSON-RPC success responses use HTTP `200`
- JSON-RPC error responses use HTTP `200`
- notification-only requests and notification-only batches use HTTP `204` with an empty body
- response content type is `application/json` whenever a JSON-RPC body is returned

## JSON-RPC Envelope

- ZEVM speaks JSON-RPC `2.0`.
- Single requests are supported.
- Batch requests are supported.
- Empty batch `[]` is invalid request content and returns HTTP `200` with this exact JSON-RPC body:

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
- Mixed valid and invalid items inside a batch are supported.
- A notification is a request object with no `id` member.
- ZEVM sends no JSON-RPC response for notifications.
- A mixed batch emits responses only for items that included an `id`.
- `"id": null` is not a notification and receives a response with `id: null`.

## Global Errors

### Standard JSON-RPC codes

| Condition | Code |
| --- | --- |
| parse error | `-32700` |
| invalid request | `-32600` |
| method not found | `-32601` |
| invalid params | `-32602` |
| internal error | `-32603` |

### ZEVM runtime codes

| Condition | Code |
| --- | --- |
| method unsupported in the active mode | `-32010` |
| light mode is not ready to serve proof-backed reads | `-32011` |
| reserved: selected checkpoint is too old under strict checkpoint-age policy | `-32012` |
| reserved: checkpoint input or persisted checkpoint file is invalid or corrupt | `-32013` |
| proof verification failed | `-32014` |
| upstream light-mode proof source returned malformed data | `-32015` |

### Shared method-level error rules

- malformed addresses, malformed hex data, malformed quantities, malformed block selectors, malformed filter objects, invalid tuple lengths, and invalid request-object field combinations fail with `-32602`
- valid request shapes that target a surface unavailable in the active mode fail with `-32010`
- trusted block or transaction lookup methods return `null` for a well-formed selector that does not resolve to an existing object
- `eth_getLogs` returns `[]` for a well-formed filter that matches no logs
- if the initially selected light-mode checkpoint is stale under strict policy or malformed or corrupt, ZEVM fails startup before opening the listener; `-32012` and `-32013` are therefore reserved codes, not part of the initial proof-backed read method surface in this pass

## Mode And Block-Tag Rules

### Trusted mode

| Selector | Exact meaning |
| --- | --- |
| `latest` | current canonical local head |
| `pending` | compatibility alias of `latest` |
| `safe` | compatibility alias of `latest` |
| `finalized` | compatibility alias of `latest` |
| `earliest` | block `0` |
| numeric quantity | exact local block number |

Trusted-mode `pending`, `safe`, and `finalized` do not provide consensus-backed finality.

### Light mode

| Selector | Exact meaning |
| --- | --- |
| `latest` | latest verified optimistic execution head |
| `safe` | consensus-backed safe execution head |
| `finalized` | consensus-finalized execution head |
| `earliest` | block `0` |
| numeric quantity | block `0`, or an exact block inside the retained verified-history window containing the most recent `8191` verified execution blocks when ZEVM can verify that exact execution block and the requested proof-backed read against that block's state root |
| `pending` | unsupported in light mode and fails with `-32010` |

If light mode is generally not ready for proof-backed reads, ZEVM serves no proof-backed reads and fails them with `-32011`.

If light mode is ready in general, numeric selectors are supported only for block `0` and for exact blocks inside the retained verified-history window containing the most recent `8191` verified execution blocks when ZEVM can verify the exact execution block and the requested proof-backed read against that block's state root.

If light mode is ready in general but the requested numeric block is outside that retained verified-history window, the request fails with `-32602`.

If a selector is otherwise supported but proof verification of the requested read against the resolved block state root fails, the request fails with `-32014`.

If the upstream proof source returns malformed data, the request fails with `-32015`.

ZEVM does not promise arbitrary checkpoint-to-head historical archive reads.

## Shared Objects

### Phase-1 transaction request

`TransactionRequest` is the exact request object used by `eth_call`, `eth_estimateGas`, and `eth_sendTransaction`.

Allowed fields:

| Field | Type | Rule |
| --- | --- | --- |
| `from` | `Address` | required for `eth_sendTransaction`; optional for `eth_call` and `eth_estimateGas` |
| `to` | `Address \| null` | omit or use `null` for contract creation |
| `gas` | `QuantityHex` | optional |
| `gasPrice` | `QuantityHex` | optional |
| `value` | `QuantityHex` | optional |
| `nonce` | `QuantityHex` | optional |
| `data` | `HexData` | optional |
| `input` | `HexData` | optional alias of `data` |

Rules:

- `data` and `input` may both be omitted
- if both `data` and `input` are present, they must be byte-for-byte equal or the request fails with `-32602`
- any field not listed above is invalid in the phase-1 ZEVM contract and fails with `-32602`

### State overrides

`StateOverrideSet` is an object keyed by address. Each keyed value may include:

| Field | Type |
| --- | --- |
| `balance` | `QuantityHex` |
| `nonce` | `QuantityHex` |
| `code` | `HexData` |
| `storage` | object whose keys are `Bytes32` storage slots and whose values are `Bytes32` storage values |

### Fee history result

`FeeHistoryResult` uses this exact shape:

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
- `baseFeePerGas`: array of `QuantityHex` with length `blockCount + 1`
- `gasUsedRatio`: array of JSON numbers with length `blockCount`
- `reward`: optional; when present, it is an array with one item per returned block, and each item is an array of `QuantityHex` values that matches the requested `rewardPercentiles` length

### Transaction object

The exact ZEVM phase-1 transaction object shape is:

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

Field rules:

- `type`, `hash`, `nonce`, `from`, `value`, `gas`, and `input` are always present
- `to` may be `null` for contract creation
- `blockHash`, `blockNumber`, and `transactionIndex` are `null` for pending transactions and populated for mined transactions

### Block object

The exact ZEVM phase-1 block object shape is:

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

Field rules:

- `transactions` is an array of `Hash32` values when `fullTransactions = false`
- `transactions` is an array of transaction objects when `fullTransactions = true`
- optional fork-era fields may be omitted when not applicable

### Receipt object

The exact ZEVM phase-1 receipt object shape is:

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

### Log object

The exact ZEVM phase-1 log object shape is:

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

### Log filter

`LogFilter` is the exact request object for `eth_getLogs`.

Allowed fields:

| Field | Type |
| --- | --- |
| `fromBlock` | `TrustedBlockSelector` |
| `toBlock` | `TrustedBlockSelector` |
| `blockHash` | `Hash32` |
| `address` | `Address` or array of `Address` |
| `topics` | array where each item is `null`, a single `Hash32`, or an array of `Hash32` |

Rules:

- `blockHash` is mutually exclusive with `fromBlock` and `toBlock`
- `fromBlock` must be less than or equal to `toBlock` when both are present
- malformed filter combinations fail with `-32602`

### Light sync status object

`zevm_lightSyncStatus` returns this exact top-level object shape:

```json
{
  "ready": true,
  "status": "synced",
  "network": "mainnet",
  "checkpointSource": "explicit",
  "lastCheckpoint": "0x...",
  "optimisticSlot": "0x1234",
  "finalizedSlot": "0x1230"
}
```

Field rules:

- `ready`: boolean; `true` only when `status = "synced"` and ZEVM can serve proof-backed reads
- `status`: `syncing`, `synced`, or `error`
- `network`: `mainnet`, `sepolia`, or `holesky`
- `checkpointSource`: `explicit`, `persisted`, or `default`
- `lastCheckpoint`: `Hash32` or `null`
- `optimisticSlot`: `QuantityHex`
- `finalizedSlot`: `QuantityHex`

## Trusted-Mode Standard Methods

### Core reads

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `eth_chainId` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params |
| `eth_blockNumber` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params |
| `eth_getBalance` | `[address, block]` | `QuantityHex` | `-32602` for malformed address or selector |
| `eth_getCode` | `[address, block]` | `HexData` | `-32602` for malformed address or selector |
| `eth_getStorageAt` | `[address, slot, block]` | `Bytes32` | `-32602` for malformed address, slot, or selector |
| `eth_getTransactionCount` | `[address, block]` | `QuantityHex` | `-32602` for malformed address or selector |
| `eth_accounts` | `[]` or omitted | array of the 10 managed trusted-mode addresses in ascending index order | `-32602` for non-empty params |
| `eth_coinbase` | `[]` or omitted | `Address` | `-32602` for non-empty params |
| `eth_gasPrice` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params |
| `eth_maxPriorityFeePerGas` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params |
| `eth_blobBaseFee` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params |
| `eth_feeHistory` | `[blockCount, newestBlock]` or `[blockCount, newestBlock, rewardPercentiles]` | `FeeHistoryResult` | `-32602` for malformed count, selector, or percentiles |

### Simulation

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `eth_call` | `[tx, block]` or `[tx, block, stateOverrides]` | `HexData` | `-32602` for malformed tx object, selector, or overrides |
| `eth_estimateGas` | `[tx]`, `[tx, block]`, or `[tx, block, stateOverrides]` | `QuantityHex` | `-32602` for malformed tx object, selector, or overrides |

Rules:

- these methods are trusted-mode only
- they use checkpoint-and-revert semantics and must not mutate canonical state

### Submission and mining-adjacent standard methods

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `eth_sendTransaction` | `[tx]` using the phase-1 `TransactionRequest` object | `Hash32` | `-32602` for malformed tx object; `-32603` for unmanaged account, nonce mismatch, insufficient balance, intrinsic gas failure, or signing failure |
| `eth_sendRawTransaction` | `[rawTx]` where `rawTx` is `HexData` | `Hash32` | `-32602` for malformed hex or decode failure; `-32603` for chain-id mismatch, nonce mismatch, insufficient balance, or intrinsic gas failure |

### Queries

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `eth_getBlockByNumber` | `[block, fullTransactions]` | block object or `null` | `-32602` for malformed selector or boolean |
| `eth_getBlockByHash` | `[blockHash, fullTransactions]` | block object or `null` | `-32602` for malformed hash or boolean |
| `eth_getTransactionByHash` | `[transactionHash]` | transaction object or `null` | `-32602` for malformed hash |
| `eth_getTransactionReceipt` | `[transactionHash]` | receipt object or `null` | `-32602` for malformed hash |
| `eth_getBlockReceipts` | `[block]` where `block` is a `ReceiptSelector` | array of receipt objects or `null` | `-32602` for malformed selector |
| `eth_getLogs` | `[filter]` | array of log objects | `-32602` for malformed filter |

## Trusted-Mode `zevm_*` Methods

### Alias rule

Accepted compatibility aliases are alternate method names for the same ZEVM contract. They share the canonical ZEVM params, return payloads, mode-gating, and error behavior exactly.

ZEVM does not promise byte-for-byte response-shape parity with every external alias source where those external products disagree with one another.

### Account and state objects

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

### Metadata objects

`MinedBlockSummary`:

```json
{
  "number": "0x1",
  "hash": "0x...",
  "timestamp": "0x1"
}
```

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

### Canonical methods and exact accepted aliases

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
| `zevm_increaseTime` | `[seconds]` | `QuantityHex` new accumulated time offset | `anvil_increaseTime`, `evm_increaseTime` |
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

Rules:

- every method in this section is trusted-mode only and fails with `-32010` in light mode
- malformed params fail with `-32602`
- `zevm_revert` returns `false` for an unknown snapshot id instead of raising an error
- `zevm_dropTransaction` returns `false` when the target tx is not in the pool
- `zevm_setIntervalMining([\"0x0\"])` disables interval mining and leaves trusted mode in non-interval operation

## Deferred Trusted-Mode Helpers

These helpers are outside the phase-1 exact contract and remain deferred:

| Canonical deferred helper | Deferred accepted aliases |
| --- | --- |
| `zevm_enableTraces` | `anvil_enableTraces` |
| `zevm_addCompilationResult` | `hardhat_addCompilationResult` |
| `zevm_setPrevRandao` | `hardhat_setPrevRandao` |

`hardhat_setLoggingEnabled` is treated as a deferred compatibility alias for `zevm_enableTraces`.

## Light-Mode Methods

| Method | Exact params | Exact result | Errors |
| --- | --- | --- | --- |
| `zevm_lightSyncStatus` | `[]` or omitted | light sync status object | `-32010` in trusted mode; `-32602` for non-empty params |
| `eth_chainId` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params |
| `eth_blockNumber` | `[]` or omitted | `QuantityHex` | `-32602` for non-empty params; `-32011` while `ready = false` |
| `eth_getBalance` | `[address, block]` where `block` is a `LightBlockSelector` | `QuantityHex` | `-32011`, `-32014`, `-32015`, `-32602` |
| `eth_getCode` | `[address, block]` where `block` is a `LightBlockSelector` | `HexData` | `-32011`, `-32014`, `-32015`, `-32602` |
| `eth_getStorageAt` | `[address, slot, block]` where `block` is a `LightBlockSelector` | `Bytes32` | `-32011`, `-32014`, `-32015`, `-32602` |
| `eth_getTransactionCount` | `[address, block]` where `block` is a `LightBlockSelector` | `QuantityHex` | `-32011`, `-32014`, `-32015`, `-32602` |

Rules:

- `eth_call`, `eth_estimateGas`, transaction submission, mining, snapshots, state mutation, impersonation, filters, subscriptions, and WebSocket transport are unsupported in light mode and fail with `-32010`
- `ready = true` only when `status = "synced"` and ZEVM can serve proof-backed reads
- while `ready = false`, `eth_blockNumber` fails with `-32011`
- once `ready = true`, `eth_blockNumber` returns the block number of the light-mode `latest` head, meaning the latest verified optimistic execution head
- light-mode proof-backed reads never serve unverified data
- while `ready = false`, ZEVM serves no proof-backed reads and fails them with `-32011`
- once ready, numeric selectors are supported only for block `0` and for exact blocks inside the retained verified-history window containing the most recent `8191` verified execution blocks when ZEVM can verify the exact execution block and the requested proof-backed read against that block's state root
- when a ready light-mode node receives a numeric selector outside that retained verified-history window, the request fails with `-32602`
- when a ready light-mode node accepts a supported selector but cannot verify the requested proof-backed read against the resolved block state root, the request fails with `-32014`
- when the upstream proof source returns malformed data for an otherwise-supported light-mode read, the request fails with `-32015`
- light mode does not promise arbitrary checkpoint-to-head historical archive reads

## Deferred And Unsupported Public Surface

These surfaces are not part of the phase-1 or light-mode exact contract:

- debug tracing
- filter lifecycle APIs beyond `eth_getLogs`
- subscriptions
- WebSocket transport
