# Research Context: add-logs-types-to-voltaire

**Ticket:** `add-logs-types-to-voltaire`  
**Category:** `cat-5-block-queries`  
**Date:** 2026-02-27

## Goal

In `../voltaire/packages/voltaire-zig/src/jsonrpc/`, add:
- A `Filter` params type for `eth_getLogs` with fields:
  - `address`
  - `fromBlock`
  - `toBlock`
  - `topics`
  - `blockHash`
- A `LogEntry` response type for `eth_getLogs` with fields:
  - `address`
  - `topics`
  - `data`
  - `blockNumber`
  - `transactionHash`
  - `transactionIndex`
  - `blockHash`
  - `logIndex`
  - `removed`
- Update `eth_getLogs.zig` so:
  - `Params.filter` uses `Filter`
  - `Result.value` uses an array of `LogEntry`

## Current Voltaire State

### JSON-RPC methods are currently placeholder-typed for logs/filter methods

- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getLogs/eth_getLogs.zig`
  - `Params.filter: types.Quantity`
  - `Result.value: types.Quantity`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/newFilter/eth_newFilter.zig`
  - `Params.filter: types.Quantity`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getFilterLogs/eth_getFilterLogs.zig`
  - `Result.value: types.Quantity`
- `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getFilterChanges/eth_getFilterChanges.zig`
  - `Result.value: types.Quantity`

### JSON-RPC shared types currently exported

- `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` exports only:
  - `Address`
  - `Hash`
  - `Quantity`
  - `BlockTag`
  - `BlockSpec`

There is no existing `Filter` or `LogEntry` JSON-RPC type module under:
- `../voltaire/packages/voltaire-zig/src/jsonrpc/types/`

### Relevant primitives already exist in Voltaire

- `../voltaire/packages/voltaire-zig/src/primitives/EventLog/EventLog.zig`
  - `EventLog` already includes:
    - `address`
    - `topics`
    - `data`
    - `block_number`
    - `transaction_hash`
    - `transaction_index`
    - `log_index`
    - `removed`
  - `LogFilter` includes:
    - `address`
    - `topics`
    - `from_block`
    - `to_block`
    - `block_hash`
- `../voltaire/packages/voltaire-zig/src/primitives/TopicFilter/topic_filter.zig`
  - Has explicit support for:
    - positional topic matching
    - wildcard entries
    - OR-topic lists per position
    - max 4 topics

### State manager / blockchain integration gap

- `../voltaire/packages/voltaire-zig/src/state-manager/` has no direct log query API.
- `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig` focuses on block storage and canonical chain lookups; no log-index query surface yet.
- `../voltaire/packages/voltaire-zig/src/evm/log/handlers_log.zig` emits EVM logs (`address`, `topics`, `data`) but does not itself define RPC log object serialization.

Implication: this ticket is correctly scoped to JSON-RPC type plumbing first.

## Canonical Specification Sources

### execution-apis method + schema definitions

- `execution-apis/src/eth/filter.yaml`
  - `eth_getLogs` param is `Filter`
  - result schema references `FilterResults`
- `execution-apis/src/schemas/filter.yaml`
  - `Filter` supports two modes:
    - block range mode (`fromBlock`, `toBlock`, optional `address`, `topics`)
    - block hash mode (`blockHash`, optional `address`, `topics`)
  - `blockHash` mode is mutually exclusive with range mode
  - `address` supports:
    - single address
    - array of addresses
    - `null`
  - topics support:
    - wildcard
    - single topic
    - OR-list per topic position
- `execution-apis/src/schemas/receipt.yaml` (`Log` schema)
  - log fields include:
    - `removed`
    - `logIndex`
    - `transactionIndex`
    - `transactionHash`
    - `blockHash`
    - `blockNumber`
    - `blockTimestamp`
    - `address`
    - `data`
    - `topics`

Note: `blockTimestamp` exists in execution-apis log schema, but is not requested in this ticket’s `LogEntry` field list.

### execution-apis conformance tests for `eth_getLogs`

Directory:
- `execution-apis/tests/eth_getLogs/`

Key behavior covered:
- `contract-addr.io`: address array filtering
- `no-topics.io`: range query without topic filter
- `topic-exact-match.io`: exact positional topics
- `topic-wildcard.io`: wildcard topic position using empty array entry
- `filter-with-blockHash.io`: block hash scoped query
- `filter-with-blockHash-and-topics.io`: block hash + topic constraints
- `filter-error-invalid-blockHash-and-range.io`: reject `blockHash` with `fromBlock`/`toBlock`
- `filter-error-reversed-block-range.io`: reject reversed range
- `filter-error-future-block-range.io`: reject range beyond head

## EIP and Protocol References

- `EIPs/EIPS/eip-234.md`
  - Introduces `blockHash` for filter options used by `eth_newFilter` and `eth_getLogs`.
  - Explicitly states `blockHash` should be mutually exclusive with `fromBlock`/`toBlock`.
- `EIPs/EIPS/eip-1474.md`
  - Defines RPC method-level shape for `eth_getLogs` and log object fields.
  - Documents topic order semantics and wildcard/OR matching patterns.
- `yellowpaper/Paper.tex`
  - Canonical EVM log tuple semantics:
    - logger address
    - ordered topics (0..4)
    - data
  - Log bloom derivation from address and topics.

## Reference Implementations

### Hardhat EDR (Rust)

- `edr/crates/edr_eth/src/filter.rs`
  - `LogFilterOptions` fields:
    - `from_block`
    - `to_block`
    - `block_hash`
    - `address` (one-or-many)
    - `topics` (positional optional one-or-many)
  - `LogOutput` fields:
    - `removed`
    - `log_index`
    - `transaction_index`
    - `transaction_hash`
    - `block_hash`
    - `block_number`
    - `address`
    - `data`
    - `topics`
- `edr/crates/edr_provider/src/requests/eth/filter.rs`
  - Validates `blockHash` exclusivity with range fields.
  - Resolves `blockHash` to exact block-number range.
  - Normalizes addresses and topics for matching.
- `edr/crates/edr_receipt/src/log.rs`
  - Topic matching helper shows positional matching with per-position wildcard/OR representation.
- `edr/crates/edr_provider/src/requests/methods.rs`
  - `eth_getLogs` docs and method wiring.

### Foundry / Anvil

- `foundry/crates/anvil/src/filter.rs`
  - Filter lifecycle and polling (`eth_newFilter`, `eth_getFilterChanges` style infra).
- `foundry/crates/anvil/src/pubsub.rs`
  - `filter_logs` includes address/topic/block-range/hash checks and emits log entries.
- `foundry/crates/anvil/src/eth/backend/mem/mod.rs`
  - `logs()` path for `eth_getLogs`, with range and block-hash mode.
- `foundry/crates/anvil/tests/it/logs.rs`
  - Integration coverage for:
    - range queries
    - address/topic filtering
    - `at_block_hash` lookups
    - consistency between receipt logs and getLogs output

### Hardhat (TypeScript provider layer)

- `hardhat/v-next/hardhat-ethers/src/internal/hardhat-ethers-provider/hardhat-ethers-provider.ts`
  - Canonicalizes topics and addresses.
  - Asserts `blockHash` cannot be combined with `fromBlock`/`toBlock`.
- `hardhat/v-next/hardhat-ethers/test/hardhat-ethers-provider.ts`
  - `getLogs` tests for:
    - default latest behavior
    - block range
    - address and address-array filters
    - topic filtering

### TEVM

- `../tevm-monorepo/packages/actions/src/eth/ethGetLogsHandler.js`
  - Accepts filter params with address/topics/range.
  - Handles OR topics and null-like wildcard forms.
  - Returns structured log output fields aligned with RPC.
- `../tevm-monorepo/packages/actions/src/eth/ethGetLogsProcedure.js`
  - Converts internal numeric indices/block numbers to hex quantities.
- `../tevm-monorepo/packages/actions/src/eth/ethGetLogsHandler.spec.ts`
  - Tests OR-topics, wildcards, range, forked mode behavior.

## Path-by-Path Coverage Notes (Requested Inputs)

- `docs/specs/`
  - Reviewed `docs/specs/prd.md`; it explicitly lists `eth_getLogs` and filter namespace work.
- `../voltaire/packages/voltaire-zig/src/jsonrpc/`
  - Reviewed current method/type placeholders and integration points.
- `../voltaire/packages/voltaire-zig/src/state-manager/`
  - Reviewed; no dedicated log-query surface yet.
- `../voltaire/packages/voltaire-zig/src/blockchain/`
  - Reviewed; block-centric storage only, no log index APIs.
- `../voltaire/packages/voltaire-zig/src/evm/`
  - Reviewed log opcode handling for upstream log semantics.
- `../bench/guillotine-mini/client/rpc/`
  - Path missing in this checkout.
- `../bench/guillotine-mini/client/engine/`
  - Path missing in this checkout.
  - Closest available local upstream references reviewed instead:
    - `../guillotine-mini/src/` (EVM/log internals)
    - `../guillotine-mini/execution-apis/` (mirrored API schema/tests)
- `edr/crates/edr_provider/src/requests/`
  - Reviewed `methods.rs` and `eth/filter.rs` for validation and shape.
- `foundry/`
  - Reviewed Anvil filter/log implementation and integration tests.
- `hardhat/`
  - Reviewed v-next hardhat-ethers provider filter normalization and tests.
- `../tevm-monorepo/packages/actions/src/`
  - Reviewed `ethGetLogs` handler/procedure and tests.
- `execution-apis/`
  - Reviewed method schema, filter schema, log schema, and `eth_getLogs` tests.
- `execution-specs/src/ethereum/`
  - Reviewed EVM log/receipt canonical structures and LOG opcode behavior.
- `ethereum-tests/`
  - Scanned; no direct JSON-RPC `eth_getLogs` conformance artifacts found.
- `execution-spec-tests/tests/`
  - Scanned; primarily fork/opcode tests, no direct `eth_getLogs` RPC suite.
- `EIPs/EIPS/`
  - Reviewed EIP-1474, EIP-234, EIP-1898, plus draft forward-looking log EIPs.
- `consensus-specs/specs/`
  - Reviewed for relevance; contains consensus p2p topics and execution payload fields, not `eth_getLogs` RPC semantics.
- `yellowpaper/`
  - Reviewed canonical EVM/receipt/log semantics.
- `hive/simulators/ethereum/`
  - Reviewed; focus is Engine API / consensus compatibility, not `eth_getLogs` semantics.

## Gaps and Decisions for Implementation

1. Address shape in `Filter` should support single-or-array (and likely nullable), not only a single address.
2. Topics shape should support positional wildcards and OR lists per position.
3. `blockHash` with `fromBlock`/`toBlock` exclusivity should be validated at handler/runtime layer.
4. `LogEntry` should include exactly ticket-requested fields even though execution-apis also includes `blockTimestamp`.
5. This ticket updates `eth_getLogs`; closely-related filter methods (`eth_newFilter`, `eth_getFilterLogs`, `eth_getFilterChanges`) remain placeholder-typed and are natural follow-up work.

## Suggested File Changes (for implementation phase)

- Create:
  - `../voltaire/packages/voltaire-zig/src/jsonrpc/types/Filter.zig`
  - `../voltaire/packages/voltaire-zig/src/jsonrpc/types/LogEntry.zig`
- Update:
  - `../voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` (exports)
  - `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/getLogs/eth_getLogs.zig`

This keeps the change narrowly scoped to JSON-RPC typing and method signatures as requested.
