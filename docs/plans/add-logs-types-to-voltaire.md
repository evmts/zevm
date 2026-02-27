# TDD Implementation Plan: Add Logs Types to Voltaire

## Overview
The goal is to implement the JSON-RPC `Filter` and `LogEntry` types in the `voltaire` repository for the `eth_getLogs` method. These types must strictly match the Ethereum Execution APIs specification for log filtering and log entry responses.

## Ticket
- **ID**: `add-logs-types-to-voltaire`
- **Category**: `cat-5-block-queries`
- **Goal**: In `../voltaire/packages/voltaire-zig/src/jsonrpc/`, create `Filter` params type with `address`, `fromBlock`, `toBlock`, `topics`, `blockHash` fields. Create `LogEntry` response type with `address`, `topics`, `data`, `blockNumber`, `transactionHash`, `transactionIndex`, `blockHash`, `logIndex`, `removed` fields. Update `eth_getLogs.zig` Params to use `Filter` and Result to use array of `LogEntry`.

## Reference Specifications

### Filter Schema (from execution-apis/src/schemas/filter.yaml)
The `Filter` type is a `oneOf` with two variants:
1. **Filter by block range**: `fromBlock`, `toBlock`, `address`, `topics`
2. **Filter by block hash**: `blockHash`, `address`, `topics`

Fields:
- `fromBlock`: `uint` (block number)
- `toBlock`: `uint` (block number)
- `blockHash`: `hash32` (32-byte hash)
- `address`: `null | address | addresses` (single or array of 20-byte addresses)
- `topics`: `FilterTopics` (null or array of `FilterTopic`)

`FilterTopic` is `bytes32 | array of bytes32` (allows topic wildcards).

### LogEntry Schema (from execution-apis/src/schemas/receipt.yaml)
The `Log` type represents a log entry with the following fields:
- `removed`: `boolean` (true if log was removed due to chain reorg)
- `logIndex`: `uint` (index within block)
- `transactionIndex`: `uint` (index within block)
- `transactionHash`: `hash32` (required)
- `blockHash`: `hash32`
- `blockNumber`: `uint`
- `blockTimestamp`: `uint`
- `address`: `address` (20-byte contract address)
- `data`: `bytes` (unindexed log data)
- `topics`: `array of bytes32` (indexed event parameters)

## TDD Step Order (Tests before implementation)

We will follow a strict Test-Driven Development approach, ensuring that serialization/deserialization behavior is validated against the execution-apis specification before writing the implementation.

### Step 1: Implement `Filter` type
- **Test First**: Create `Filter_test.zig`. Write unit tests to verify:
  - JSON parsing of block range filter (`fromBlock`, `toBlock`, `address`, `topics`)
  - JSON parsing of block hash filter (`blockHash`, `address`, `topics`)
  - Address field handling: null, single address, or array of addresses
  - Topics field handling: null, single topics, or array of topic arrays (wildcard support)
  - JSON serialization roundtrip
- **Implementation**: Create `Filter.zig`. Define the struct with all filter fields as optionals. Implement `jsonParseFromValue` and `jsonStringify` methods. Export it in `types.zig`.

### Step 2: Implement `LogEntry` type
- **Test First**: Create `LogEntry_test.zig`. Write tests to verify:
  - JSON serialization of a complete log entry with all fields
  - Handling of `removed` flag (boolean)
  - Proper hex encoding for `address`, `topics`, `data`, hashes
  - Quantity encoding for numeric fields (`logIndex`, `transactionIndex`, `blockNumber`)
  - JSON parsing roundtrip
- **Implementation**: Create `LogEntry.zig`. Define the struct with all log entry fields. Implement `jsonStringify` and `jsonParseFromValue` methods. Export it in `types.zig`.

### Step 3: Update `eth_getLogs.zig` Params type
- **Test First**: Update existing tests (if any) or create new tests in `eth_getLogs_test.zig` to verify:
  - Params correctly parses a Filter object from JSON-RPC request
  - Params serialization produces correct JSON-RPC param array
- **Implementation**: Modify `eth_getLogs.zig` to change `Params.filter` from `types.Quantity` to `types.Filter`. Update `jsonStringify` and `jsonParseFromValue` accordingly.

### Step 4: Update `eth_getLogs.zig` Result type
- **Test First**: Update existing tests (if any) or create new tests in `eth_getLogs_test.zig` to verify:
  - Result correctly serializes an array of `LogEntry` objects
  - Empty result (no logs) serializes as empty array `[]`
  - Result parsing from JSON works correctly
- **Implementation**: Modify `eth_getLogs.zig` to change `Result.value` from `types.Quantity` to `[]const types.LogEntry`. Update `jsonStringify` and `jsonParseFromValue` accordingly.

## Files to Create and Modify

**Create:**
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/Filter_test.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/Filter.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/LogEntry_test.zig`
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types/LogEntry.zig`

**Modify:**
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/types.zig` (Export the new types `Filter` and `LogEntry`)
- `/Users/williamcory/voltaire/packages/voltaire-zig/src/jsonrpc/eth/getLogs/eth_getLogs.zig` (Update Params and Result types)

## Type Signatures

### Filter.zig
```zig
pub const Filter = struct {
    fromBlock: ?types.Quantity = null,
    toBlock: ?types.Quantity = null,
    blockHash: ?types.Hash = null,
    address: ?FilterAddress = null,
    topics: ?FilterTopics = null,

    pub const FilterAddress = union(enum) {
        single: types.Address,
        array: []const types.Address,
    };

    pub const FilterTopics = []const ?FilterTopic;
    pub const FilterTopic = union(enum) {
        single: types.Hash,      // bytes32
        array: []const types.Hash,
    };

    pub fn jsonStringify(self: Filter, jws: *std.json.Stringify) !void;
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Filter;
};
```

### LogEntry.zig
```zig
pub const LogEntry = struct {
    removed: bool = false,
    logIndex: ?types.Quantity = null,
    transactionIndex: ?types.Quantity = null,
    transactionHash: types.Hash,
    blockHash: ?types.Hash = null,
    blockNumber: ?types.Quantity = null,
    blockTimestamp: ?types.Quantity = null,
    address: types.Address,
    data: types.Quantity,  // Using Quantity as pass-through for bytes
    topics: []const types.Hash,

    pub fn jsonStringify(self: LogEntry, jws: *std.json.Stringify) !void;
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !LogEntry;
};
```

### eth_getLogs.zig (updated)
```zig
pub const Params = struct {
    filter: types.Filter,

    pub fn jsonStringify(self: Params, jws: *std.json.Stringify) !void;
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Params;
};

pub const Result = struct {
    logs: []const types.LogEntry,

    pub fn jsonStringify(self: Result, jws: *std.json.Stringify) !void;
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Result;
};
```

## Tests to Write

### Unit Tests (`*_test.zig`)

**Filter_test.zig:**
- `test "parse block range filter"` - Parse filter with fromBlock/toBlock
- `test "parse block hash filter"` - Parse filter with blockHash
- `test "parse filter with single address"` - Address as single hex string
- `test "parse filter with address array"` - Address as array of hex strings
- `test "parse filter with topics"` - Topics as array of bytes32 or array of arrays
- `test "serialize block range filter"` - Verify correct JSON output
- `test "serialize block hash filter"` - Verify blockHash field is present
- `test "serialize filter with null fields"` - Optional fields omitted

**LogEntry_test.zig:**
- `test "serialize complete log entry"` - All fields present
- `test "serialize log entry with null block fields"` - Pending log (no block info)
- `test "parse log entry from JSON"` - Roundtrip test
- `test "serialize log with multiple topics"` - Topics array handling
- `test "serialize removed log"` - removed = true (chain reorg)

**eth_getLogs_test.zig:**
- `test "parse params with filter"` - Params parsing
- `test "serialize result with logs"` - Result serialization
- `test "serialize empty result"` - Empty logs array

### Integration Tests (using execution-apis test vectors)

From `execution-apis/tests/eth_getLogs/`:
- `contract-addr.io` - Filter by contract address
- `topic-exact-match.io` - Filter by exact topic match
- `topic-wildcard.io` - Filter with topic wildcards
- `no-topics.io` - Filter without topics

These vectors validate the Filter input shapes and expected log outputs.

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| **Complex union types for address/topics** - Filter.address and FilterTopic can be single value or array | Use Zig tagged unions (`union(enum)`) with custom `jsonStringify`/`jsonParseFromValue` to handle the polymorphic JSON shapes |
| **Optional fields in Filter** - Filter has mutually exclusive patterns (blockHash vs fromBlock/toBlock) | All fields optional in struct; no runtime validation needed for parsing - higher layers handle validation |
| **Array allocation in parsing** - topics and address arrays need allocator | Accept `std.mem.Allocator` in `jsonParseFromValue` and document ownership semantics (caller owns returned slices) |
| **Hex encoding consistency** - Must match Ethereum hex format (0x prefix, lowercase) | Reuse existing `types.Address` and `types.Hash` stringification logic which already handles this |
| **BlockTimestamp field** - execution-apis includes blockTimestamp but EIP-1474 examples don't always show it | Include blockTimestamp as optional field in LogEntry for forward compatibility with newer clients |

## Acceptance Criteria Verification

After implementation, verify:

1. **Type existence**: `types.Filter` and `types.LogEntry` are exported from `types.zig`
2. **eth_getLogs params**: `eth_getLogs.Params.filter` is of type `types.Filter`
3. **eth_getLogs result**: `eth_getLogs.Result` contains `[]const types.LogEntry`
4. **JSON serialization**: Run unit tests with `zig build test` - all tests pass
5. **Spec compliance**: Test vectors from `execution-apis/tests/eth_getLogs/` can be parsed/serialized correctly
6. **Field coverage**: 
   - Filter has: `fromBlock`, `toBlock`, `blockHash`, `address`, `topics`
   - LogEntry has: `address`, `topics`, `data`, `blockNumber`, `transactionHash`, `transactionIndex`, `blockHash`, `logIndex`, `removed` (plus `blockTimestamp` for completeness)
