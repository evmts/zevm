const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const dispatcher = @import("dispatcher.zig");
const dispatch_wiring = @import("dispatch_wiring.zig");
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

    var timestamp_response = try dispatchQuantityRequest(&handlers, "hardhat_setNextBlockTimestamp", "0x4d2");
    defer timestamp_response.deinit(std.testing.allocator);
    try std.testing.expect(timestamp_response.error_value == null);
    try std.testing.expect(timestamp_response.result.?.bool);
    try std.testing.expectEqual(@as(u64, 1234), rt.dev_runtime.config.next_block_timestamp.?);

    var blob_fee_response = try dispatchQuantityRequest(&handlers, "anvil_setBlobBaseFee", "0x7");
    defer blob_fee_response.deinit(std.testing.allocator);
    try std.testing.expect(blob_fee_response.error_value == null);
    try std.testing.expect(blob_fee_response.result.?.bool);
    try std.testing.expectEqual(@as(u256, 7), rt.dev_runtime.config.blob_base_fee.?);

    var blob_read = try makeRequest("eth_blobBaseFee", null);
    defer blob_read.deinit(std.testing.allocator);
    var blob_read_response = try dispatcher.dispatch(std.testing.allocator, blob_read, &handlers);
    defer blob_read_response.deinit(std.testing.allocator);
    try std.testing.expect(blob_read_response.error_value == null);
    try std.testing.expectEqualStrings("0x7", blob_read_response.result.?.string);
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

fn setLightExecutionHead(rt: *runtime_mod.NodeRuntime, block_number: u64, state_root: [32]u8) void {
    if (rt.light) |*light| {
        light.engine.store.optimistic_header.execution.block_number = block_number;
        light.engine.store.optimistic_header.execution.state_root = state_root;
        light.engine.store.finalized_header.execution.block_number = block_number;
        light.engine.store.finalized_header.execution.state_root = state_root;
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
    setLightExecutionHead(&rt, 10_000, primitives.AccountState.EMPTY_TRIE_ROOT);

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
