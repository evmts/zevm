const std = @import("std");
const jsonrpc = @import("jsonrpc");
const dispatcher = @import("dispatcher.zig");
const dispatch_wiring = @import("dispatch_wiring.zig");
const runtime_mod = @import("../node/runtime.zig");

fn makeRequest(method: []const u8, params: ?std.json.Value) !jsonrpc.envelope.RequestEnvelope {
    return .{
        .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
        .id = .{ .integer = 1 },
        .method = try std.testing.allocator.dupe(u8, method),
        .params = params,
    };
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
