const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const dispatcher = @import("dispatcher.zig");
const dispatch_wiring = @import("dispatch_wiring.zig");
const genesis_mod = @import("../genesis.zig");
const light_proof = @import("../light_proof.zig");
const mining = @import("../mining.zig");
const runtime_mod = @import("../node/runtime.zig");

fn makeRequest(method: []const u8, params: ?std.json.Value) !jsonrpc.envelope.RequestEnvelope {
    return .{
        .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
        .id = .{ .integer = 1 },
        .method = try std.testing.allocator.dupe(u8, method),
        .params = params,
    };
}

fn dispatchQuantityRequest(
    handlers: *const dispatcher.HandlerRegistry,
    method: []const u8,
    quantity: []const u8,
) !jsonrpc.envelope.ResponseEnvelope {
    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(.{ .string = quantity });

    var request = try makeRequest(method, .{ .array = params });
    defer request.deinit(std.testing.allocator);

    return dispatcher.dispatch(std.testing.allocator, request, handlers);
}

fn getObjectField(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.MissingField,
        else => error.ExpectedObject,
    };
}

fn expectBoolRpc(
    handlers: *const dispatcher.HandlerRegistry,
    method: []const u8,
    params: ?std.json.Value,
) !void {
    var request = try makeRequest(method, params);
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    try std.testing.expect(response.result != null);
    try std.testing.expect(response.result.?.bool);
}

fn expectInvalidParamsRpc(
    handlers: *const dispatcher.HandlerRegistry,
    method: []const u8,
    params: ?std.json.Value,
) !void {
    var request = try makeRequest(method, params);
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(@as(i32, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), response.error_value.?.code);
}

fn dispatchOneStringParam(
    handlers: *const dispatcher.HandlerRegistry,
    method: []const u8,
    value: []const u8,
) !jsonrpc.envelope.ResponseEnvelope {
    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(.{ .string = value });

    var request = try makeRequest(method, .{ .array = params });
    defer request.deinit(std.testing.allocator);

    return dispatcher.dispatch(std.testing.allocator, request, handlers);
}

fn rpcBlockNumber(handlers: *const dispatcher.HandlerRegistry) !u64 {
    var request = try makeRequest("eth_blockNumber", null);
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    const quantity = response.result.?.string;
    if (!std.mem.startsWith(u8, quantity, "0x")) return error.InvalidQuantity;
    if (quantity.len == 2) return error.InvalidQuantity;
    return std.fmt.parseInt(u64, quantity[2..], 16);
}

fn waitForRpcBlockNumberAtLeast(handlers: *const dispatcher.HandlerRegistry, target: u64) !void {
    const deadline = std.time.nanoTimestamp() + 4 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        if ((try rpcBlockNumber(handlers)) >= target) return;
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    return error.TimeoutWaitingForIntervalMining;
}

fn addPooledTransaction(rt: *runtime_mod.NodeRuntime, sender: primitives.Address, hash: [32]u8) !void {
    try rt.pool.setNonce(sender, 0);
    try rt.pool.add(std.testing.allocator, .{
        .sender = sender,
        .nonce = 0,
        .gas_limit = 21_000,
        .max_fee_per_gas = runtime_mod.DEFAULT_GAS_PRICE,
        .hash = hash,
    });
}

const ContractMethodInventory = std.StringHashMap(void);
const contract_method_prefixes = [_][]const u8{
    "debug_",
    "engine_",
    "eth_",
    "web3_",
    "net_",
    "txpool_",
    "zevm_",
    "anvil_",
    "hardhat_",
    "evm_",
};

fn collectContractMethodInventory(allocator: std.mem.Allocator, methods: *ContractMethodInventory) !void {
    const docs = try std.fs.cwd().readFileAlloc(allocator, "docs/specs/json-rpc-contract.md", 2 * 1024 * 1024);

    try collectMethodsFromSection(methods, docs, "## 8. Trusted-Mode Standard Methods", "## 12. Deferred Trusted Helpers");
    try collectMethodsFromSection(methods, docs, "## 13. Light-Mode Methods", "## 14. Unsupported Public Surface");
}

fn collectSourceMethodInventory(allocator: std.mem.Allocator, methods: *ContractMethodInventory) !void {
    const dispatcher_source = try std.fs.cwd().readFileAlloc(allocator, "src/rpc/dispatcher.zig", 512 * 1024);
    const wiring_source = try std.fs.cwd().readFileAlloc(allocator, "src/rpc/dispatch_wiring.zig", 1024 * 1024);

    try collectQuotedMethodTokens(methods, dispatcher_source);
    try collectQuotedMethodTokens(methods, wiring_source);
}

fn collectMethodsFromSection(
    methods: *ContractMethodInventory,
    docs: []const u8,
    start_marker: []const u8,
    end_marker: []const u8,
) !void {
    const start = std.mem.indexOf(u8, docs, start_marker) orelse return error.ContractSectionMissing;
    const end = std.mem.indexOfPos(u8, docs, start + start_marker.len, end_marker) orelse return error.ContractSectionMissing;
    try collectMethodTokens(methods, docs[start..end]);
}

fn collectQuotedMethodTokens(methods: *ContractMethodInventory, source: []const u8) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, cursor, '"')) |start| {
        const end = std.mem.indexOfScalarPos(u8, source, start + 1, '"') orelse return error.MalformedStringLiteral;
        const text = source[start + 1 .. end];
        if (isConcreteMethodName(text) and !methods.contains(text)) try methods.put(text, {});
        cursor = end + 1;
    }
}

fn isConcreteMethodName(text: []const u8) bool {
    const prefix = methodPrefixAt(text) orelse return false;
    if (text.len <= prefix.len) return false;
    for (text) |char| {
        if (!isMethodNameChar(char)) return false;
    }
    return true;
}

fn collectMethodTokens(methods: *ContractMethodInventory, text: []const u8) !void {
    var index: usize = 0;
    while (index < text.len) {
        if (index != 0 and isMethodNameChar(text[index - 1])) {
            index += 1;
            continue;
        }

        const prefix = methodPrefixAt(text[index..]) orelse {
            index += 1;
            continue;
        };
        var end = index + prefix.len;
        while (end < text.len and isMethodNameChar(text[end])) : (end += 1) {}

        if (end > index + prefix.len) {
            const method = text[index..end];
            if (!methods.contains(method)) try methods.put(method, {});
        }
        index = end;
    }
}

fn methodPrefixAt(text: []const u8) ?[]const u8 {
    for (contract_method_prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return prefix;
    }
    return null;
}

fn isMethodNameChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_';
}

fn expectInventoriesEqual(contract_methods: *ContractMethodInventory, source_methods: *ContractMethodInventory) !void {
    var missing_from_source: usize = 0;
    var contract_it = contract_methods.keyIterator();
    while (contract_it.next()) |method| {
        if (!source_methods.contains(method.*)) {
            std.debug.print("documented JSON-RPC method is not routed: {s}\n", .{method.*});
            missing_from_source += 1;
        }
    }

    var missing_from_contract: usize = 0;
    var source_it = source_methods.keyIterator();
    while (source_it.next()) |method| {
        if (!contract_methods.contains(method.*)) {
            std.debug.print("routed JSON-RPC method is not documented in the phase-1 contract: {s}\n", .{method.*});
            missing_from_contract += 1;
        }
    }

    if (missing_from_source != 0 or missing_from_contract != 0) return error.JsonRpcContractInventoryMismatch;
}

fn expectContractMethodRouted(mode: enum { trusted, light }, method: []const u8) !void {
    var params_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer params_arena.deinit();

    var rt = switch (mode) {
        .trusted => try runtime_mod.NodeRuntime.init(std.testing.allocator, null),
        .light => try initLightRuntime(null),
    };
    defer rt.deinit();

    const params = try contractProbeParams(params_arena.allocator(), method);
    var response = try dispatchForTest(&rt, method, params);
    defer response.deinit(std.testing.allocator);

    if (response.error_value) |err| {
        if (err.code == jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND) {
            std.debug.print("documented JSON-RPC method fell through in {s} mode: {s}\n", .{ @tagName(mode), method });
            return error.DocumentedMethodNotRouted;
        }
    }
}

fn contractProbeParams(allocator: std.mem.Allocator, method: []const u8) !?std.json.Value {
    if (methodIs(method, &.{
        "eth_chainId",
        "eth_blockNumber",
        "eth_gasPrice",
        "eth_maxPriorityFeePerGas",
        "eth_blobBaseFee",
        "eth_coinbase",
        "eth_accounts",
        "eth_mining",
        "eth_syncing",
        "eth_protocolVersion",
        "eth_newBlockFilter",
        "eth_newPendingTransactionFilter",
        "debug_getBadBlocks",
        "web3_clientVersion",
        "net_version",
        "net_listening",
        "net_peerCount",
        "txpool_content",
        "txpool_status",
        "txpool_inspect",
        "zevm_dumpState",
        "anvil_dumpState",
        "zevm_getAutomine",
        "anvil_getAutomine",
        "hardhat_getAutomine",
        "zevm_getIntervalMining",
        "anvil_getIntervalMining",
        "zevm_mine",
        "anvil_mine",
        "hardhat_mine",
        "evm_mine",
        "zevm_mineDetailed",
        "anvil_mineDetailed",
        "zevm_dropAllTransactions",
        "anvil_dropAllTransactions",
        "zevm_snapshot",
        "anvil_snapshot",
        "evm_snapshot",
        "zevm_removeBlockTimestampInterval",
        "anvil_removeBlockTimestampInterval",
        "zevm_reset",
        "anvil_reset",
        "hardhat_reset",
        "zevm_metadata",
        "anvil_metadata",
        "hardhat_metadata",
        "zevm_nodeInfo",
        "anvil_nodeInfo",
        "zevm_lightSyncStatus",
    })) return null;

    if (methodIs(method, &.{ "debug_getRawBlock", "debug_getRawHeader", "debug_getRawReceipts" })) {
        return try arrayParams(allocator, &.{.{ .string = "0x0" }});
    }
    if (std.mem.eql(u8, method, "debug_getRawTransaction")) {
        return try arrayParams(allocator, &.{hash32Value()});
    }
    if (std.mem.eql(u8, method, "engine_exchangeCapabilities")) {
        return try arrayParams(allocator, &.{.{ .array = std.json.Array.init(allocator) }});
    }
    if (std.mem.eql(u8, method, "engine_exchangeTransitionConfigurationV1")) {
        return try arrayParams(allocator, &.{try emptyObjectValue(allocator)});
    }
    if (std.mem.eql(u8, method, "engine_getClientVersionV1")) {
        var client = std.json.ObjectMap.init(allocator);
        try client.put("code", .{ .string = "CL" });
        try client.put("name", .{ .string = "probe" });
        try client.put("version", .{ .string = "v0.0.0" });
        try client.put("commit", .{ .string = "0x00000000" });
        return try arrayParams(allocator, &.{.{ .object = client }});
    }
    if (methodIs(method, &.{ "engine_forkchoiceUpdatedV1", "engine_forkchoiceUpdatedV2", "engine_forkchoiceUpdatedV3", "engine_forkchoiceUpdatedV4" })) {
        var state = std.json.ObjectMap.init(allocator);
        try state.put("headBlockHash", hash32Value());
        try state.put("safeBlockHash", hash32Value());
        try state.put("finalizedBlockHash", hash32Value());
        return try arrayParams(allocator, &.{.{ .object = state }});
    }
    if (methodIs(method, &.{ "engine_newPayloadV1", "engine_newPayloadV2" })) {
        return try arrayParams(allocator, &.{try emptyObjectValue(allocator)});
    }
    if (std.mem.eql(u8, method, "engine_newPayloadV3")) {
        return try arrayParams(allocator, &.{ try emptyObjectValue(allocator), .{ .array = std.json.Array.init(allocator) }, hash32Value() });
    }
    if (methodIs(method, &.{ "engine_newPayloadV4", "engine_newPayloadV5" })) {
        return try arrayParams(allocator, &.{ try emptyObjectValue(allocator), .{ .array = std.json.Array.init(allocator) }, hash32Value(), .{ .array = std.json.Array.init(allocator) } });
    }
    if (methodIs(method, &.{ "engine_getPayloadV1", "engine_getPayloadV2", "engine_getPayloadV3", "engine_getPayloadV4", "engine_getPayloadV5", "engine_getPayloadV6" })) {
        return try arrayParams(allocator, &.{.{ .string = "0x0000000000000001" }});
    }
    if (methodIs(method, &.{
        "engine_getPayloadBodiesByHashV1",
        "engine_getPayloadBodiesByHashV2",
        "engine_getBlobsV1",
        "engine_getBlobsV2",
        "engine_getBlobsV3",
    })) {
        var hashes = std.json.Array.init(allocator);
        try hashes.append(hash32Value());
        return try arrayParams(allocator, &.{.{ .array = hashes }});
    }
    if (methodIs(method, &.{ "engine_getPayloadBodiesByRangeV1", "engine_getPayloadBodiesByRangeV2" })) {
        return try arrayParams(allocator, &.{ .{ .string = "0x0" }, .{ .string = "0x1" } });
    }
    if (methodIs(method, &.{ "eth_getBalance", "eth_getCode", "eth_getTransactionCount" })) {
        return try arrayParams(allocator, &.{ addressValue(), .{ .string = "latest" } });
    }
    if (std.mem.eql(u8, method, "eth_getStorageAt")) {
        return try arrayParams(allocator, &.{ addressValue(), bytes32Value(), .{ .string = "latest" } });
    }
    if (std.mem.eql(u8, method, "eth_getStorageValues")) {
        var storage_request = std.json.ObjectMap.init(allocator);
        var slots = std.json.Array.init(allocator);
        try slots.append(bytes32Value());
        try storage_request.put(managedAddressText(), .{ .array = slots });
        return try arrayParams(allocator, &.{ .{ .object = storage_request }, .{ .string = "latest" } });
    }
    if (std.mem.eql(u8, method, "eth_getProof")) {
        var slots = std.json.Array.init(allocator);
        try slots.append(bytes32Value());
        return try arrayParams(allocator, &.{ addressValue(), .{ .array = slots }, .{ .string = "latest" } });
    }
    if (std.mem.eql(u8, method, "eth_feeHistory")) {
        return try arrayParams(allocator, &.{ .{ .string = "0x1" }, .{ .string = "latest" } });
    }
    if (std.mem.eql(u8, method, "web3_sha3")) {
        return try arrayParams(allocator, &.{.{ .string = "0x" }});
    }
    if (std.mem.eql(u8, method, "eth_call")) {
        return try arrayParams(allocator, &.{ try transactionRequestValue(allocator), .{ .string = "latest" } });
    }
    if (std.mem.eql(u8, method, "eth_estimateGas")) {
        return try arrayParams(allocator, &.{try transactionRequestValue(allocator)});
    }
    if (std.mem.eql(u8, method, "eth_createAccessList")) {
        return try arrayParams(allocator, &.{ try transactionRequestValue(allocator), .{ .string = "latest" } });
    }
    if (std.mem.eql(u8, method, "eth_simulateV1")) {
        var payload = std.json.ObjectMap.init(allocator);
        var blocks = std.json.Array.init(allocator);
        try blocks.append(try emptyObjectValue(allocator));
        try payload.put("blockStateCalls", .{ .array = blocks });
        return try arrayParams(allocator, &.{.{ .object = payload }});
    }
    if (std.mem.eql(u8, method, "testing_buildBlockV1")) {
        var attrs = std.json.ObjectMap.init(allocator);
        try attrs.put("parentBeaconBlockRoot", bytes32Value());
        try attrs.put("prevRandao", bytes32Value());
        try attrs.put("suggestedFeeRecipient", addressValue());
        try attrs.put("timestamp", .{ .string = "0x1" });
        try attrs.put("withdrawals", .{ .array = std.json.Array.init(allocator) });
        return try arrayParams(allocator, &.{ hash32Value(), .{ .object = attrs }, .{ .array = std.json.Array.init(allocator) }, .{ .string = "0x" } });
    }
    if (std.mem.eql(u8, method, "eth_sendTransaction")) {
        return try arrayParams(allocator, &.{try transactionRequestValue(allocator)});
    }
    if (std.mem.eql(u8, method, "eth_sendRawTransaction")) {
        return try arrayParams(allocator, &.{.{ .string = "0x" }});
    }
    if (std.mem.eql(u8, method, "eth_sign")) {
        return try arrayParams(allocator, &.{ .{ .string = managedAddressText() }, .{ .string = "0x" } });
    }
    if (std.mem.eql(u8, method, "eth_signTransaction")) {
        return try arrayParams(allocator, &.{try transactionRequestValue(allocator)});
    }
    if (std.mem.eql(u8, method, "eth_newFilter")) {
        return try arrayParams(allocator, &.{try emptyObjectValue(allocator)});
    }
    if (methodIs(method, &.{ "eth_getFilterChanges", "eth_getFilterLogs", "eth_uninstallFilter" })) {
        return try arrayParams(allocator, &.{.{ .string = "0x1" }});
    }
    if (std.mem.eql(u8, method, "eth_getBlockByNumber")) {
        return try arrayParams(allocator, &.{ .{ .string = "latest" }, .{ .bool = false } });
    }
    if (std.mem.eql(u8, method, "eth_getBlockByHash")) {
        return try arrayParams(allocator, &.{ hash32Value(), .{ .bool = false } });
    }
    if (methodIs(method, &.{ "eth_getBlockTransactionCountByHash", "eth_getUncleCountByBlockHash", "eth_getTransactionByHash", "eth_getTransactionReceipt" })) {
        return try arrayParams(allocator, &.{hash32Value()});
    }
    if (methodIs(method, &.{ "eth_getBlockTransactionCountByNumber", "eth_getUncleCountByBlockNumber" })) {
        return try arrayParams(allocator, &.{.{ .string = "latest" }});
    }
    if (std.mem.eql(u8, method, "eth_getTransactionByBlockHashAndIndex")) {
        return try arrayParams(allocator, &.{ hash32Value(), .{ .string = "0x0" } });
    }
    if (std.mem.eql(u8, method, "eth_getTransactionByBlockNumberAndIndex")) {
        return try arrayParams(allocator, &.{ .{ .string = "latest" }, .{ .string = "0x0" } });
    }
    if (std.mem.eql(u8, method, "eth_getBlockReceipts")) {
        return try arrayParams(allocator, &.{.{ .string = "latest" }});
    }
    if (std.mem.eql(u8, method, "eth_getBlockAccessList")) {
        return try arrayParams(allocator, &.{.{ .string = "latest" }});
    }
    if (std.mem.eql(u8, method, "eth_getLogs")) {
        return try arrayParams(allocator, &.{try emptyObjectValue(allocator)});
    }
    if (std.mem.eql(u8, method, "txpool_contentFrom")) {
        return try arrayParams(allocator, &.{addressValue()});
    }
    if (std.mem.eql(u8, method, "zevm_getAccount")) {
        return try arrayParams(allocator, &.{addressValue()});
    }
    if (std.mem.eql(u8, method, "zevm_setAccount")) {
        return try arrayParams(allocator, &.{ addressValue(), try accountStateValueForProbe(allocator) });
    }
    if (methodIs(method, &.{ "zevm_loadState", "anvil_loadState" })) {
        return try arrayParams(allocator, &.{.{ .string = "0x7b2276657273696f6e223a312c226163636f756e7473223a7b7d7d" }});
    }
    if (methodIs(method, &.{
        "zevm_setBalance",
        "anvil_setBalance",
        "hardhat_setBalance",
        "zevm_deal",
        "anvil_deal",
        "zevm_addBalance",
        "anvil_addBalance",
        "zevm_setNonce",
        "anvil_setNonce",
        "hardhat_setNonce",
    })) {
        return try arrayParams(allocator, &.{ addressValue(), .{ .string = "0x1" } });
    }
    if (methodIs(method, &.{ "zevm_setCode", "anvil_setCode", "hardhat_setCode" })) {
        return try arrayParams(allocator, &.{ addressValue(), .{ .string = "0x" } });
    }
    if (methodIs(method, &.{ "zevm_setStorageAt", "anvil_setStorageAt", "hardhat_setStorageAt" })) {
        return try arrayParams(allocator, &.{ addressValue(), bytes32Value(), bytes32Value() });
    }
    if (methodIs(method, &.{ "zevm_dealErc20", "anvil_dealErc20" })) {
        return try arrayParams(allocator, &.{ tokenValue(), addressValue(), .{ .string = "0x1" } });
    }
    if (methodIs(method, &.{ "zevm_setErc20Allowance", "anvil_setErc20Allowance" })) {
        return try arrayParams(allocator, &.{ tokenValue(), addressValue(), spenderValue(), .{ .string = "0x1" } });
    }
    if (methodIs(method, &.{
        "zevm_setCoinbase",
        "anvil_setCoinbase",
        "hardhat_setCoinbase",
        "zevm_impersonateAccount",
        "anvil_impersonateAccount",
        "hardhat_impersonateAccount",
        "zevm_stopImpersonatingAccount",
        "anvil_stopImpersonatingAccount",
        "hardhat_stopImpersonatingAccount",
    })) {
        return try arrayParams(allocator, &.{addressValue()});
    }
    if (methodIs(method, &.{
        "zevm_setChainId",
        "anvil_setChainId",
        "zevm_setBlockGasLimit",
        "anvil_setBlockGasLimit",
        "evm_setBlockGasLimit",
        "zevm_setNextBlockBaseFeePerGas",
        "anvil_setNextBlockBaseFeePerGas",
        "hardhat_setNextBlockBaseFeePerGas",
        "zevm_setMinGasPrice",
        "anvil_setMinGasPrice",
        "hardhat_setMinGasPrice",
        "zevm_increaseTime",
        "anvil_increaseTime",
        "evm_increaseTime",
        "zevm_setTime",
        "anvil_setTime",
        "zevm_setNextBlockTimestamp",
        "anvil_setNextBlockTimestamp",
        "evm_setNextBlockTimestamp",
        "zevm_setBlockTimestampInterval",
        "anvil_setBlockTimestampInterval",
        "zevm_setIntervalMining",
        "anvil_setIntervalMining",
        "evm_setIntervalMining",
        "zevm_revert",
        "anvil_revert",
        "evm_revert",
    })) {
        return try arrayParams(allocator, &.{.{ .string = "0x1" }});
    }
    if (methodIs(method, &.{
        "zevm_setAutomine",
        "anvil_setAutomine",
        "evm_setAutomine",
        "zevm_autoImpersonateAccount",
        "anvil_autoImpersonateAccount",
    })) {
        return try arrayParams(allocator, &.{.{ .bool = true }});
    }
    if (methodIs(method, &.{ "zevm_setRpcUrl", "anvil_setRpcUrl" })) {
        return try arrayParams(allocator, &.{.{ .string = "https://example.invalid" }});
    }
    if (methodIs(method, &.{ "zevm_dropTransaction", "anvil_dropTransaction", "hardhat_dropTransaction" })) {
        return try arrayParams(allocator, &.{hash32Value()});
    }
    if (methodIs(method, &.{ "zevm_removePoolTransactions", "anvil_removePoolTransactions" })) {
        var hashes = std.json.Array.init(allocator);
        try hashes.append(hash32Value());
        return try arrayParams(allocator, &.{.{ .array = hashes }});
    }

    std.debug.print("missing JSON-RPC contract probe params for method: {s}\n", .{method});
    return error.MissingContractProbeParams;
}

fn arrayParams(allocator: std.mem.Allocator, values: []const std.json.Value) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(value);
    return .{ .array = array };
}

fn emptyObjectValue(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .object = std.json.ObjectMap.init(allocator) };
}

fn transactionRequestValue(allocator: std.mem.Allocator) !std.json.Value {
    var object = std.json.ObjectMap.init(allocator);
    try object.put("from", .{ .string = managedAddressText() });
    try object.put("to", addressValue());
    try object.put("gas", .{ .string = "0x5208" });
    try object.put("gasPrice", .{ .string = "0x3b9aca00" });
    try object.put("value", .{ .string = "0x0" });
    try object.put("data", .{ .string = "0x" });
    return .{ .object = object };
}

fn accountStateValueForProbe(allocator: std.mem.Allocator) !std.json.Value {
    var object = std.json.ObjectMap.init(allocator);
    try object.put("balance", .{ .string = "0x1" });
    try object.put("nonce", .{ .string = "0x0" });
    try object.put("code", .{ .string = "0x" });
    try object.put("storage", try emptyObjectValue(allocator));
    return .{ .object = object };
}

fn addressValue() std.json.Value {
    return .{ .string = "0x0000000000000000000000000000000000000042" };
}

fn tokenValue() std.json.Value {
    return .{ .string = "0x0000000000000000000000000000000000001000" };
}

fn spenderValue() std.json.Value {
    return .{ .string = "0x0000000000000000000000000000000000001001" };
}

fn managedAddressText() []const u8 {
    return "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";
}

fn hash32Value() std.json.Value {
    return .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000000" };
}

fn hashText(allocator: std.mem.Allocator, hash: [32]u8) ![]u8 {
    const hex = std.fmt.bytesToHex(hash, .lower);
    return std.fmt.allocPrint(allocator, "0x{s}", .{&hex});
}

fn bytes32Value() std.json.Value {
    return .{ .string = "0x0000000000000000000000000000000000000000000000000000000000000000" };
}

fn methodIs(method_name: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |name| {
        if (std.mem.eql(u8, method_name, name)) return true;
    }
    return false;
}

test "canonical JSON-RPC method inventory matches dispatcher wiring" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var contract_methods = ContractMethodInventory.init(arena.allocator());
    var source_methods = ContractMethodInventory.init(arena.allocator());
    try collectContractMethodInventory(arena.allocator(), &contract_methods);
    try collectSourceMethodInventory(arena.allocator(), &source_methods);

    try expectInventoriesEqual(&contract_methods, &source_methods);
}

test "canonical JSON-RPC methods never fall through routing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var contract_methods = ContractMethodInventory.init(arena.allocator());
    try collectContractMethodInventory(arena.allocator(), &contract_methods);

    var it = contract_methods.keyIterator();
    while (it.next()) |method| {
        try expectContractMethodRouted(.trusted, method.*);
        try expectContractMethodRouted(.light, method.*);
    }
}

test "installed dispatch wiring reaches runtime-backed eth methods" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var request = try makeRequest("eth_chainId", null);
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    try std.testing.expect(response.result != null);
    try std.testing.expectEqualStrings("0x7a69", response.result.?.string);
}

test "installed dispatch wiring exposes trusted compatibility utility methods" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    {
        var response = try dispatchForTest(&rt, "web3_clientVersion", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("zevm/0.1.0", response.result.?.string);
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = "0x" });

        var response = try dispatchForTest(&rt, "web3_sha3", .{ .array = params });
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings(
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
            response.result.?.string,
        );
    }

    {
        var response = try dispatchForTest(&rt, "net_version", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("31337", response.result.?.string);
    }

    {
        var response = try dispatchForTest(&rt, "net_listening", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        try std.testing.expect(response.result.?.bool);
    }

    {
        var response = try dispatchForTest(&rt, "net_peerCount", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("0x0", response.result.?.string);
    }

    {
        var response = try dispatchForTest(&rt, "eth_mining", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        try std.testing.expect(response.result.?.bool);
    }

    {
        var response = try dispatchForTest(&rt, "eth_syncing", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        try std.testing.expect(!response.result.?.bool);
    }

    {
        var response = try dispatchForTest(&rt, "eth_protocolVersion", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("0x41", response.result.?.string);
    }
}

test "installed dispatch wiring keeps independent runtime contexts" {
    var rt_a = try runtime_mod.NodeRuntime.init(std.testing.allocator, .{ .chain_id = 1 });
    defer rt_a.deinit();
    var rt_b = try runtime_mod.NodeRuntime.init(std.testing.allocator, .{ .chain_id = 2 });
    defer rt_b.deinit();

    var handlers_a = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers_a, &rt_a);
    var handlers_b = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers_b, &rt_b);

    var request_a = try makeRequest("eth_chainId", null);
    defer request_a.deinit(std.testing.allocator);
    var response_a = try dispatcher.dispatch(std.testing.allocator, request_a, &handlers_a);
    defer response_a.deinit(std.testing.allocator);
    try std.testing.expect(response_a.error_value == null);
    try std.testing.expectEqualStrings("0x1", response_a.result.?.string);

    var request_b = try makeRequest("eth_chainId", null);
    defer request_b.deinit(std.testing.allocator);
    var response_b = try dispatcher.dispatch(std.testing.allocator, request_b, &handlers_b);
    defer response_b.deinit(std.testing.allocator);
    try std.testing.expect(response_b.error_value == null);
    try std.testing.expectEqualStrings("0x2", response_b.result.?.string);
}

test "installed dispatch wiring reaches runtime-backed eth_feeHistory" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.mineBlocks(2, 0);

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var reward_percentiles = std.json.Array.init(std.testing.allocator);
    defer reward_percentiles.deinit();
    try reward_percentiles.append(.{ .integer = 10 });
    try reward_percentiles.append(.{ .integer = 50 });

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(.{ .string = "0x1" });
    try params.append(.{ .string = "latest" });
    try params.append(.{ .array = reward_percentiles });

    var request = try makeRequest("eth_feeHistory", .{ .array = params });
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    const result = response.result orelse return error.ExpectedResult;
    try std.testing.expectEqualStrings("0x2", (try getObjectField(result, "oldestBlock")).string);
    try std.testing.expectEqual(@as(usize, 2), (try getObjectField(result, "baseFeePerGas")).array.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try getObjectField(result, "gasUsedRatio")).array.items.len);
    try std.testing.expectEqual(@as(usize, 2), (try getObjectField(result, "baseFeePerBlobGas")).array.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try getObjectField(result, "blobGasUsedRatio")).array.items.len);

    const reward = (try getObjectField(result, "reward")).array.items;
    try std.testing.expectEqual(@as(usize, 1), reward.len);
    try std.testing.expectEqual(@as(usize, 2), reward[0].array.items.len);
}

test "installed dispatch wiring rejects params for no-param trusted methods" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const methods = [_][]const u8{
        "eth_chainId",
        "eth_blockNumber",
        "eth_gasPrice",
        "eth_maxPriorityFeePerGas",
        "eth_blobBaseFee",
        "eth_coinbase",
        "eth_accounts",
        "zevm_snapshot",
        "anvil_snapshot",
        "evm_snapshot",
    };

    for (&methods) |method| {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = "0x0" });
        try expectInvalidParamsRpc(&handlers, method, .{ .array = params });
    }
}

test "installed dispatch wiring routes uncle count methods" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = "latest" });

        var request = try makeRequest("eth_getUncleCountByBlockNumber", .{ .array = params });
        defer request.deinit(std.testing.allocator);
        var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("0x0", response.result.?.string);
    }

    {
        const genesis = (try rt.blockchain.getBlockByNumber(0)).?;
        const hash_hex = std.fmt.bytesToHex(genesis.hash, .lower);
        const hash_param = try std.fmt.allocPrint(std.testing.allocator, "0x{s}", .{hash_hex[0..]});
        defer std.testing.allocator.free(hash_param);

        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = hash_param });

        var request = try makeRequest("eth_getUncleCountByBlockHash", .{ .array = params });
        defer request.deinit(std.testing.allocator);
        var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("0x0", response.result.?.string);
    }
}

test "installed dispatch wiring reads managed accounts from runtime" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    rt.managed_accounts[0] = genesis_mod.DEV_ACCOUNTS[1];

    {
        var response = try dispatchForTest(&rt, "eth_accounts", null);
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value == null);
        const accounts = response.result.?.array.items;
        try std.testing.expectEqual(@as(usize, 10), accounts.len);
        try std.testing.expectEqualStrings("0x70997970c51812dc3a010c7d01b50e0d17dc79c8", accounts[0].string);
    }

    {
        var response = try dispatchForTest(&rt, "zevm_nodeInfo", null);
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value == null);
        const object = response.result.?.object;
        const accounts = (try objectField(&object, "managedAccounts")).array.items;
        try std.testing.expectEqualStrings("0x70997970c51812dc3a010c7d01b50e0d17dc79c8", accounts[0].string);
    }
}

test "installed dispatch wiring returns eth_getStorageAt as 32-byte data" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const address_text = "0x0000000000000000000000000000000000000042";
    const address = try primitives.Address.fromHex(address_text);
    try rt.setStorage(address, 1, 42);

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(.{ .string = address_text });
    try params.append(.{ .string = "0x1" });
    try params.append(.{ .string = "latest" });

    var request = try makeRequest("eth_getStorageAt", .{ .array = params });
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    try std.testing.expect(response.result != null);
    try std.testing.expectEqualStrings(
        "0x000000000000000000000000000000000000000000000000000000000000002a",
        response.result.?.string,
    );
}

test "installed dispatch wiring accepts 32-byte eth_getStorageAt slot" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(.{ .string = "0xc1cadaffffffffffffffffffffffffffffffffff" });
    try params.append(.{ .string = "0x0100000000000000000000000000000000000000000000000000000000000000" });
    try params.append(.{ .string = "latest" });

    var request = try makeRequest("eth_getStorageAt", .{ .array = params });
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    try std.testing.expect(response.result != null);
    try std.testing.expectEqualStrings(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        response.result.?.string,
    );
}

test "installed dispatch wiring reaches hardhat state mutation aliases" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const address = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(.{ .string = address });
    try params.append(.{ .string = "0x2a" });

    var request = try makeRequest("hardhat_setBalance", .{ .array = params });
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    try std.testing.expect(response.result.?.bool);

    const balance = try rt.getBalance(runtime_mod.DEFAULT_DEV_ACCOUNTS[0]);
    try std.testing.expectEqual(@as(u256, 42), balance);
}

test "installed dispatch wiring handles full account get and set" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const address = "0x0000000000000000000000000000000000000042";
    const parsed_address = try parseTestAddress(address);
    const storage_key = "0x0000000000000000000000000000000000000000000000000000000000000001";
    const storage_value = "0x000000000000000000000000000000000000000000000000000000000000002a";

    var storage = std.json.ObjectMap.init(std.testing.allocator);
    defer storage.deinit();
    try storage.put(storage_key, .{ .string = storage_value });

    var account = std.json.ObjectMap.init(std.testing.allocator);
    defer account.deinit();
    try account.put("balance", .{ .string = "0x2a" });
    try account.put("nonce", .{ .string = "0x3" });
    try account.put("code", .{ .string = "0x6001" });
    try account.put("storage", .{ .object = storage });

    var set_params = std.json.Array.init(std.testing.allocator);
    defer set_params.deinit();
    try set_params.append(.{ .string = address });
    try set_params.append(.{ .object = account });

    try expectBoolRpc(&handlers, "zevm_setAccount", .{ .array = set_params });

    try std.testing.expectEqual(@as(u256, 42), try rt.getBalance(parsed_address));
    try std.testing.expectEqual(@as(u64, 3), try rt.getNonce(parsed_address));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0x01 }, try rt.getCode(parsed_address));
    try std.testing.expectEqual(@as(u256, 42), try rt.getStorage(parsed_address, 1));

    var get_params = std.json.Array.init(std.testing.allocator);
    defer get_params.deinit();
    try get_params.append(.{ .string = address });
    try get_params.append(.{ .string = "latest" });

    var get_request = try makeRequest("zevm_getAccount", .{ .array = get_params });
    defer get_request.deinit(std.testing.allocator);
    var get_response = try dispatcher.dispatch(std.testing.allocator, get_request, &handlers);
    defer get_response.deinit(std.testing.allocator);

    try std.testing.expect(get_response.error_value == null);
    const result = get_response.result.?;
    try std.testing.expectEqualStrings("0x2a", (try getObjectField(result, "balance")).string);
    try std.testing.expectEqualStrings("0x3", (try getObjectField(result, "nonce")).string);
    try std.testing.expectEqualStrings("0x6001", (try getObjectField(result, "code")).string);

    const storage_result = try getObjectField(result, "storage");
    try std.testing.expectEqualStrings(storage_value, (try getObjectField(storage_result, storage_key)).string);
}

test "installed dispatch wiring dumps and loads local state" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const address_text = "0x0000000000000000000000000000000000000042";
    const address = try parseTestAddress(address_text);
    try rt.setBalance(address, 42);
    try rt.setNonce(address, 3);
    try rt.setCode(address, &[_]u8{ 0x60, 0x01 });
    try rt.setStorage(address, 1, 42);

    var dump_request = try makeRequest("anvil_dumpState", null);
    defer dump_request.deinit(std.testing.allocator);
    var dump_response = try dispatcher.dispatch(std.testing.allocator, dump_request, &handlers);
    defer dump_response.deinit(std.testing.allocator);
    try std.testing.expect(dump_response.error_value == null);
    const dump_blob = dump_response.result.?.string;

    try rt.setBalance(address, 999);
    try rt.setNonce(address, 9);
    try rt.setCode(address, &[_]u8{0x00});
    try rt.setStorage(address, 1, 7);

    var load_params = std.json.Array.init(std.testing.allocator);
    defer load_params.deinit();
    try load_params.append(.{ .string = dump_blob });

    var load_request = try makeRequest("zevm_loadState", .{ .array = load_params });
    defer load_request.deinit(std.testing.allocator);
    var load_response = try dispatcher.dispatch(std.testing.allocator, load_request, &handlers);
    defer load_response.deinit(std.testing.allocator);
    try std.testing.expect(load_response.error_value == null);
    try std.testing.expect(load_response.result.?.bool);

    try std.testing.expectEqual(@as(u256, 42), try rt.getBalance(address));
    try std.testing.expectEqual(@as(u64, 3), try rt.getNonce(address));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0x01 }, try rt.getCode(address));
    try std.testing.expectEqual(@as(u256, 42), try rt.getStorage(address, 1));
}

test "installed dispatch wiring reaches impersonation aliases" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const address = "0x0000000000000000000000000000000000000042";
    const parsed = try primitives.Address.fromHex(address);

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = address });

        try expectBoolRpc(&handlers, "anvil_impersonateAccount", .{ .array = params });
        try std.testing.expect(rt.isImpersonatingAccount(parsed));
        try std.testing.expect(rt.canSignForAccount(parsed));
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = address });

        try expectBoolRpc(&handlers, "hardhat_stopImpersonatingAccount", .{ .array = params });
        try std.testing.expect(!rt.isImpersonatingAccount(parsed));
        try std.testing.expect(!rt.canSignForAccount(parsed));
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .bool = true });

        try expectBoolRpc(&handlers, "zevm_autoImpersonateAccount", .{ .array = params });
        try std.testing.expect(rt.canSignForAccount(parsed));
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .bool = false });

        try expectBoolRpc(&handlers, "anvil_autoImpersonateAccount", .{ .array = params });
        try std.testing.expect(!rt.canSignForAccount(parsed));
    }
}

test "installed dispatch wiring reaches time-control aliases" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var increase_response = try dispatchOneStringParam(&handlers, "evm_increaseTime", "0x2a");
    defer increase_response.deinit(std.testing.allocator);
    try std.testing.expect(increase_response.error_value == null);
    try std.testing.expectEqualStrings("0x2a", increase_response.result.?.string);
    try std.testing.expectEqual(@as(i128, 42), rt.time_offset);

    const target = rt.effectiveCurrentTime() + 600;
    const target_hex = try std.fmt.allocPrint(std.testing.allocator, "0x{x}", .{target});
    defer std.testing.allocator.free(target_hex);

    var set_time_response = try dispatchOneStringParam(&handlers, "zevm_setTime", target_hex);
    defer set_time_response.deinit(std.testing.allocator);
    try std.testing.expect(set_time_response.error_value == null);
    try std.testing.expectEqualStrings(target_hex, set_time_response.result.?.string);

    const anvil_target = target + 1;
    const anvil_target_hex = try std.fmt.allocPrint(std.testing.allocator, "0x{x}", .{anvil_target});
    defer std.testing.allocator.free(anvil_target_hex);

    var anvil_set_time_response = try dispatchOneStringParam(&handlers, "anvil_setTime", anvil_target_hex);
    defer anvil_set_time_response.deinit(std.testing.allocator);
    try std.testing.expect(anvil_set_time_response.error_value == null);
    try std.testing.expectEqualStrings(anvil_target_hex, anvil_set_time_response.result.?.string);

    var evm_next_response = try dispatchOneStringParam(&handlers, "evm_setNextBlockTimestamp", "0x3038");
    defer evm_next_response.deinit(std.testing.allocator);
    try std.testing.expect(evm_next_response.error_value == null);
    try std.testing.expect(evm_next_response.result.?.bool);
    try std.testing.expectEqual(@as(?u64, 12344), rt.next_block_timestamp);

    var anvil_next_response = try dispatchOneStringParam(&handlers, "anvil_setNextBlockTimestamp", "0x3039");
    defer anvil_next_response.deinit(std.testing.allocator);
    try std.testing.expect(anvil_next_response.error_value == null);
    try std.testing.expect(anvil_next_response.result.?.bool);
    try std.testing.expectEqual(@as(?u64, 12345), rt.next_block_timestamp);
}

test "installed dispatch wiring stores block environment override aliases" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var gas_response = try dispatchQuantityRequest(&handlers, "anvil_setBlockGasLimit", "0x5208");
    defer gas_response.deinit(std.testing.allocator);
    try std.testing.expect(gas_response.error_value == null);
    try std.testing.expect(gas_response.result.?.bool);
    try std.testing.expectEqual(@as(u64, 21_000), rt.dev_runtime.config.block_gas_limit);

    var base_fee_response = try dispatchQuantityRequest(&handlers, "hardhat_setNextBlockBaseFeePerGas", "0x2");
    defer base_fee_response.deinit(std.testing.allocator);
    try std.testing.expect(base_fee_response.error_value == null);
    try std.testing.expect(base_fee_response.result.?.bool);
    try std.testing.expectEqual(@as(u256, 2), rt.dev_runtime.config.next_block_base_fee_per_gas.?);

    var timestamp_response = try dispatchQuantityRequest(&handlers, "anvil_setNextBlockTimestamp", "0x4d2");
    defer timestamp_response.deinit(std.testing.allocator);
    try std.testing.expect(timestamp_response.error_value == null);
    try std.testing.expect(timestamp_response.result.?.bool);
    try std.testing.expectEqual(@as(u64, 1234), rt.dev_runtime.config.next_block_timestamp.?);

    var blob_read = try makeRequest("eth_blobBaseFee", null);
    defer blob_read.deinit(std.testing.allocator);
    var blob_read_response = try dispatcher.dispatch(std.testing.allocator, blob_read, &handlers);
    defer blob_read_response.deinit(std.testing.allocator);
    try std.testing.expect(blob_read_response.error_value == null);
    try std.testing.expectEqualStrings("0x1", blob_read_response.result.?.string);
}

test "undocumented compatibility aliases return method not found" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const methods = [_][]const u8{
        "hardhat_setBlockGasLimit",
        "zevm_setBlobBaseFee",
        "anvil_setBlobBaseFee",
        "hardhat_setBlobBaseFee",
        "zevm_setAutoImpersonateAccount",
        "anvil_setAutoImpersonateAccount",
        "hardhat_setAutoImpersonateAccount",
        "evm_setTime",
        "hardhat_setNextBlockTimestamp",
    };

    for (methods) |method| {
        try expectErrorCode(&rt, method, null, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND);
    }
}

test "installed dispatch wiring updates minimum gas price aliases" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var set_response = try dispatchQuantityRequest(&handlers, "hardhat_setMinGasPrice", "0x2a");
    defer set_response.deinit(std.testing.allocator);
    try std.testing.expect(set_response.error_value == null);
    try std.testing.expect(set_response.result.?.bool);
    try std.testing.expectEqual(@as(u256, 42), rt.gas_price);

    var read_request = try makeRequest("eth_gasPrice", null);
    defer read_request.deinit(std.testing.allocator);
    var read_response = try dispatcher.dispatch(std.testing.allocator, read_request, &handlers);
    defer read_response.deinit(std.testing.allocator);
    try std.testing.expect(read_response.error_value == null);
    try std.testing.expectEqualStrings("0x2a", read_response.result.?.string);
}

test "installed dispatch wiring removes txpool transactions" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const hash_a = [_]u8{0xaa} ** 32;
    const hash_b = [_]u8{0xbb} ** 32;
    const hash_c = [_]u8{0xcc} ** 32;
    const missing_hash = [_]u8{0xdd} ** 32;
    const hash_a_hex = try primitives.Hex.bytesToHex(std.testing.allocator, &hash_a);
    defer std.testing.allocator.free(hash_a_hex);
    const hash_b_hex = try primitives.Hex.bytesToHex(std.testing.allocator, &hash_b);
    defer std.testing.allocator.free(hash_b_hex);
    const hash_c_hex = try primitives.Hex.bytesToHex(std.testing.allocator, &hash_c);
    defer std.testing.allocator.free(hash_c_hex);
    const missing_hash_hex = try primitives.Hex.bytesToHex(std.testing.allocator, &missing_hash);
    defer std.testing.allocator.free(missing_hash_hex);

    try addPooledTransaction(&rt, runtime_mod.DEFAULT_DEV_ACCOUNTS[0], hash_a);
    try addPooledTransaction(&rt, runtime_mod.DEFAULT_DEV_ACCOUNTS[1], hash_b);
    try std.testing.expectEqual(@as(usize, 2), rt.pool.items().len);

    var drop_response = try dispatchOneStringParam(&handlers, "hardhat_dropTransaction", hash_a_hex);
    defer drop_response.deinit(std.testing.allocator);
    try std.testing.expect(drop_response.error_value == null);
    try std.testing.expect(drop_response.result.?.bool);
    try std.testing.expectEqual(@as(usize, 1), rt.pool.items().len);

    var missing_drop_response = try dispatchOneStringParam(&handlers, "zevm_dropTransaction", missing_hash_hex);
    defer missing_drop_response.deinit(std.testing.allocator);
    try std.testing.expect(missing_drop_response.error_value == null);
    try std.testing.expect(!missing_drop_response.result.?.bool);
    try std.testing.expectEqual(@as(usize, 1), rt.pool.items().len);

    try addPooledTransaction(&rt, runtime_mod.DEFAULT_DEV_ACCOUNTS[2], hash_c);

    var hashes = std.json.Array.init(std.testing.allocator);
    defer hashes.deinit();
    try hashes.append(.{ .string = hash_b_hex });
    try hashes.append(.{ .string = missing_hash_hex });
    try hashes.append(.{ .string = hash_c_hex });

    var remove_params = std.json.Array.init(std.testing.allocator);
    defer remove_params.deinit();
    try remove_params.append(.{ .array = hashes });

    var remove_request = try makeRequest("anvil_removePoolTransactions", .{ .array = remove_params });
    defer remove_request.deinit(std.testing.allocator);
    var remove_response = try dispatcher.dispatch(std.testing.allocator, remove_request, &handlers);
    defer remove_response.deinit(std.testing.allocator);
    try std.testing.expect(remove_response.error_value == null);
    try std.testing.expectEqualStrings("0x2", remove_response.result.?.string);
    try std.testing.expectEqual(@as(usize, 0), rt.pool.items().len);

    try addPooledTransaction(&rt, runtime_mod.DEFAULT_DEV_ACCOUNTS[0], hash_a);
    try addPooledTransaction(&rt, runtime_mod.DEFAULT_DEV_ACCOUNTS[1], hash_b);

    var drop_all_request = try makeRequest("anvil_dropAllTransactions", null);
    defer drop_all_request.deinit(std.testing.allocator);
    var drop_all_response = try dispatcher.dispatch(std.testing.allocator, drop_all_request, &handlers);
    defer drop_all_response.deinit(std.testing.allocator);
    try std.testing.expect(drop_all_response.error_value == null);
    try std.testing.expectEqualStrings("0x2", drop_all_response.result.?.string);
    try std.testing.expectEqual(@as(usize, 0), rt.pool.items().len);
}

test "installed dispatch wiring returns detailed mining summaries" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(.{ .string = "0x2" });
    try params.append(.{ .string = "0x3" });

    var request = try makeRequest("anvil_mineDetailed", .{ .array = params });
    defer request.deinit(std.testing.allocator);
    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    const result = response.result.?;
    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);
    try std.testing.expectEqual(@as(u64, 2), rt.head_block_number);

    const block_1 = (try rt.blockchain.getBlockByNumber(1)).?;
    const block_2 = (try rt.blockchain.getBlockByNumber(2)).?;
    const block_1_hash = try primitives.Hex.bytesToHex(std.testing.allocator, &block_1.hash);
    defer std.testing.allocator.free(block_1_hash);
    const block_2_hash = try primitives.Hex.bytesToHex(std.testing.allocator, &block_2.hash);
    defer std.testing.allocator.free(block_2_hash);
    const block_1_timestamp = try std.fmt.allocPrint(std.testing.allocator, "0x{x}", .{block_1.header.timestamp});
    defer std.testing.allocator.free(block_1_timestamp);
    const block_2_timestamp = try std.fmt.allocPrint(std.testing.allocator, "0x{x}", .{block_2.header.timestamp});
    defer std.testing.allocator.free(block_2_timestamp);

    try std.testing.expectEqualStrings("0x1", (try getObjectField(result.array.items[0], "number")).string);
    try std.testing.expectEqualStrings(block_1_hash, (try getObjectField(result.array.items[0], "hash")).string);
    try std.testing.expectEqualStrings(block_1_timestamp, (try getObjectField(result.array.items[0], "timestamp")).string);
    try std.testing.expectEqualStrings("0x2", (try getObjectField(result.array.items[1], "number")).string);
    try std.testing.expectEqualStrings(block_2_hash, (try getObjectField(result.array.items[1], "hash")).string);
    try std.testing.expectEqualStrings(block_2_timestamp, (try getObjectField(result.array.items[1], "timestamp")).string);
}

test "installed dispatch wiring applies block timestamp interval controls" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var set_response = try dispatchQuantityRequest(&handlers, "anvil_setBlockTimestampInterval", "0x7");
    defer set_response.deinit(std.testing.allocator);
    try std.testing.expect(set_response.error_value == null);
    try std.testing.expect(set_response.result.?.bool);
    try std.testing.expectEqual(@as(?u64, 7), rt.block_timestamp_interval);

    var mine_params = std.json.Array.init(std.testing.allocator);
    defer mine_params.deinit();
    try mine_params.append(.{ .string = "0x2" });

    var mine_request = try makeRequest("zevm_mineDetailed", .{ .array = mine_params });
    defer mine_request.deinit(std.testing.allocator);
    var mine_response = try dispatcher.dispatch(std.testing.allocator, mine_request, &handlers);
    defer mine_response.deinit(std.testing.allocator);
    try std.testing.expect(mine_response.error_value == null);

    const result = mine_response.result.?;
    try std.testing.expectEqualStrings("0x7", (try getObjectField(result.array.items[0], "timestamp")).string);
    try std.testing.expectEqualStrings("0xe", (try getObjectField(result.array.items[1], "timestamp")).string);

    var remove_request = try makeRequest("anvil_removeBlockTimestampInterval", null);
    defer remove_request.deinit(std.testing.allocator);
    var remove_response = try dispatcher.dispatch(std.testing.allocator, remove_request, &handlers);
    defer remove_response.deinit(std.testing.allocator);
    try std.testing.expect(remove_response.error_value == null);
    try std.testing.expect(remove_response.result.?.bool);
    try std.testing.expectEqual(@as(?u64, null), rt.block_timestamp_interval);
}

test "installed dispatch wiring maps unsupported methods to method not found" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var request = try makeRequest("no_such_method", null);
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(@as(i32, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND), response.error_value.?.code);
}

fn testCheckpoint(byte: u8) [32]u8 {
    return [_]u8{byte} ** 32;
}

const LightProofFixtureMode = enum {
    valid_empty,
    malformed,
};

const LightProofFixture = struct {
    mode: LightProofFixtureMode = .valid_empty,
    code: []const u8 = "",
    expected_block_tag: ?[]const u8 = null,

    fn resolver(self: *LightProofFixture) light_proof.RpcResolver {
        return .{
            .context = self,
            .resolve = &resolve,
        };
    }

    fn resolve(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: light_proof.RpcRequest,
    ) ![]u8 {
        const self: *LightProofFixture = @ptrCast(@alignCast(context orelse return error.InvalidContext));
        if (self.expected_block_tag) |block_tag| {
            const expected_tail = try std.fmt.allocPrint(allocator, "\"{s}\"]", .{block_tag});
            defer allocator.free(expected_tail);
            if (std.mem.indexOf(u8, request.params_json, expected_tail) == null) return error.InvalidBlockTag;
        }

        if (self.mode == .malformed) {
            return allocator.dupe(u8, "{\"nonce\":\"0x0\"}");
        }

        if (std.mem.eql(u8, request.method, "eth_getCode")) {
            const code_hex = try primitives.Hex.bytesToHex(allocator, self.code);
            defer allocator.free(code_hex);
            return try std.fmt.allocPrint(allocator, "\"{s}\"", .{code_hex});
        }

        const has_storage = std.mem.indexOf(u8, request.params_json, ",[\"0x") != null;
        if (has_storage) {
            return std.fmt.allocPrint(
                allocator,
                "{{\"nonce\":\"0x0\",\"balance\":\"0x0\",\"codeHash\":\"0x{s}\",\"storageHash\":\"0x{s}\",\"accountProof\":[],\"storageProof\":[{{\"key\":\"0x{x:0>64}\",\"value\":\"0x0\",\"proof\":[]}}]}}",
                .{
                    "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
                    "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
                    @as(u256, 1),
                },
            );
        }

        return std.fmt.allocPrint(
            allocator,
            "{{\"nonce\":\"0x0\",\"balance\":\"0x0\",\"codeHash\":\"0x{s}\",\"storageHash\":\"0x{s}\",\"accountProof\":[],\"storageProof\":[]}}",
            .{
                "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
                "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
            },
        );
    }
};

fn initLightRuntime(proof_fixture: ?*LightProofFixture) !runtime_mod.NodeRuntime {
    return runtime_mod.NodeRuntime.init(std.testing.allocator, .{
        .mode = .light,
        .light = .{
            .network = .mainnet,
            .consensus_rpc_url = "http://localhost:5052",
            .proof_resolver = if (proof_fixture) |fixture| fixture.resolver() else null,
            .advance_on_request = false,
            .checkpoint = testCheckpoint(0xaa),
            .checkpoint_source = .explicit,
        },
    });
}

fn dispatchForTest(rt: *runtime_mod.NodeRuntime, method: []const u8, params: ?std.json.Value) !jsonrpc.envelope.ResponseEnvelope {
    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, rt);

    var request = try makeRequest(method, params);
    defer request.deinit(std.testing.allocator);

    return dispatcher.dispatch(std.testing.allocator, request, &handlers);
}

fn objectField(obj: *const std.json.ObjectMap, key: []const u8) !std.json.Value {
    return obj.get(key) orelse error.MissingField;
}

fn expectErrorCode(rt: *runtime_mod.NodeRuntime, method: []const u8, params: ?std.json.Value, code: i32) !void {
    var response = try dispatchForTest(rt, method, params);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(code, response.error_value.?.code);
}

fn validAddress() std.json.Value {
    return .{ .string = "0x0000000000000000000000000000000000000042" };
}

fn parseTestAddress(text: []const u8) !primitives.Address {
    if (text.len != 42 or text[0] != '0' or text[1] != 'x') return error.InvalidAddress;
    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text[2..]) catch return error.InvalidAddress;
    return .{ .bytes = bytes };
}

fn setLightExecutionHead(rt: *runtime_mod.NodeRuntime, block_number: u64, state_root: [32]u8) !void {
    try setLightExecutionHeads(
        rt,
        .{ .block_number = block_number, .state_root = state_root },
        .{ .block_number = block_number, .state_root = state_root },
        .{ .block_number = block_number, .state_root = state_root },
    );
}

fn setLightExecutionHeads(
    rt: *runtime_mod.NodeRuntime,
    optimistic: runtime_mod.LightReadHead,
    safe: runtime_mod.LightReadHead,
    finalized: runtime_mod.LightReadHead,
) !void {
    if (rt.light) |*light| {
        light.engine.store.optimistic_header.execution.block_number = optimistic.block_number;
        light.engine.store.optimistic_header.execution.state_root = optimistic.state_root;
        light.engine.store.finalized_header.execution.block_number = finalized.block_number;
        light.engine.store.finalized_header.execution.state_root = finalized.state_root;
        try rt.recordLightReadHead(finalized);
        try rt.setLightSafeReadHead(safe);
        try rt.recordLightReadHead(optimistic);
    }
}

test "light sync status returns canonical payload while not ready" {
    var rt = try initLightRuntime(null);
    defer rt.deinit();

    var response = try dispatchForTest(&rt, "zevm_lightSyncStatus", null);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    const result = response.result.?;
    try std.testing.expect(result == .object);

    try std.testing.expectEqualStrings("syncing", (try objectField(&result.object, "status")).string);
    try std.testing.expect(!(try objectField(&result.object, "ready")).bool);
    try std.testing.expectEqualStrings("mainnet", (try objectField(&result.object, "network")).string);
    try std.testing.expectEqualStrings("explicit", (try objectField(&result.object, "checkpointSource")).string);
    try std.testing.expectEqualStrings("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", (try objectField(&result.object, "lastCheckpoint")).string);
    try std.testing.expectEqualStrings("0x0", (try objectField(&result.object, "optimisticSlot")).string);
    try std.testing.expectEqualStrings("0x0", (try objectField(&result.object, "safeSlot")).string);
    try std.testing.expectEqualStrings("0x0", (try objectField(&result.object, "finalizedSlot")).string);
}

test "zevm_lightSyncStatus is mode unsupported in trusted mode after param validation" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try expectErrorCode(&rt, "zevm_lightSyncStatus", null, dispatcher.RuntimeErrorCode.MODE_UNSUPPORTED);

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(.null);
    try expectErrorCode(&rt, "zevm_lightSyncStatus", .{ .array = params }, jsonrpc.envelope.ErrorCode.INVALID_PARAMS);
}

test "light mode malformed proof read params fail before readiness" {
    var rt = try initLightRuntime(null);
    defer rt.deinit();

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();

    try expectErrorCode(&rt, "eth_getBalance", .{ .array = params }, jsonrpc.envelope.ErrorCode.INVALID_PARAMS);
}

test "light mode pending selector is mode unsupported before readiness" {
    var rt = try initLightRuntime(null);
    defer rt.deinit();

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(validAddress());
    try params.append(.{ .string = "pending" });

    try expectErrorCode(&rt, "eth_getBalance", .{ .array = params }, dispatcher.RuntimeErrorCode.MODE_UNSUPPORTED);
}

test "light mode unsupported methods return mode unsupported after validation" {
    var rt = try initLightRuntime(null);
    defer rt.deinit();

    var tx = std.json.ObjectMap.init(std.testing.allocator);
    defer tx.deinit();
    try tx.put("to", validAddress());

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(.{ .object = tx });
    try params.append(.{ .string = "latest" });

    try expectErrorCode(&rt, "eth_call", .{ .array = params }, dispatcher.RuntimeErrorCode.MODE_UNSUPPORTED);
}

test "light mode unknown prefixed methods return method not found" {
    var rt = try initLightRuntime(null);
    defer rt.deinit();

    const methods = [_][]const u8{
        "zevm_noSuchMethod",
        "dev_noSuchMethod",
        "anvil_noSuchMethod",
        "hardhat_noSuchMethod",
        "evm_noSuchMethod",
    };

    for (methods) |method| {
        try expectErrorCode(&rt, method, null, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND);
    }
}

test "light mode known trusted controls return mode unsupported" {
    var rt = try initLightRuntime(null);
    defer rt.deinit();

    try expectErrorCode(&rt, "zevm_setBalance", null, dispatcher.RuntimeErrorCode.MODE_UNSUPPORTED);
}

test "light mode proof reads and block number return not-ready after validation" {
    var rt = try initLightRuntime(null);
    defer rt.deinit();

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(validAddress());
    try params.append(.{ .string = "latest" });

    try expectErrorCode(&rt, "eth_getBalance", .{ .array = params }, dispatcher.RuntimeErrorCode.LIGHT_NOT_READY);
    try expectErrorCode(&rt, "eth_blockNumber", null, dispatcher.RuntimeErrorCode.LIGHT_NOT_READY);

    var block_params = std.json.Array.init(std.testing.allocator);
    defer block_params.deinit();
    try block_params.append(.null);
    try expectErrorCode(&rt, "eth_blockNumber", .{ .array = block_params }, jsonrpc.envelope.ErrorCode.INVALID_PARAMS);
}

test "light mode retained window check runs after readiness" {
    var rt = try initLightRuntime(null);
    defer rt.deinit();
    try rt.setLightSyncProgress(.synced, 12, 11, 10, 10_000);

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(validAddress());
    try params.append(.{ .string = "0x2" });

    try expectErrorCode(&rt, "eth_getBalance", .{ .array = params }, jsonrpc.envelope.ErrorCode.INVALID_PARAMS);
}

test "light mode malformed proof payload maps to -32015" {
    var fixture = LightProofFixture{ .mode = .malformed };
    var rt = try initLightRuntime(&fixture);
    defer rt.deinit();
    try rt.setLightSyncProgress(.synced, 12, 11, 10, 10_000);

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(validAddress());
    try params.append(.{ .string = "latest" });

    try expectErrorCode(&rt, "eth_getBalance", .{ .array = params }, dispatcher.RuntimeErrorCode.MALFORMED_PROOF);
}

test "light mode proof verification failure maps to -32014" {
    var fixture = LightProofFixture{};
    var rt = try initLightRuntime(&fixture);
    defer rt.deinit();
    try rt.setLightSyncProgress(.synced, 12, 11, 10, 10_000);

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(validAddress());
    try params.append(.{ .string = "latest" });

    try expectErrorCode(&rt, "eth_getBalance", .{ .array = params }, dispatcher.RuntimeErrorCode.PROOF_VERIFY_FAILED);
}

test "light mode proof-backed empty account reads verify against state root" {
    var fixture = LightProofFixture{};
    var rt = try initLightRuntime(&fixture);
    defer rt.deinit();
    try rt.setLightSyncProgress(.synced, 12, 11, 10, 10_000);
    try setLightExecutionHead(&rt, 10_000, primitives.AccountState.EMPTY_TRIE_ROOT);

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(validAddress());
    try params.append(.{ .string = "latest" });

    {
        var response = try dispatchForTest(&rt, "eth_getBalance", .{ .array = params });
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("0x0", response.result.?.string);
    }
    {
        var response = try dispatchForTest(&rt, "eth_getTransactionCount", .{ .array = params });
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("0x0", response.result.?.string);
    }
    {
        var response = try dispatchForTest(&rt, "eth_getCode", .{ .array = params });
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("0x", response.result.?.string);
    }

    var storage_params = std.json.Array.init(std.testing.allocator);
    defer storage_params.deinit();
    try storage_params.append(validAddress());
    try storage_params.append(.{ .string = "0x1" });
    try storage_params.append(.{ .string = "latest" });

    var storage_response = try dispatchForTest(&rt, "eth_getStorageAt", .{ .array = storage_params });
    defer storage_response.deinit(std.testing.allocator);

    try std.testing.expect(storage_response.error_value == null);
    try std.testing.expectEqualStrings(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        storage_response.result.?.string,
    );
}

test "light mode earliest and numeric zero resolve retained genesis head" {
    var fixture = LightProofFixture{ .expected_block_tag = "0x0" };
    var rt = try initLightRuntime(&fixture);
    defer rt.deinit();
    try rt.setLightSyncProgress(.synced, 12, 11, 10, 10_000);
    try rt.recordLightReadHead(.{
        .block_number = 0,
        .state_root = primitives.AccountState.EMPTY_TRIE_ROOT,
    });

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(validAddress());
        try params.append(.{ .string = "earliest" });

        var response = try dispatchForTest(&rt, "eth_getBalance", .{ .array = params });
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("0x0", response.result.?.string);
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(validAddress());
        try params.append(.{ .string = "0x0" });

        var response = try dispatchForTest(&rt, "eth_getBalance", .{ .array = params });
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("0x0", response.result.?.string);
    }
}

test "light mode safe and finalized selectors use distinct heads" {
    var fixture = LightProofFixture{};
    var rt = try initLightRuntime(&fixture);
    defer rt.deinit();
    try rt.setLightSyncProgress(.synced, 12, 11, 10, 10_000);
    try setLightExecutionHeads(
        &rt,
        .{ .block_number = 10_000, .state_root = primitives.AccountState.EMPTY_TRIE_ROOT },
        .{ .block_number = 9_500, .state_root = primitives.AccountState.EMPTY_TRIE_ROOT },
        .{ .block_number = 9_000, .state_root = [_]u8{0x42} ** 32 },
    );

    {
        fixture.expected_block_tag = "0x251c";
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(validAddress());
        try params.append(.{ .string = "safe" });

        var response = try dispatchForTest(&rt, "eth_getBalance", .{ .array = params });
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("0x0", response.result.?.string);
    }

    {
        fixture.expected_block_tag = "0x2328";
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(validAddress());
        try params.append(.{ .string = "finalized" });

        try expectErrorCode(&rt, "eth_getBalance", .{ .array = params }, dispatcher.RuntimeErrorCode.PROOF_VERIFY_FAILED);
    }
}

test "light mode numeric selector resolves retained lower boundary head" {
    var fixture = LightProofFixture{ .expected_block_tag = "0x712" };
    var rt = try initLightRuntime(&fixture);
    defer rt.deinit();
    try rt.setLightSyncProgress(.synced, 12, 11, 10, 10_000);
    try setLightExecutionHead(&rt, 10_000, primitives.AccountState.EMPTY_TRIE_ROOT);
    try rt.recordLightReadHead(.{
        .block_number = 1_810,
        .state_root = primitives.AccountState.EMPTY_TRIE_ROOT,
    });

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(validAddress());
    try params.append(.{ .string = "0x712" });

    var response = try dispatchForTest(&rt, "eth_getBalance", .{ .array = params });
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    try std.testing.expectEqualStrings("0x0", response.result.?.string);
}

test "installed dispatch wiring handles automine aliases" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    {
        var response = try dispatchForTest(&rt, "zevm_getAutomine", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        try std.testing.expect(response.result.?.bool);
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .bool = false });

        try expectBoolRpc(&handlers, "evm_setAutomine", .{ .array = params });
        try std.testing.expectEqual(mining.MiningConfigType.manual, std.meta.activeTag(rt.mining_config));
    }

    {
        var response = try dispatchForTest(&rt, "hardhat_getAutomine", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        try std.testing.expect(!response.result.?.bool);
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .bool = true });

        try expectBoolRpc(&handlers, "anvil_setAutomine", .{ .array = params });
        try std.testing.expectEqual(mining.MiningConfigType.auto, std.meta.activeTag(rt.mining_config));
    }
}

test "installed dispatch wiring handles interval mining aliases" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    {
        var response = try dispatchForTest(&rt, "zevm_getIntervalMining", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("0x0", response.result.?.string);
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = "0xc" });

        try expectBoolRpc(&handlers, "evm_setIntervalMining", .{ .array = params });
        try std.testing.expectEqual(mining.MiningConfigType.interval, std.meta.activeTag(rt.mining_config));
        switch (rt.mining_config) {
            .interval => |interval| try std.testing.expectEqual(@as(u64, 12), interval.block_time),
            else => return error.TestUnexpectedResult,
        }
    }

    {
        var response = try dispatchForTest(&rt, "anvil_getIntervalMining", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        try std.testing.expectEqualStrings("0xc", response.result.?.string);
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = "0x0" });

        try expectBoolRpc(&handlers, "anvil_setIntervalMining", .{ .array = params });
        try std.testing.expectEqual(mining.MiningConfigType.manual, std.meta.activeTag(rt.mining_config));
    }
}

test "installed dispatch wiring interval mining seals periodically and stops on manual mode" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = "0x1" });
        try expectBoolRpc(&handlers, "zevm_setIntervalMining", .{ .array = params });
    }

    try waitForRpcBlockNumberAtLeast(&handlers, 1);
    const mined_head = try rpcBlockNumber(&handlers);
    try std.testing.expect(mined_head >= 1);

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .bool = false });
        try expectBoolRpc(&handlers, "evm_setAutomine", .{ .array = params });
    }

    const stopped_head = try rpcBlockNumber(&handlers);
    std.Thread.sleep(1200 * std.time.ns_per_ms);
    try std.testing.expectEqual(stopped_head, try rpcBlockNumber(&handlers));
}

test "installed dispatch wiring handles state and metadata helper aliases" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(validAddress());
        try params.append(.{ .string = "0x2a" });

        try expectBoolRpc(&handlers, "zevm_deal", .{ .array = params });
        try std.testing.expectEqual(@as(u256, 42), try rt.getBalance(try parseTestAddress("0x0000000000000000000000000000000000000042")));
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(validAddress());
        try params.append(.{ .string = "0x8" });

        try expectBoolRpc(&handlers, "anvil_addBalance", .{ .array = params });
        try std.testing.expectEqual(@as(u256, 50), try rt.getBalance(try parseTestAddress("0x0000000000000000000000000000000000000042")));
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = "0x539" });

        try expectBoolRpc(&handlers, "anvil_setChainId", .{ .array = params });
        try std.testing.expectEqual(@as(u64, 1337), rt.chain_id);
    }

    {
        var response = try dispatchForTest(&rt, "zevm_metadata", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        const object = response.result.?.object;
        try std.testing.expectEqualStrings("trusted", (try objectField(&object, "mode")).string);
        try std.testing.expectEqualStrings("0x539", (try objectField(&object, "chainId")).string);
        try std.testing.expect(!(try objectField(&object, "forking")).bool);
    }

    {
        var response = try dispatchForTest(&rt, "anvil_nodeInfo", null);
        defer response.deinit(std.testing.allocator);
        try std.testing.expect(response.error_value == null);
        const object = response.result.?.object;
        try std.testing.expectEqualStrings("0x539", (try objectField(&object, "chainId")).string);
        try std.testing.expectEqualStrings("0x0", (try objectField(&object, "blockNumber")).string);
        try std.testing.expectEqual(@as(usize, 10), (try objectField(&object, "managedAccounts")).array.items.len);
        const mining_object = (try objectField(&object, "mining")).object;
        try std.testing.expectEqualStrings("auto", (try objectField(&mining_object, "type")).string);
        const fork_object = (try objectField(&object, "fork")).object;
        try std.testing.expect(!(try objectField(&fork_object, "enabled")).bool);
    }
}

test "engine capabilities expose implemented engine methods" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var capabilities = std.json.Array.init(allocator);
    try capabilities.append(.{ .string = "engine_newPayloadV3" });

    var params = std.json.Array.init(allocator);
    try params.append(.{ .array = capabilities });

    var request = try makeRequest("engine_exchangeCapabilities", .{ .array = params });
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    const result = response.result.?.array.items;
    var found_forkchoice = false;
    var found_new_payload = false;
    for (result) |item| {
        if (std.mem.eql(u8, item.string, "engine_forkchoiceUpdatedV3")) found_forkchoice = true;
        if (std.mem.eql(u8, item.string, "engine_newPayloadV3")) found_new_payload = true;
    }
    try std.testing.expect(found_forkchoice);
    try std.testing.expect(found_new_payload);
}

test "engine lifecycle methods are routed and validate params" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const methods = [_][]const u8{
        "engine_newPayloadV1",
        "engine_newPayloadV2",
        "engine_newPayloadV3",
        "engine_getPayloadV1",
        "engine_getPayloadV2",
        "engine_getPayloadBodiesByHashV1",
        "engine_getPayloadBodiesByRangeV1",
    };

    for (methods) |method| {
        try expectErrorCode(&rt, method, null, jsonrpc.envelope.ErrorCode.INVALID_PARAMS);
    }

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(.{ .string = "0x0000000000000001" });
    try expectErrorCode(&rt, "engine_getPayloadV1", .{ .array = params }, dispatcher.RuntimeErrorCode.ENGINE_UNKNOWN_PAYLOAD);
}

test "engine forkchoice validates against known canonical blocks" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const head = try rt.blockchain.getCanonicalHeadBlock();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const head_text = try hashText(allocator, head.hash);

    var forkchoice = std.json.ObjectMap.init(allocator);
    try forkchoice.put("headBlockHash", .{ .string = head_text });
    try forkchoice.put("safeBlockHash", hash32Value());
    try forkchoice.put("finalizedBlockHash", hash32Value());

    var params = std.json.Array.init(allocator);
    try params.append(.{ .object = forkchoice });
    try params.append(.null);

    var request = try makeRequest("engine_forkchoiceUpdatedV3", .{ .array = params });
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    const payload_status = try getObjectField(response.result.?, "payloadStatus");
    try std.testing.expectEqualStrings("VALID", (try getObjectField(payload_status, "status")).string);
    try std.testing.expectEqualStrings(head_text, (try getObjectField(payload_status, "latestValidHash")).string);
    try std.testing.expectEqual(head.header.number, rt.head_block_number);
}

test "engine forkchoice reports syncing for unknown head" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var forkchoice = std.json.ObjectMap.init(allocator);
    try forkchoice.put("headBlockHash", .{ .string = "0x1111111111111111111111111111111111111111111111111111111111111111" });
    try forkchoice.put("safeBlockHash", hash32Value());
    try forkchoice.put("finalizedBlockHash", hash32Value());

    var params = std.json.Array.init(allocator);
    try params.append(.{ .object = forkchoice });
    try params.append(.null);

    var request = try makeRequest("engine_forkchoiceUpdatedV3", .{ .array = params });
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    const payload_status = try getObjectField(response.result.?, "payloadStatus");
    try std.testing.expectEqualStrings("SYNCING", (try getObjectField(payload_status, "status")).string);
    try std.testing.expectEqual(.null, try getObjectField(payload_status, "latestValidHash"));
}

test "installed dispatch wiring mines empty blocks through aliases" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();

        try expectBoolRpc(&handlers, "anvil_mine", .{ .array = params });
        try std.testing.expectEqual(@as(u64, 1), rt.head_block_number);
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = "0x2" });
        try params.append(.{ .string = "0xa" });

        try expectBoolRpc(&handlers, "hardhat_mine", .{ .array = params });
        try std.testing.expectEqual(@as(u64, 3), rt.head_block_number);
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = "0x1" });

        try expectBoolRpc(&handlers, "evm_mine", .{ .array = params });
        try std.testing.expectEqual(@as(u64, 4), rt.head_block_number);
    }
}

test "installed dispatch wiring rejects malformed mining params" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = "false" });

        try expectInvalidParamsRpc(&handlers, "anvil_setAutomine", .{ .array = params });
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .integer = 1 });

        try expectInvalidParamsRpc(&handlers, "anvil_mine", .{ .array = params });
    }
}

test "installed dispatch wiring rejects structurally invalid fork URLs" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = "https://rpc.example",
    });
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = "https://" });

        try expectInvalidParamsRpc(&handlers, "zevm_setRpcUrl", .{ .array = params });
    }

    {
        var cfg_obj = std.json.ObjectMap.init(std.testing.allocator);
        defer cfg_obj.deinit();
        try cfg_obj.put("url", .{ .string = "http://" });

        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .object = cfg_obj });

        try expectInvalidParamsRpc(&handlers, "zevm_reset", .{ .array = params });
    }
}

test "installed dispatch wiring rejects non-hex and non-minimal quantities" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(validAddress());
        try params.append(.{ .integer = 1 });

        try expectInvalidParamsRpc(&handlers, "zevm_setBalance", .{ .array = params });
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(validAddress());
        try params.append(.{ .string = "0x01" });

        try expectInvalidParamsRpc(&handlers, "zevm_setBalance", .{ .array = params });
    }

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(validAddress());
        try params.append(.{ .integer = 1 });

        try expectInvalidParamsRpc(&handlers, "eth_getBalance", .{ .array = params });
    }
}
