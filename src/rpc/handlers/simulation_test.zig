const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const runtime = @import("../../node/runtime.zig");
const dispatcher = @import("../dispatcher.zig");
const dispatch_wiring = @import("../dispatch_wiring.zig");
const simulation = @import("simulation.zig");

const RETURN_32_BYTE_42 = [_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
const SSTORE_THEN_RETURN_42 = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
const SSTORE_THEN_REVERT_42 = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xfd };
const RETURN_TIMESTAMP = [_]u8{ 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
const RETURN_GAS_LIMIT = [_]u8{ 0x45, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
const RETURN_BASE_FEE = [_]u8{ 0x48, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
const RETURN_BLOCKHASH_ZERO = [_]u8{ 0x60, 0x00, 0x40, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
const TARGET = "0x1000000000000000000000000000000000000001";
const MISSING_TARGET = "0x3000000000000000000000000000000000000003";
const DEFAULT_ACCOUNT = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";
const RECIPIENT_ACCOUNT = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8";
const EXPECTED_32_BYTE_42 = "0x000000000000000000000000000000000000000000000000000000000000002a";

test "simulation exposes mode unsupported error tuple" {
    try std.testing.expectEqual(@as(i32, -32010), simulation.MODE_UNSUPPORTED_ERROR_CODE);
    try std.testing.expectEqualStrings("mode-unsupported", simulation.MODE_UNSUPPORTED_MESSAGE);
}

test "eth_call returns output without mutating state" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const target = try parseAddress(TARGET);
    try rt.setCode(target, &SSTORE_THEN_RETURN_42);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","data":"0x"},"latest"]
    );
    defer parsed.deinit();

    const result = try simulation.handleEthCall(std.testing.allocator, &rt, parsed.value);
    defer std.testing.allocator.free(result.string);

    try std.testing.expectEqualStrings(EXPECTED_32_BYTE_42, result.string);
    try std.testing.expectEqual(@as(u256, 0), try rt.getStorage(target, 0));
}

test "eth_call applies state overrides only inside simulation" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const target = try parseAddress(TARGET);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001"},"latest",{"0x1000000000000000000000000000000000000001":{"code":"0x602a60005260206000f3"}}]
    );
    defer parsed.deinit();

    const result = try simulation.handleEthCall(std.testing.allocator, &rt, parsed.value);
    defer std.testing.allocator.free(result.string);

    try std.testing.expectEqualStrings(EXPECTED_32_BYTE_42, result.string);
    try std.testing.expectEqual(@as(usize, 0), (try rt.getCode(target)).len);
}

test "eth_call to missing account returns empty output without creating code" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const target = try parseAddress(MISSING_TARGET);

    var parsed = try parseJson(
        \\[{"to":"0x3000000000000000000000000000000000000003"},"latest"]
    );
    defer parsed.deinit();

    const result = try simulation.handleEthCall(std.testing.allocator, &rt, parsed.value);
    defer std.testing.allocator.free(result.string);

    try std.testing.expectEqualStrings("0x", result.string);
    try std.testing.expectEqual(@as(usize, 0), (try rt.getCode(target)).len);
}

test "eth_call transfer-like request does not mutate balances" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const sender = try parseAddress(DEFAULT_ACCOUNT);
    const recipient = try parseAddress(RECIPIENT_ACCOUNT);
    const sender_balance_before = try rt.getBalance(sender);
    const recipient_balance_before = try rt.getBalance(recipient);

    var parsed = try parseJson(
        \\[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":"0x70997970c51812dc3a010c7d01b50e0d17dc79c8","value":"0x64"},"latest"]
    );
    defer parsed.deinit();

    const result = try simulation.handleEthCall(std.testing.allocator, &rt, parsed.value);
    defer std.testing.allocator.free(result.string);

    try std.testing.expectEqualStrings("0x", result.string);
    try std.testing.expectEqual(sender_balance_before, try rt.getBalance(sender));
    try std.testing.expectEqual(recipient_balance_before, try rt.getBalance(recipient));
}

test "eth_call create succeeds without persisting nonce or code" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const sender = try parseAddress(DEFAULT_ACCOUNT);
    try rt.setNonce(sender, 7);
    const created = try primitives.Address.getContractAddress(std.testing.allocator, sender, 7);

    var parsed = try parseJson(
        \\[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":null,"data":"0x602a60005260206000f3","gas":"0x100000"},"latest"]
    );
    defer parsed.deinit();

    const result = try simulation.handleEthCall(std.testing.allocator, &rt, parsed.value);
    defer std.testing.allocator.free(result.string);

    try std.testing.expectEqualStrings("0x", result.string);
    try std.testing.expectEqual(@as(u64, 7), try rt.getNonce(sender));
    try std.testing.expectEqual(@as(usize, 0), (try rt.getCode(created)).len);
}

test "eth_call create uses sender nonce for collision checks" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const sender = try parseAddress(DEFAULT_ACCOUNT);
    try rt.setNonce(sender, 7);
    const collision = try primitives.Address.getContractAddress(std.testing.allocator, sender, 7);
    try rt.setCode(collision, &RETURN_32_BYTE_42);

    var parsed = try parseJson(
        \\[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":null,"data":"0x602a60005260206000f3","gas":"0x100000"},"latest"]
    );
    defer parsed.deinit();

    try std.testing.expectError(error.ExecutionFailed, simulation.handleEthCall(std.testing.allocator, &rt, parsed.value));
    try std.testing.expectEqual(@as(u64, 7), try rt.getNonce(sender));
    try std.testing.expectEqual(@as(usize, RETURN_32_BYTE_42.len), (try rt.getCode(collision)).len);
}

test "eth_call revert reports execution failure without mutating state" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const target = try parseAddress(TARGET);
    try rt.setCode(target, &SSTORE_THEN_REVERT_42);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","data":"0x"},"latest"]
    );
    defer parsed.deinit();

    try std.testing.expectError(error.ExecutionFailed, simulation.handleEthCall(std.testing.allocator, &rt, parsed.value));
    try std.testing.expectEqual(@as(u256, 0), try rt.getStorage(target, 0));
}

test "eth_estimateGas returns a quantity" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var parsed = try parseJson(
        \\[{"from":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8"}]
    );
    defer parsed.deinit();

    const result = try simulation.handleEthEstimateGas(std.testing.allocator, &rt, parsed.value);
    defer std.testing.allocator.free(result.string);

    try std.testing.expectEqualStrings("0x5208", result.string);
}

test "eth_estimateGas estimates create flows" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var parsed = try parseJson(
        \\[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":null,"data":"0x602a60005260206000f3","gas":"0x100000"}]
    );
    defer parsed.deinit();

    const result = try simulation.handleEthEstimateGas(std.testing.allocator, &rt, parsed.value);
    defer std.testing.allocator.free(result.string);

    try std.testing.expect(result.string.len > 2);
    const estimated = try std.fmt.parseInt(u64, result.string[2..], 16);
    try std.testing.expect(estimated > 53_000);
    try std.testing.expect(estimated <= 0x100000);
}

test "eth_estimateGas uses runtime hardfork policy for create intrinsic gas" {
    var default_rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer default_rt.deinit();

    var pre_shanghai_rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .hardfork_config = .{
            .homestead_block = 0,
            .dao_block = 0,
            .tangerine_whistle_block = 0,
            .spurious_dragon_block = 0,
            .byzantium_block = 0,
            .petersburg_block = 0,
            .istanbul_block = 0,
            .muir_glacier_block = 0,
            .berlin_block = 0,
            .london_block = 0,
            .arrow_glacier_block = 0,
            .gray_glacier_block = 0,
            .merge_block = 0,
            .shanghai_timestamp = std.math.maxInt(u64),
            .cancun_timestamp = std.math.maxInt(u64),
            .prague_timestamp = std.math.maxInt(u64),
            .osaka_timestamp = std.math.maxInt(u64),
        },
    });
    defer pre_shanghai_rt.deinit();

    var default_params = try parseJson(
        \\[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":null,"data":"0x00","gas":"0x100000"}]
    );
    defer default_params.deinit();
    const default_result = try simulation.handleEthEstimateGas(std.testing.allocator, &default_rt, default_params.value);
    defer std.testing.allocator.free(default_result.string);

    var custom_params = try parseJson(
        \\[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":null,"data":"0x00","gas":"0x100000"}]
    );
    defer custom_params.deinit();
    const custom_result = try simulation.handleEthEstimateGas(std.testing.allocator, &pre_shanghai_rt, custom_params.value);
    defer std.testing.allocator.free(custom_result.string);

    const default_estimate = try std.fmt.parseInt(u64, default_result.string[2..], 16);
    const custom_estimate = try std.fmt.parseInt(u64, custom_result.string[2..], 16);
    try std.testing.expectEqual(custom_estimate + 2, default_estimate);
}

test "eth_estimateGas rejects reverting execution without mutating state" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const target = try parseAddress(TARGET);
    try rt.setCode(target, &SSTORE_THEN_REVERT_42);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","gas":"0x186a0"}]
    );
    defer parsed.deinit();

    try std.testing.expectError(error.ExecutionFailed, simulation.handleEthEstimateGas(std.testing.allocator, &rt, parsed.value));
    try std.testing.expectEqual(@as(u256, 0), try rt.getStorage(target, 0));
}

test "eth_call uses mined runtime timestamp" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.setNextBlockTimestamp(1234);
    try rt.mineBlocks(1, 0);

    const target = try parseAddress(TARGET);
    try rt.setCode(target, &RETURN_TIMESTAMP);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001"},"latest"]
    );
    defer parsed.deinit();

    try expectCallResultU256(&rt, parsed.value, 1234);
}

test "eth_call blockhash uses parent history for latest block context" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const genesis_block = (try rt.blockchain.getBlockByNumber(0)).?;
    try rt.mineBlocks(1, 0);

    const target = try parseAddress(TARGET);
    try rt.setCode(target, &RETURN_BLOCKHASH_ZERO);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001"},"latest"]
    );
    defer parsed.deinit();

    const result = try simulation.handleEthCall(std.testing.allocator, &rt, parsed.value);
    defer std.testing.allocator.free(result.string);

    const genesis_hash_hex = std.fmt.bytesToHex(genesis_block.hash, .lower);
    var expected: [66]u8 = undefined;
    expected[0] = '0';
    expected[1] = 'x';
    @memcpy(expected[2..], &genesis_hash_hex);
    try std.testing.expectEqualStrings(&expected, result.string);
}

test "eth_call uses runtime gas limit override" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.dev_runtime.config.block_gas_limit = 12_345_678;

    const target = try parseAddress(TARGET);
    try rt.setCode(target, &RETURN_GAS_LIMIT);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001"},"latest"]
    );
    defer parsed.deinit();

    try expectCallResultU256(&rt, parsed.value, 12_345_678);
}

test "eth_call uses runtime base fee override" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.dev_runtime.config.next_block_base_fee_per_gas = 42;

    const target = try parseAddress(TARGET);
    try rt.setCode(target, &RETURN_BASE_FEE);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001"},"latest"]
    );
    defer parsed.deinit();

    try expectCallResultU256(&rt, parsed.value, 42);
}

test "eth_call rejects non-head selector instead of using current state" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.mineBlocks(1, 0);

    const target = try parseAddress(TARGET);
    try rt.setCode(target, &RETURN_32_BYTE_42);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001"},"0x0"]
    );
    defer parsed.deinit();

    try std.testing.expectError(error.InvalidParams, simulation.handleEthCall(std.testing.allocator, &rt, parsed.value));
}

test "eth_estimateGas rejects non-head selector instead of using current state" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.mineBlocks(1, 0);

    var parsed = try parseJson(
        \\[{"from":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8"},"0x0"]
    );
    defer parsed.deinit();

    try std.testing.expectError(error.InvalidParams, simulation.handleEthEstimateGas(std.testing.allocator, &rt, parsed.value));
}

test "eth_estimateGas defaults to runtime gas limit" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.dev_runtime.config.block_gas_limit = 21_000;

    var parsed = try parseJson(
        \\[{"from":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8"}]
    );
    defer parsed.deinit();

    const result = try simulation.handleEthEstimateGas(std.testing.allocator, &rt, parsed.value);
    defer std.testing.allocator.free(result.string);

    try std.testing.expectEqualStrings("0x5208", result.string);
}

test "simulation rejects unsupported transaction request fields" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","maxFeePerGas":"0x1"},"latest"]
    );
    defer parsed.deinit();

    try std.testing.expectError(error.InvalidParams, simulation.handleEthCall(std.testing.allocator, &rt, parsed.value));
}

test "dispatch wiring reaches simulation handlers" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const target = try parseAddress(TARGET);
    try rt.setCode(target, &RETURN_32_BYTE_42);

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001"},"latest"]
    );
    defer parsed.deinit();

    var request = try makeRequest("eth_call", parsed.value);
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    try std.testing.expect(response.result != null);
    try std.testing.expectEqualStrings(EXPECTED_32_BYTE_42, response.result.?.string);
}

test "light mode estimateGas is mode unsupported for well-formed tx-only tuple" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .mode = .light,
        .light = .{
            .consensus_rpc_url = "http://localhost",
            .checkpoint = [_]u8{0x11} ** 32,
        },
    });
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var parsed = try parseJson(
        \\[{"from":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"}]
    );
    defer parsed.deinit();

    var request = try makeRequest("eth_estimateGas", parsed.value);
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(@as(i32, -32010), response.error_value.?.code);
}

fn parseJson(bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{
        .allocate = .alloc_always,
    });
}

fn expectCallResultU256(rt: *runtime.NodeRuntime, params: std.json.Value, expected: u256) !void {
    const result = try simulation.handleEthCall(std.testing.allocator, rt, params);
    defer std.testing.allocator.free(result.string);

    try std.testing.expect(result.string.len >= 2);
    try std.testing.expectEqualStrings("0x", result.string[0..2]);
    const actual = try std.fmt.parseInt(u256, result.string[2..], 16);
    try std.testing.expectEqual(expected, actual);
}

fn makeRequest(method: []const u8, params: ?std.json.Value) !jsonrpc.envelope.RequestEnvelope {
    return .{
        .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
        .id = .{ .integer = 1 },
        .method = try std.testing.allocator.dupe(u8, method),
        .params = params,
    };
}

fn parseAddress(text: []const u8) !primitives.Address {
    if (text.len != 42 or text[0] != '0' or text[1] != 'x') return error.InvalidAddress;
    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text[2..]) catch return error.InvalidAddress;
    return .{ .bytes = bytes };
}
