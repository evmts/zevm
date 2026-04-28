const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const runtime = @import("../../node/runtime.zig");
const dispatcher = @import("../dispatcher.zig");
const dispatch_wiring = @import("../dispatch_wiring.zig");
const simulation = @import("simulation.zig");

const RETURN_32_BYTE_42 = [_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
const SSTORE_THEN_RETURN_42 = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
const TARGET = "0x1000000000000000000000000000000000000001";
const EXPECTED_32_BYTE_42 = "0x000000000000000000000000000000000000000000000000000000000000002a";

test "simulation exports mode unsupported error tuple" {
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

fn parseJson(bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{
        .allocate = .alloc_always,
    });
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
