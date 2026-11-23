const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const runtime = @import("../../node/runtime.zig");
const hardfork_schedule = @import("../../hardfork_schedule.zig");
const tx_processor = @import("../../tx_processor.zig");
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

test "decodeRevertReason rejects overflowing attacker-controlled offset without panicking" {
    const selector = [_]u8{ 0x08, 0xc3, 0x79, 0xa0 };

    // offset word set to maxInt(u64): on a 64-bit target this previously passed the
    // `offset > maxInt(usize)` guard and overflowed `4 + offset`.
    var output: [4 + 32 + 32]u8 = undefined;
    @memcpy(output[0..4], &selector);
    @memset(output[4..], 0);
    // big-endian offset word lives at output[4..36]; set the low 8 bytes to 0xff..ff.
    @memset(output[28..36], 0xff);
    @memset(output[36..68], 0);
    try std.testing.expect(simulation.decodeRevertReason(&output) == null);

    // offset word set to full maxInt(u256): must also be rejected via std.math.cast.
    @memset(output[4..36], 0xff);
    try std.testing.expect(simulation.decodeRevertReason(&output) == null);

    // length word set to maxInt(u64) with a valid offset: reason_start + reason_len overflows.
    @memset(output[4..36], 0);
    output[35] = 0x20; // offset = 32 -> length word at output[36..68]
    @memset(output[36..68], 0);
    @memset(output[60..68], 0xff);
    try std.testing.expect(simulation.decodeRevertReason(&output) == null);
}

test "decodeRevertReason decodes a well-formed Error(string) payload" {
    // selector + offset(0x20) + length(5) + "hello" padded to 32 bytes
    const reason = "hello";
    var output: [4 + 32 + 32 + 32]u8 = undefined;
    @memset(&output, 0);
    output[0] = 0x08;
    output[1] = 0xc3;
    output[2] = 0x79;
    output[3] = 0xa0;
    output[35] = 0x20; // offset = 32
    output[67] = reason.len; // length = 5
    @memcpy(output[68 .. 68 + reason.len], reason);
    const decoded = simulation.decodeRevertReason(&output) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(reason, decoded);
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

    try std.testing.expectEqualStrings(EXPECTED_32_BYTE_42, result.string);
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

    var pre_shanghai_cfg = runtime.DEFAULT_DEV_HARDFORK_CONFIG;
    pre_shanghai_cfg.shanghai_timestamp = std.math.maxInt(u64);
    pre_shanghai_cfg.cancun_timestamp = std.math.maxInt(u64);
    var pre_shanghai_rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .hardfork_config = pre_shanghai_cfg,
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
        \\[{"to":"0x1000000000000000000000000000000000000001","gasPrice":"0x1"},"latest"]
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
        \\[{"to":"0x1000000000000000000000000000000000000001","unsupported":"0x1"},"latest"]
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

// GAS PUSH4 20_000_000 LT PUSH1 0x0d JUMPI PUSH0 PUSH0 REVERT JUMPDEST STOP:
// succeeds only when more than 20M gas remains at entry.
const REQUIRES_OVER_20M_GAS = [_]u8{ 0x5a, 0x63, 0x01, 0x31, 0x2d, 0x00, 0x10, 0x60, 0x0d, 0x57, 0x5f, 0x5f, 0xfd, 0x5b, 0x00 };

test "EIP-7825 eth_estimateGas never returns an estimate above the Osaka transaction cap" {
    const target = try parseAddress(TARGET);

    // Prague has no transaction cap: the estimate may exceed 2^24.
    var prague_cfg = runtime.DEFAULT_DEV_HARDFORK_CONFIG;
    prague_cfg.prague_timestamp = 0;
    var prague_rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .hardfork_config = prague_cfg,
    });
    defer prague_rt.deinit();
    try prague_rt.setCode(target, &REQUIRES_OVER_20M_GAS);
    var prague_params = try parseJson(
        \\[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":"0x1000000000000000000000000000000000000001"}]
    );
    defer prague_params.deinit();
    const prague_result = try simulation.handleEthEstimateGas(std.testing.allocator, &prague_rt, prague_params.value);
    defer std.testing.allocator.free(prague_result.string);
    const prague_estimate = try std.fmt.parseInt(u64, prague_result.string[2..], 16);
    try std.testing.expect(prague_estimate > 20_000_000);
    try std.testing.expect(prague_estimate <= 30_000_000);

    // Osaka: the same call cannot fit any valid transaction, with or without
    // an explicit gas above the cap.
    var osaka_cfg = runtime.DEFAULT_DEV_HARDFORK_CONFIG;
    osaka_cfg.prague_timestamp = 0;
    osaka_cfg.osaka_timestamp = 0;
    var osaka_rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .hardfork_config = osaka_cfg,
    });
    defer osaka_rt.deinit();
    try osaka_rt.setCode(target, &REQUIRES_OVER_20M_GAS);
    for ([_][]const u8{
        \\[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":"0x1000000000000000000000000000000000000001"}]
        ,
        \\[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":"0x1000000000000000000000000000000000000001","gas":"0x1c9c380"}]
        ,
    }) |request| {
        var params = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request, .{});
        defer params.deinit();
        try std.testing.expectError(error.ExecutionFailed, simulation.handleEthEstimateGas(std.testing.allocator, &osaka_rt, params.value));
    }

    // An ordinary Osaka estimate is unchanged, and eth_call may still run
    // with the full block gas limit.
    var transfer_params = try parseJson(
        \\[{"from":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8"}]
    );
    defer transfer_params.deinit();
    const transfer = try simulation.handleEthEstimateGas(std.testing.allocator, &osaka_rt, transfer_params.value);
    defer std.testing.allocator.free(transfer.string);
    try std.testing.expectEqualStrings("0x5208", transfer.string);

    var call_params = try parseJson(
        \\[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":"0x1000000000000000000000000000000000000001"},"latest"]
    );
    defer call_params.deinit();
    const call_result = try simulation.handleEthCall(std.testing.allocator, &osaka_rt, call_params.value);
    defer std.testing.allocator.free(call_result.string);
    try std.testing.expectEqualStrings("0x", call_result.string);
}

test "EIP-7951 P256VERIFY eth_call, eth_estimateGas, OOG boundary, and mainnet Osaka mining at 1764798551" {
    const allocator = std.testing.allocator;
    const osaka_ts = hardfork_schedule.MAINNET_CHAIN_CONFIG.osaka_timestamp;
    try std.testing.expectEqual(@as(u64, 1_764_798_551), osaka_ts);

    var rt = try runtime.NodeRuntime.init(allocator, .{ .chain_id = 1 });
    defer rt.deinit();

    const p256_valid_hex = "4cee90eb86eaa050036147a12d49004b6b9c72bd725d39d4785011fe190f0b4d" ++
        "a73bd4903f0ce3b639bbbf6e8e80d16931ff4bcf5993d58468e8fb19086e8cac" ++
        "36dbcd03009df8c59286b162af3bd7fcc0450c9aa81be5d10d312af6c66b1d60" ++
        "4aebd3099c618202fcfe16ae7770b0c49ab5eadf74b754204a3bb6060e44eff3" ++
        "7618b065f9832de4ca6ca971a7a1adc826d0f7c00181a5fb2ddf79ae00b4e10e";
    var valid_bytes: [160]u8 = undefined;
    _ = try std.fmt.hexToBytes(&valid_bytes, p256_valid_hex);

    const p256_n: u256 = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    var high_s_bytes = valid_bytes;
    const orig_s = std.mem.readInt(u256, valid_bytes[64..96], .big);
    std.mem.writeInt(u256, high_s_bytes[64..96], p256_n - orig_s, .big);
    const high_s_hex = std.fmt.bytesToHex(high_s_bytes, .lower);

    var bad_sig_bytes = valid_bytes;
    bad_sig_bytes[0] ^= 0x01;
    const bad_sig_hex = std.fmt.bytesToHex(bad_sig_bytes, .lower);

    var infinity_bytes = valid_bytes;
    @memset(infinity_bytes[96..160], 0);
    const infinity_hex = std.fmt.bytesToHex(infinity_bytes, .lower);

    const expected_one = "0x0000000000000000000000000000000000000000000000000000000000000001";
    const p256_intrinsic = tx_processor.intrinsicGasForFork(&valid_bytes, false, .OSAKA);

    // Block 1 at osaka_timestamp - 1 (1764798550, Prague): mines cleanly and P256VERIFY is inactive.
    rt.setNextBlockTimestamp(osaka_ts - 1);
    try rt.mineBlocks(1, 12);
    try std.testing.expectEqual(@as(u64, 1), rt.head_block_number);
    try std.testing.expectEqual(osaka_ts - 1, rt.head_block_timestamp);

    {
        const req_json = try std.fmt.allocPrint(
            allocator,
            "[{{\"to\":\"0x0000000000000000000000000000000000000100\",\"data\":\"0x{s}\"}},\"latest\"]",
            .{p256_valid_hex},
        );
        defer allocator.free(req_json);
        var params = try parseJson(req_json);
        defer params.deinit();

        const pre_osaka = try simulation.handleEthCall(allocator, &rt, params.value);
        defer allocator.free(pre_osaka.string);
        try std.testing.expectEqualStrings("0x", pre_osaka.string);

        const pre_gas = try simulation.handleEthEstimateGas(allocator, &rt, params.value);
        defer allocator.free(pre_gas.string);
        const pre_estimate = try std.fmt.parseInt(u64, pre_gas.string[2..], 16);
        const expected_pre_osaka_gas = @max(p256_intrinsic, try tx_processor.transactionGasFloorForFork(&valid_bytes, .PRAGUE));
        try std.testing.expectEqual(expected_pre_osaka_gas, pre_estimate);
    }

    // Block 2 at osaka_timestamp (1764798551, Osaka): mines cleanly and activates EIP-7951 P256VERIFY.
    const block1 = (try rt.blockchain.getBlockByNumber(1)).?;
    rt.setNextBlockTimestamp(osaka_ts);
    try rt.mineBlocks(1, 12);
    try std.testing.expectEqual(@as(u64, 2), rt.head_block_number);
    try std.testing.expectEqual(osaka_ts, rt.head_block_timestamp);

    // Valid signature and high-s malleated signature both return 32-byte 1.
    for ([_][]const u8{ p256_valid_hex, &high_s_hex }) |payload_hex| {
        const req_json = try std.fmt.allocPrint(
            allocator,
            "[{{\"to\":\"0x0000000000000000000000000000000000000100\",\"data\":\"0x{s}\"}},\"latest\"]",
            .{payload_hex},
        );
        defer allocator.free(req_json);
        var params = try parseJson(req_json);
        defer params.deinit();

        const res = try simulation.handleEthCall(allocator, &rt, params.value);
        defer allocator.free(res.string);
        try std.testing.expectEqualStrings(expected_one, res.string);
    }

    // Invalid signature, point at infinity, and wrong input length return empty bytes ("0x") without revert.
    for ([_][]const u8{ &bad_sig_hex, &infinity_hex, "1234", "" }) |bad_hex| {
        const req_json = try std.fmt.allocPrint(
            allocator,
            "[{{\"to\":\"0x0000000000000000000000000000000000000100\",\"data\":\"0x{s}\"}},\"latest\"]",
            .{bad_hex},
        );
        defer allocator.free(req_json);
        var params = try parseJson(req_json);
        defer params.deinit();

        const res = try simulation.handleEthCall(allocator, &rt, params.value);
        defer allocator.free(res.string);
        try std.testing.expectEqualStrings("0x", res.string);
    }

    // Exact gas boundary: intrinsic + 6899 fails with ExecutionFailed (OutOfGas), intrinsic + 6900 succeeds.
    {
        const oog_json = try std.fmt.allocPrint(
            allocator,
            "[{{\"to\":\"0x0000000000000000000000000000000000000100\",\"gas\":\"0x{x}\",\"data\":\"0x{s}\"}},\"latest\"]",
            .{ p256_intrinsic + 6899, p256_valid_hex },
        );
        defer allocator.free(oog_json);
        var oog_params = try parseJson(oog_json);
        defer oog_params.deinit();
        try std.testing.expectError(error.ExecutionFailed, simulation.handleEthCall(allocator, &rt, oog_params.value));

        const exact_json = try std.fmt.allocPrint(
            allocator,
            "[{{\"to\":\"0x0000000000000000000000000000000000000100\",\"gas\":\"0x{x}\",\"data\":\"0x{s}\"}},\"latest\"]",
            .{ p256_intrinsic + 6900, p256_valid_hex },
        );
        defer allocator.free(exact_json);
        var exact_params = try parseJson(exact_json);
        defer exact_params.deinit();
        const exact_res = try simulation.handleEthCall(allocator, &rt, exact_params.value);
        defer allocator.free(exact_res.string);
        try std.testing.expectEqualStrings(expected_one, exact_res.string);
    }

    // EIP-2935 canonical history contract serves block 1's canonical hash via eth_call.
    {
        var block1_num_word: [32]u8 = [_]u8{0} ** 32;
        block1_num_word[31] = 1;
        const word_hex = std.fmt.bytesToHex(block1_num_word, .lower);
        const req_json = try std.fmt.allocPrint(
            allocator,
            "[{{\"to\":\"0x0000f90827f1c53a10cb7a02335b175320002935\",\"data\":\"0x{s}\"}},\"latest\"]",
            .{&word_hex},
        );
        defer allocator.free(req_json);
        var params = try parseJson(req_json);
        defer params.deinit();

        const res = try simulation.handleEthCall(allocator, &rt, params.value);
        defer allocator.free(res.string);
        const expected_hash_hex = try std.fmt.allocPrint(allocator, "0x{s}", .{&std.fmt.bytesToHex(block1.hash, .lower)});
        defer allocator.free(expected_hash_hex);
        try std.testing.expectEqualStrings(expected_hash_hex, res.string);
    }

    // EIP-7002 canonical withdrawal requests contract returns min fee (1 wei) on empty calldata.
    {
        var params = try parseJson(
            \\[{"to":"0x00000961ef480eb55e80d19ad83579a64c007002","data":"0x"},"latest"]
        );
        defer params.deinit();
        const res = try simulation.handleEthCall(allocator, &rt, params.value);
        defer allocator.free(res.string);
        try std.testing.expectEqualStrings(expected_one, res.string);
    }
}

// PUSH1 0 SLOAD PUSH1 0 MSTORE PUSH1 0x20 PUSH1 0 RETURN: returns storage slot 0.
const RETURN_SLOT_ZERO = [_]u8{ 0x60, 0x00, 0x54, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };

test "eth_call frees a partially parsed access list when a later entry is malformed" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    // Each request parses at least one valid entry, with storage keys, before
    // the malformed entry. The error path previously freed the uninitialized
    // tail of the access-list allocation.
    const malformed = [_][]const u8{
        \\[{"to":"0x1000000000000000000000000000000000000001","accessList":[{"address":"0x1000000000000000000000000000000000000001","storageKeys":["0x0000000000000000000000000000000000000000000000000000000000000001"]},{"address":"0x12","storageKeys":[]},{"address":"0x1000000000000000000000000000000000000001","storageKeys":[]}]},"latest"]
        ,
        \\[{"to":"0x1000000000000000000000000000000000000001","accessList":[{"address":"0x1000000000000000000000000000000000000001","storageKeys":["0x0000000000000000000000000000000000000000000000000000000000000001"]},{"address":"0x1000000000000000000000000000000000000001"}]},"latest"]
        ,
        \\[{"to":"0x1000000000000000000000000000000000000001","accessList":[{"address":"0x1000000000000000000000000000000000000001","storageKeys":[]},{"address":"0x1000000000000000000000000000000000000001","storageKeys":["0x0000000000000000000000000000000000000000000000000000000000000001","0xzz"]},7]},"latest"]
        ,
        \\[{"to":"0x1000000000000000000000000000000000000001","accessList":[7]},"latest"]
        ,
    };
    for (malformed) |request| {
        var parsed = try parseJson(request);
        defer parsed.deinit();
        try std.testing.expectError(
            error.InvalidParams,
            simulation.handleEthCall(std.testing.allocator, &rt, parsed.value),
        );
    }

    // A well-formed access list still executes.
    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","accessList":[{"address":"0x1000000000000000000000000000000000000001","storageKeys":["0x0000000000000000000000000000000000000000000000000000000000000001"]}]},"latest"]
    );
    defer parsed.deinit();
    const result = try simulation.handleEthCall(std.testing.allocator, &rt, parsed.value);
    defer std.testing.allocator.free(result.string);
    try std.testing.expectEqualStrings("0x", result.string);
}

test "eth_call state override replaces storage inside the call without wiping live storage" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const target = try parseAddress(TARGET);
    try rt.setCode(target, &RETURN_SLOT_ZERO);
    try rt.setStorage(target, 0, 0x11);
    try rt.setStorage(target, 1, 0x22);

    // `state` replaces the whole storage: slot 0 reads as 0 inside the call.
    var with_state = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001"},"latest",{"0x1000000000000000000000000000000000000001":{"state":{"0x0000000000000000000000000000000000000000000000000000000000000001":"0x0000000000000000000000000000000000000000000000000000000000000033"}}}]
    );
    defer with_state.deinit();
    try expectCallResultU256(&rt, with_state.value, 0);

    // The live contract keeps every slot.
    try std.testing.expectEqual(@as(u256, 0x11), try rt.getStorage(target, 0));
    try std.testing.expectEqual(@as(u256, 0x22), try rt.getStorage(target, 1));

    // `stateDiff` patches one slot and leaves slot 0 readable.
    var with_diff = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001"},"latest",{"0x1000000000000000000000000000000000000001":{"stateDiff":{"0x0000000000000000000000000000000000000000000000000000000000000001":"0x0000000000000000000000000000000000000000000000000000000000000033"}}}]
    );
    defer with_diff.deinit();
    try expectCallResultU256(&rt, with_diff.value, 0x11);

    // A call without overrides and eth_estimateGas with `state` see and keep live storage.
    var plain = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001"},"latest"]
    );
    defer plain.deinit();
    try expectCallResultU256(&rt, plain.value, 0x11);

    var estimate = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001"},"latest",{"0x1000000000000000000000000000000000000001":{"state":{}}}]
    );
    defer estimate.deinit();
    const estimated = try simulation.handleEthEstimateGas(std.testing.allocator, &rt, estimate.value);
    defer std.testing.allocator.free(estimated.string);
    try std.testing.expectEqual(@as(u256, 0x11), try rt.getStorage(target, 0));
    try std.testing.expectEqual(@as(u256, 0x22), try rt.getStorage(target, 1));
}

fn expectSimulateRpcError(rt: *runtime.NodeRuntime, request: []const u8, expected_code: i32) !void {
    var parsed = try parseJson(request);
    defer parsed.deinit();
    try std.testing.expectError(
        error.SimulationRpcError,
        simulation.handleEthSimulateV1(std.testing.allocator, rt, parsed.value),
    );
    const rpc_error = simulation.takeLastSimulationRpcError() orelse return error.MissingSimulationRpcError;
    try std.testing.expectEqual(expected_code, rpc_error.code);
}

test "eth_simulateV1 rejects a huge block number instead of synthesizing gap blocks" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    const head_before = rt.head_block_number;

    try expectSimulateRpcError(&rt,
        \\[{"blockStateCalls":[{"blockOverrides":{"number":"0xffffffffffffffff"}}]},"latest"]
    , -38026);
    // 257 blocks: 256 gap blocks plus the requested block.
    try expectSimulateRpcError(&rt,
        \\[{"blockStateCalls":[{"blockOverrides":{"number":"0x101"}}]},"latest"]
    , -38026);
    try std.testing.expectEqual(head_before, rt.head_block_number);
}

test "eth_simulateV1 fills a small block number gap with empty blocks" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);

    var parsed = try parseJson(
        \\[{"blockStateCalls":[{"blockOverrides":{"number":"0x3"}}]},"latest"]
    );
    defer parsed.deinit();
    const result = try simulation.handleEthSimulateV1(arena.allocator(), &rt, parsed.value);
    // Head is block 0: blocks 1 and 2 fill the gap, block 3 is the request.
    try std.testing.expectEqual(@as(usize, 3), result.array.items.len);
    try std.testing.expectEqualStrings("0x3", result.array.items[2].object.get("number").?.string);
}

test "eth_simulateV1 rejects a mismatched chainId and an overflowing legacy chainId" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    // chainId * 2 + 35 overflows u64 for this value; the request must fail cleanly.
    try expectSimulateRpcError(&rt,
        \\[{"blockStateCalls":[{"calls":[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":"0x70997970c51812dc3a010c7d01b50e0d17dc79c8","type":"0x0","chainId":"0xffffffffffffffff"}]}]},"latest"]
    , -32000);
    try expectSimulateRpcError(&rt,
        \\[{"blockStateCalls":[{"calls":[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":"0x70997970c51812dc3a010c7d01b50e0d17dc79c8","chainId":"0x2"}]}]},"latest"]
    , -32000);

    // When the node's own chain ID is that large, the EIP-155 `v` computation
    // is the overflow site. It must return an error, not panic.
    rt.chain_id = std.math.maxInt(u64);
    var parsed = try parseJson(
        \\[{"blockStateCalls":[{"calls":[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":"0x70997970c51812dc3a010c7d01b50e0d17dc79c8","type":"0x0","chainId":"0xffffffffffffffff"}]}]},"latest"]
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.InvalidParams,
        simulation.handleEthSimulateV1(std.testing.allocator, &rt, parsed.value),
    );
}

test "eth_simulateV1 caps a call's gas at the request gas budget despite a raised block gas limit" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Block gas limit 100M and call gas 100M; the request budget is 50M.
    var parsed = try parseJson(
        \\[{"returnFullTransactions":true,"blockStateCalls":[{"blockOverrides":{"gasLimit":"0x5f5e100"},"calls":[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":"0x70997970c51812dc3a010c7d01b50e0d17dc79c8","gas":"0x5f5e100"}]}]},"latest"]
    );
    defer parsed.deinit();
    const result = try simulation.handleEthSimulateV1(arena.allocator(), &rt, parsed.value);
    const block = result.array.items[0].object;
    const tx = block.get("transactions").?.array.items[0].object;
    try std.testing.expectEqualStrings("0x2faf080", tx.get("gas").?.string);
}

test "debug_traceCall accepts disableStorage=false" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try rt.setCode(try parseAddress(TARGET), &RETURN_32_BYTE_42);
    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001"},"latest",{"disableStorage":false}]
    );
    defer parsed.deinit();
    const result = try simulation.handleDebugTraceCall(arena.allocator(), &rt, parsed.value);
    try std.testing.expect(result.object.get("structLogs").?.array.items.len > 0);
}

test "debug_traceCall fails a trace that exceeds the memory budget" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    // PUSH1 1 PUSH3 0x100000 MSTORE JUMPDEST PUSH1 7 JUMP: expands memory to
    // 1 MiB, then loops until out of gas. With enableMemory, each traced step
    // copies the whole memory, so the trace passes 32 MiB within ~32 steps.
    const one_mib_memory_loop = [_]u8{ 0x60, 0x01, 0x62, 0x10, 0x00, 0x00, 0x52, 0x5b, 0x60, 0x07, 0x56 };
    try rt.setCode(try parseAddress(TARGET), &one_mib_memory_loop);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","gas":"0x989680"},"latest",{"enableMemory":true}]
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.SimulationRpcError,
        simulation.handleDebugTraceCall(std.testing.allocator, &rt, parsed.value),
    );
    const rpc_error = simulation.takeLastSimulationRpcError() orelse return error.MissingSimulationRpcError;
    try std.testing.expectEqual(@as(i32, -32000), rpc_error.code);
}

// --- Round 2 simulation regressions ---

// Returns GASPRICE - BASEFEE, the priority fee the call effectively pays.
const RETURN_GAS_PRICE_MINUS_BASE_FEE = [_]u8{ 0x48, 0x3a, 0x03, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
// Returns the gas consumed by PUSH1 0, SLOAD, POP, GAS: 2107 cold, 107 warm.
const RETURN_SLOAD_GAS = [_]u8{ 0x5a, 0x60, 0x00, 0x54, 0x50, 0x5a, 0x90, 0x03, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };

test "eth_call rejects a state override naming both state and stateDiff" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.setCode(try parseAddress(TARGET), &RETURN_32_BYTE_42);

    var both = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","data":"0x"},"latest",
        \\ {"0x1000000000000000000000000000000000000001":{"state":{},"stateDiff":{}}}]
    );
    defer both.deinit();
    try std.testing.expectError(error.InvalidParams, simulation.handleEthCall(std.testing.allocator, &rt, both.value));

    var only_state = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","data":"0x"},"latest",
        \\ {"0x1000000000000000000000000000000000000001":{"state":{}}}]
    );
    defer only_state.deinit();
    try expectCallResultU256(&rt, only_state.value, 0x2a);
}

test "eth_call reports the EIP-1559 effective gas price to GASPRICE" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.setCode(try parseAddress(TARGET), &RETURN_GAS_PRICE_MINUS_BASE_FEE);

    // min(maxFeePerGas, baseFee + tip) = baseFee + 2 under a large fee cap.
    var capped_by_tip = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","data":"0x",
        \\  "maxFeePerGas":"0xffffffffffffffffffff","maxPriorityFeePerGas":"0x2"},"latest"]
    );
    defer capped_by_tip.deinit();
    try expectCallResultU256(&rt, capped_by_tip.value, 2);
}

test "eth_call warms the request access list" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.setCode(try parseAddress(TARGET), &RETURN_SLOAD_GAS);

    var cold = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","data":"0x"},"latest"]
    );
    defer cold.deinit();
    try expectCallResultU256(&rt, cold.value, 2107);

    var warm = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","data":"0x","accessList":[
        \\  {"address":"0x1000000000000000000000000000000000000001",
        \\   "storageKeys":["0x0000000000000000000000000000000000000000000000000000000000000000"]}]},"latest"]
    );
    defer warm.deinit();
    try expectCallResultU256(&rt, warm.value, 107);
}

test "eth_estimateGas success leaves no stale thread-local error" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.setCode(try parseAddress(TARGET), &SSTORE_THEN_RETURN_42);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","data":"0x"}]
    );
    defer parsed.deinit();

    // The binary search probes gas limits that run out of gas. Those failed
    // probes must not leave an error behind once the estimate succeeds.
    const estimate = try simulation.handleEthEstimateGas(std.testing.allocator, &rt, parsed.value);
    defer std.testing.allocator.free(estimate.string);
    try std.testing.expect(simulation.takeLastSimulationRpcError() == null);
    try std.testing.expect(simulation.takeLastExecutionErrorData() == null);
}

test "eth_call accepts a single-element params array without a block tag" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const target = try parseAddress(TARGET);
    try rt.setCode(target, &RETURN_32_BYTE_42);

    var parsed = try parseJson(
        \\[{"to":"0x1000000000000000000000000000000000000001","data":"0x"}]
    );
    defer parsed.deinit();

    const result = try simulation.handleEthCall(std.testing.allocator, &rt, parsed.value);
    defer std.testing.allocator.free(result.string);
    try std.testing.expectEqualStrings(EXPECTED_32_BYTE_42, result.string);
}

// PUSH1 0 SLOAD POP STOP: reads storage slot 0, discards result.
const SLOAD_SLOT_ZERO = [_]u8{ 0x60, 0x00, 0x54, 0x50, 0x00 };

test "eth_createAccessList returns the storage slot touched by SLOAD" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const target = try parseAddress(TARGET);
    try rt.setCode(target, &SLOAD_SLOT_ZERO);

    var parsed = try parseJson(
        \\[{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266","to":"0x1000000000000000000000000000000000000001"}]
    );
    defer parsed.deinit();

    const result = try simulation.handleEthCreateAccessList(std.testing.allocator, &rt, parsed.value);
    defer {
        var v = result;
        deinitJsonValue(std.testing.allocator, &v);
    }

    const obj = result.object;
    const access_list = obj.get("accessList").?.array;
    try std.testing.expect(access_list.items.len >= 1);
    var found_slot = false;
    for (access_list.items) |entry| {
        const keys = entry.object.get("storageKeys").?.array;
        for (keys.items) |key| {
            if (std.mem.eql(u8, key.string, "0x0000000000000000000000000000000000000000000000000000000000000000")) {
                found_slot = true;
            }
        }
    }
    try std.testing.expect(found_slot);
    try std.testing.expect(obj.get("gasUsed") != null);
    try std.testing.expect(obj.get("error") == null);
}

fn deinitJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string => |text| allocator.free(text),
        .array => |*array| {
            for (array.items) |*item| deinitJsonValue(allocator, item);
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
