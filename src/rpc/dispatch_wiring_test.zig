const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const dispatcher = @import("dispatcher.zig");
const dispatch_wiring = @import("dispatch_wiring.zig");
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

test "installed dispatch wiring reaches runtime-backed eth_feeHistory" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    rt.head_block_number = 2;

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

    const reward = (try getObjectField(result, "reward")).array.items;
    try std.testing.expectEqual(@as(usize, 1), reward.len);
    try std.testing.expectEqual(@as(usize, 2), reward[0].array.items.len);
    try std.testing.expect(result.object.get("baseFeePerBlobGas") == null);
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

        try expectBoolRpc(&handlers, "zevm_setAutoImpersonateAccount", .{ .array = params });
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

    var set_time_response = try dispatchOneStringParam(&handlers, "evm_setTime", target_hex);
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

    var hardhat_next_response = try dispatchOneStringParam(&handlers, "hardhat_setNextBlockTimestamp", "0x303a");
    defer hardhat_next_response.deinit(std.testing.allocator);
    try std.testing.expect(hardhat_next_response.error_value == null);
    try std.testing.expect(hardhat_next_response.result.?.bool);
    try std.testing.expectEqual(@as(?u64, 12346), rt.next_block_timestamp);
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

test "installed dispatch wiring handles automine aliases" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    {
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .bool = false });

        try expectBoolRpc(&handlers, "evm_setAutomine", .{ .array = params });
        try std.testing.expectEqual(mining.MiningConfigType.manual, std.meta.activeTag(rt.mining_config));
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
        var params = std.json.Array.init(std.testing.allocator);
        defer params.deinit();
        try params.append(.{ .string = "0x0" });

        try expectBoolRpc(&handlers, "anvil_setIntervalMining", .{ .array = params });
        try std.testing.expectEqual(mining.MiningConfigType.manual, std.meta.activeTag(rt.mining_config));
    }
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
