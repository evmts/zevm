//! Wires the JSON-RPC dispatcher to the live NodeRuntime.

const std = @import("std");
const primitives = @import("primitives");
const dispatcher_mod = @import("dispatcher.zig");
const eth_read = @import("handlers/eth_read.zig");
const runtime_mod = @import("../node/runtime.zig");
const simulation = @import("handlers/simulation.zig");
const trusted_fork_handlers = @import("trusted_fork_handlers.zig");
const txpool_handlers = @import("handlers/txpool.zig");

var runtime_ptr: ?*runtime_mod.NodeRuntime = null;

pub fn install(registry: *dispatcher_mod.HandlerRegistry, rt: *runtime_mod.NodeRuntime) void {
    runtime_ptr = rt;
    registry.on_method = dispatchMethod;
}

fn dispatchMethod(
    allocator: std.mem.Allocator,
    method_name: []const u8,
    params: ?std.json.Value,
) anyerror!std.json.Value {
    const rt = runtime_ptr orelse return error.MethodNotFound;

    if (rt.mode == .light) {
        return dispatchLightMethod(allocator, rt, method_name, params);
    }
    if (std.mem.eql(u8, method_name, "zevm_lightSyncStatus")) {
        try validateNoParams(params);
        return error.ModeUnsupported;
    }

    if (std.mem.eql(u8, method_name, "web3_clientVersion")) {
        return .{ .string = try allocator.dupe(u8, "zevm/0.1.0") };
    }
    if (std.mem.eql(u8, method_name, "web3_sha3")) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        const input = switch (items[0]) {
            .string => |s| try hexStringToBytes(allocator, s),
            else => return error.InvalidParams,
        };
        defer allocator.free(input);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(input, &digest, .{});
        return hexBytes(allocator, &digest);
    }
    if (std.mem.eql(u8, method_name, "net_version")) {
        return .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{rt.chain_id}) };
    }
    if (std.mem.eql(u8, method_name, "net_listening")) {
        return .{ .bool = true };
    }
    if (std.mem.eql(u8, method_name, "net_peerCount")) {
        return hexQuantity(allocator, 0);
    }

    if (std.mem.eql(u8, method_name, "eth_chainId")) {
        return hexQuantity(allocator, rt.chain_id);
    }
    if (std.mem.eql(u8, method_name, "eth_blockNumber")) {
        return hexQuantity(allocator, rt.head_block_number);
    }
    if (std.mem.eql(u8, method_name, "eth_gasPrice")) {
        return hexU256(allocator, rt.gas_price);
    }
    if (std.mem.eql(u8, method_name, "eth_maxPriorityFeePerGas")) {
        return hexU256(allocator, rt.max_priority_fee);
    }
    if (std.mem.eql(u8, method_name, "eth_blobBaseFee")) {
        return hexU256(allocator, currentBlobBaseFee(rt));
    }
    if (std.mem.eql(u8, method_name, "eth_feeHistory")) {
        const fee_history_params = try eth_read.parseEthFeeHistoryParams(allocator, params);
        defer eth_read.deinitEthFeeHistoryParams(allocator, fee_history_params);
        return eth_read.handleEthFeeHistoryValue(allocator, rt, fee_history_params);
    }
    if (std.mem.eql(u8, method_name, "eth_coinbase")) {
        return addressString(allocator, rt.coinbase);
    }
    if (std.mem.eql(u8, method_name, "eth_accounts")) {
        return accountsResponse(allocator);
    }
    if (std.mem.eql(u8, method_name, "eth_mining")) {
        return .{ .bool = std.meta.activeTag(rt.mining_config) != .manual };
    }
    if (std.mem.eql(u8, method_name, "eth_syncing")) {
        return .{ .bool = false };
    }
    if (std.mem.eql(u8, method_name, "eth_protocolVersion")) {
        return .{ .string = try allocator.dupe(u8, "0x41") };
    }
    if (std.mem.eql(u8, method_name, "eth_getBalance")) {
        const args = try parseAddrAndBlockArgs(params);
        const balance = try rt.getBalance(args.address);
        return hexU256(allocator, balance);
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionCount")) {
        const args = try parseAddrAndBlockArgs(params);
        const nonce = try rt.getNonce(args.address);
        return hexQuantity(allocator, nonce);
    }
    if (std.mem.eql(u8, method_name, "eth_getCode")) {
        const args = try parseAddrAndBlockArgs(params);
        const code = try rt.getCode(args.address);
        return hexBytes(allocator, code);
    }
    if (std.mem.eql(u8, method_name, "eth_getStorageAt")) {
        const args = try parseStorageArgs(params);
        const value = try rt.getStorage(args.address, args.slot);
        return hexU256(allocator, value);
    }
    if (std.mem.eql(u8, method_name, "txpool_content")) {
        return txpool_handlers.handleContent(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "txpool_status")) {
        return txpool_handlers.handleStatus(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "txpool_inspect")) {
        return txpool_handlers.handleInspect(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "eth_call")) {
        return simulation.handleEthCall(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "eth_estimateGas")) {
        return simulation.handleEthEstimateGas(allocator, rt, params);
    }

    if (methodIs(method_name, &.{ "zevm_reset", "anvil_reset", "hardhat_reset" })) {
        return trusted_fork_handlers.handleZevmReset(rt, params);
    }
    if (methodIs(method_name, &.{ "zevm_setRpcUrl", "anvil_setRpcUrl" })) {
        return trusted_fork_handlers.handleZevmSetRpcUrl(allocator, rt, params);
    }
    if (methodIs(method_name, &.{ "zevm_setBalance", "anvil_setBalance", "hardhat_setBalance" })) {
        const args = try parseAddrU256Args(params);
        try rt.setBalance(args.address, args.value);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setNonce", "anvil_setNonce", "hardhat_setNonce" })) {
        const args = try parseAddrU64Args(params);
        try rt.setNonce(args.address, args.value);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setCode", "anvil_setCode", "hardhat_setCode" })) {
        const args = try parseSetCodeArgs(allocator, params);
        defer allocator.free(args.code);
        try rt.setCode(args.address, args.code);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setStorageAt", "anvil_setStorageAt", "hardhat_setStorageAt" })) {
        const args = try parseSetStorageArgs(params);
        try rt.setStorage(args.address, args.slot, args.value);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setCoinbase", "anvil_setCoinbase", "hardhat_setCoinbase" })) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        rt.coinbase = try parseAddressJson(items[0]);
        rt.dev_runtime.config.coinbase = rt.coinbase;
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setBlockGasLimit", "anvil_setBlockGasLimit", "hardhat_setBlockGasLimit", "evm_setBlockGasLimit" })) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        rt.dev_runtime.config.block_gas_limit = try parseU64Json(items[0]);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setNextBlockBaseFeePerGas", "anvil_setNextBlockBaseFeePerGas", "hardhat_setNextBlockBaseFeePerGas" })) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        rt.dev_runtime.config.next_block_base_fee_per_gas = try parseU256Json(items[0]);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setNextBlockTimestamp", "anvil_setNextBlockTimestamp", "hardhat_setNextBlockTimestamp", "evm_setNextBlockTimestamp" })) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        rt.setNextBlockTimestamp(try parseU64Json(items[0]));
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setBlobBaseFee", "anvil_setBlobBaseFee", "hardhat_setBlobBaseFee" })) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        const blob_base_fee = try parseU256Json(items[0]);
        rt.dev_runtime.config.blob_base_fee = blob_base_fee;
        rt.blob_base_fee = blob_base_fee;
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_impersonateAccount", "anvil_impersonateAccount", "hardhat_impersonateAccount" })) {
        const address = try parseSingleAddressArg(params);
        try rt.impersonateAccount(address);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_stopImpersonatingAccount", "anvil_stopImpersonatingAccount", "hardhat_stopImpersonatingAccount" })) {
        const address = try parseSingleAddressArg(params);
        rt.stopImpersonatingAccount(address);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{
        "zevm_setAutoImpersonateAccount",
        "anvil_setAutoImpersonateAccount",
        "hardhat_setAutoImpersonateAccount",
        "zevm_autoImpersonateAccount",
        "anvil_autoImpersonateAccount",
    })) {
        const enabled = try parseSingleBoolArg(params);
        rt.setAutoImpersonateAccount(enabled);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_increaseTime", "anvil_increaseTime", "evm_increaseTime" })) {
        const seconds = try parseTimeControlQuantity(params);
        return hexQuantity(allocator, try rt.increaseTime(seconds));
    }
    if (methodIs(method_name, &.{ "zevm_setTime", "anvil_setTime", "evm_setTime" })) {
        const timestamp = try parseTimeControlQuantity(params);
        return hexQuantity(allocator, try rt.setTime(timestamp));
    }
    if (methodIs(method_name, &.{ "zevm_setNextBlockTimestamp", "anvil_setNextBlockTimestamp", "evm_setNextBlockTimestamp", "hardhat_setNextBlockTimestamp" })) {
        const timestamp = try parseTimeControlQuantity(params);
        rt.setNextBlockTimestamp(timestamp);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_snapshot", "anvil_snapshot", "evm_snapshot" })) {
        return hexQuantity(allocator, try rt.snapshot());
    }
    if (methodIs(method_name, &.{ "zevm_revert", "anvil_revert", "evm_revert" })) {
        const snapshot_id = try parseSnapshotId(params);
        return .{ .bool = try rt.revertToSnapshot(snapshot_id) };
    }
    if (methodIs(method_name, &.{ "zevm_mine", "anvil_mine", "evm_mine", "hardhat_mine" })) {
        const args = try parseMineArgs(params);
        try rt.mineBlocks(args.count, args.interval_seconds);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setAutomine", "anvil_setAutomine", "evm_setAutomine" })) {
        const enabled = try parseSetAutomineArgs(params);
        rt.setAutomine(enabled);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setIntervalMining", "anvil_setIntervalMining", "evm_setIntervalMining" })) {
        const seconds = try parseSetIntervalMiningArgs(params);
        rt.setIntervalMining(seconds);
        return .{ .bool = true };
    }

    return error.MethodNotFound;
}

const AddrBlockArgs = struct {
    address: primitives.Address,
};

const StorageArgs = struct {
    address: primitives.Address,
    slot: u256,
};

const AddrU256Args = struct {
    address: primitives.Address,
    value: u256,
};

const AddrU64Args = struct {
    address: primitives.Address,
    value: u64,
};

const CodeArgs = struct {
    address: primitives.Address,
    code: []u8,
};

const StorageSetArgs = struct {
    address: primitives.Address,
    slot: u256,
    value: u256,
};

const MineArgs = struct {
    count: u64,
    interval_seconds: u64,
};

fn paramsArrayItems(params: ?std.json.Value) ![]const std.json.Value {
    const value = params orelse return error.InvalidParams;
    return switch (value) {
        .array => |array| array.items,
        else => error.InvalidParams,
    };
}

fn parseAddrAndBlockArgs(params: ?std.json.Value) !AddrBlockArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    try validateBlockSpecJson(items[1]);
    return .{ .address = try parseAddressJson(items[0]) };
}

fn parseStorageArgs(params: ?std.json.Value) !StorageArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 3) return error.InvalidParams;
    try validateBlockSpecJson(items[2]);
    return .{
        .address = try parseAddressJson(items[0]),
        .slot = try parseU256Json(items[1]),
    };
}

fn parseAddrU256Args(params: ?std.json.Value) !AddrU256Args {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    return .{
        .address = try parseAddressJson(items[0]),
        .value = try parseU256Json(items[1]),
    };
}

fn parseAddrU64Args(params: ?std.json.Value) !AddrU64Args {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    return .{
        .address = try parseAddressJson(items[0]),
        .value = try parseU64Json(items[1]),
    };
}

fn parseSetCodeArgs(allocator: std.mem.Allocator, params: ?std.json.Value) !CodeArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    const code = switch (items[1]) {
        .string => |s| try hexStringToBytes(allocator, s),
        else => return error.InvalidParams,
    };
    return .{
        .address = try parseAddressJson(items[0]),
        .code = code,
    };
}

fn parseSetStorageArgs(params: ?std.json.Value) !StorageSetArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 3) return error.InvalidParams;
    return .{
        .address = try parseAddressJson(items[0]),
        .slot = try parseU256Json(items[1]),
        .value = try parseU256Json(items[2]),
    };
}

fn parseSnapshotId(params: ?std.json.Value) !u64 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return parseU64Json(items[0]);
}

fn parseSingleAddressArg(params: ?std.json.Value) !primitives.Address {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return parseAddressJson(items[0]);
}

fn parseSingleBoolArg(params: ?std.json.Value) !bool {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return switch (items[0]) {
        .bool => |enabled| enabled,
        else => error.InvalidParams,
    };
}

fn parseMineArgs(params: ?std.json.Value) !MineArgs {
    const items = try paramsArrayItems(params);
    if (items.len > 2) return error.InvalidParams;
    if (items.len == 0) {
        return .{
            .count = 1,
            .interval_seconds = 0,
        };
    }

    return .{
        .count = try parseQuantityU64Json(items[0]),
        .interval_seconds = if (items.len == 2) try parseQuantityU64Json(items[1]) else 0,
    };
}

fn parseSetAutomineArgs(params: ?std.json.Value) !bool {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return switch (items[0]) {
        .bool => |enabled| enabled,
        else => error.InvalidParams,
    };
}

fn parseSetIntervalMiningArgs(params: ?std.json.Value) !u64 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return parseQuantityU64Json(items[0]);
}

fn parseTimeControlQuantity(params: ?std.json.Value) !u64 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return parseQuantityU64Json(items[0]);
}

fn validateBlockSpecJson(value: std.json.Value) !void {
    switch (value) {
        .string => {},
        .integer => |n| if (n < 0) return error.InvalidParams,
        else => return error.InvalidParams,
    }
}

fn parseAddressJson(value: std.json.Value) !primitives.Address {
    return switch (value) {
        .string => |s| parseAddressString(s),
        else => error.InvalidParams,
    };
}

fn parseAddressString(text: []const u8) !primitives.Address {
    if (!hasHexPrefix(text)) return error.InvalidParams;
    const hex = text[2..];
    if (hex.len != 40) return error.InvalidParams;
    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidParams;
    return .{ .bytes = bytes };
}

fn parseU64Json(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n < 0) error.InvalidParams else @intCast(n),
        .string => |s| parseU64String(s),
        else => error.InvalidParams,
    };
}

fn parseQuantityU64Json(value: std.json.Value) !u64 {
    return switch (value) {
        .string => |s| parseU64String(s),
        else => error.InvalidParams,
    };
}

fn parseU64String(text: []const u8) !u64 {
    if (!isQuantityHex(text)) return error.InvalidParams;
    return std.fmt.parseInt(u64, text[2..], 16) catch error.InvalidParams;
}

fn parseU256Json(value: std.json.Value) !u256 {
    return switch (value) {
        .integer => |n| if (n < 0) error.InvalidParams else @intCast(n),
        .string => |s| parseU256String(s),
        else => error.InvalidParams,
    };
}

fn parseU256String(text: []const u8) !u256 {
    if (!isQuantityHex(text)) return error.InvalidParams;
    return std.fmt.parseInt(u256, text[2..], 16) catch error.InvalidParams;
}

fn hexStringToBytes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var hex = text;
    if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
        hex = hex[2..];
    }
    if (hex.len == 0) return try allocator.alloc(u8, 0);
    if (hex.len % 2 != 0) return error.InvalidParams;
    const out = try allocator.alloc(u8, hex.len / 2);
    _ = std.fmt.hexToBytes(out, hex) catch {
        allocator.free(out);
        return error.InvalidParams;
    };
    return out;
}

fn hasHexPrefix(text: []const u8) bool {
    return text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X');
}

fn isQuantityHex(text: []const u8) bool {
    return text.len > 2 and hasHexPrefix(text);
}

fn hexQuantity(allocator: std.mem.Allocator, n: u64) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{n}) };
}

fn hexU256(allocator: std.mem.Allocator, n: u256) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{n}) };
}

fn hexBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    if (bytes.len == 0) {
        return .{ .string = try allocator.dupe(u8, "0x") };
    }
    const buf = try allocator.alloc(u8, 2 + bytes.len * 2);
    buf[0] = '0';
    buf[1] = 'x';
    writeHexLower(buf[2..], bytes);
    return .{ .string = buf };
}

fn addressString(allocator: std.mem.Allocator, address: primitives.Address) !std.json.Value {
    const buf = try allocator.alloc(u8, 42);
    buf[0] = '0';
    buf[1] = 'x';
    writeHexLower(buf[2..], &address.bytes);
    return .{ .string = buf };
}

fn writeHexLower(out: []u8, src: []const u8) void {
    const charset = "0123456789abcdef";
    for (src, 0..) |b, i| {
        out[i * 2] = charset[(b >> 4) & 0x0f];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
}

fn accountsResponse(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }
    for (runtime_mod.DEFAULT_DEV_ACCOUNTS) |addr| {
        try array.append(try addressString(allocator, addr));
    }
    return .{ .array = array };
}

fn currentBlobBaseFee(rt: *const runtime_mod.NodeRuntime) u256 {
    return rt.dev_runtime.config.blob_base_fee orelse rt.blob_base_fee;
}

fn deinitJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string => |text| allocator.free(text),
        .number_string => |text| allocator.free(text),
        .array => |*array| {
            for (array.items) |*item| {
                deinitJsonValue(allocator, item);
            }
            array.deinit();
        },
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
        else => {},
    }
}

fn methodIs(method_name: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |name| {
        if (std.mem.eql(u8, method_name, name)) return true;
    }
    return false;
}
