const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const dev_erc20 = @import("dev_erc20.zig");
const dispatcher = @import("../dispatcher.zig");
const dispatch_wiring = @import("../dispatch_wiring.zig");
const runtime = @import("../../node/runtime.zig");

fn parseAddress(text: []const u8) !primitives.Address {
    if (text.len != 42) return error.InvalidAddress;
    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text[2..]) catch return error.InvalidAddress;
    return .{ .bytes = bytes };
}

fn parseU256Hex(text: []const u8) !u256 {
    return std.fmt.parseInt(u256, text[2..], 16);
}

fn makeRequest(method: []const u8, params: ?std.json.Value) !jsonrpc.envelope.RequestEnvelope {
    return .{
        .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
        .id = .{ .integer = 1 },
        .method = try std.testing.allocator.dupe(u8, method),
        .params = params,
    };
}

test "balanceSlot matches OpenZeppelin mapping slot 0" {
    const holder = try parseAddress("0x1111111111111111111111111111111111111111");
    const expected = try parseU256Hex("0xf043c50fe795c69f30b8ff78b84032dc53a9d87ca283ae10a1dacfbb648e83ef");

    try std.testing.expectEqual(expected, dev_erc20.balanceSlot(holder));
}

test "allowanceSlot matches OpenZeppelin nested mapping slot 1" {
    const owner = try parseAddress("0x2222222222222222222222222222222222222222");
    const spender = try parseAddress("0x3333333333333333333333333333333333333333");
    const expected = try parseU256Hex("0xe8ba05837b394842be077a23a8207f6d1ab5fd94dccb385dab44a83781123625");

    try std.testing.expectEqual(expected, dev_erc20.allowanceSlot(owner, spender));
}

test "handleSetERC20Balance writes holder balance storage" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const token_text = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const holder_text = "0x1111111111111111111111111111111111111111";
    const value: u256 = 0x1234;

    var args = std.json.Array.init(std.testing.allocator);
    defer args.deinit();
    try args.append(.{ .string = token_text });
    try args.append(.{ .string = holder_text });
    try args.append(.{ .string = "0x1234" });

    const result = try dev_erc20.handleSetERC20Balance(&rt, .{ .array = args });
    try std.testing.expect(result.bool);

    const token = try parseAddress(token_text);
    const holder = try parseAddress(holder_text);
    try std.testing.expectEqual(value, try rt.getStorage(token, dev_erc20.balanceSlot(holder)));
}

test "handleSetERC20Allowance writes owner spender allowance storage" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const token_text = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const owner_text = "0x2222222222222222222222222222222222222222";
    const spender_text = "0x3333333333333333333333333333333333333333";
    const value: u256 = 0x4567;

    var args = std.json.Array.init(std.testing.allocator);
    defer args.deinit();
    try args.append(.{ .string = token_text });
    try args.append(.{ .string = owner_text });
    try args.append(.{ .string = spender_text });
    try args.append(.{ .string = "0x4567" });

    const result = try dev_erc20.handleSetERC20Allowance(&rt, .{ .array = args });
    try std.testing.expect(result.bool);

    const token = try parseAddress(token_text);
    const owner = try parseAddress(owner_text);
    const spender = try parseAddress(spender_text);
    try std.testing.expectEqual(value, try rt.getStorage(token, dev_erc20.allowanceSlot(owner, spender)));
}

test "dispatch wiring accepts ERC20 balance and allowance aliases" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const token_text = "0xcccccccccccccccccccccccccccccccccccccccc";
    const holder_text = "0x1111111111111111111111111111111111111111";
    const owner_text = "0x2222222222222222222222222222222222222222";
    const spender_text = "0x3333333333333333333333333333333333333333";
    const token = try parseAddress(token_text);
    const holder = try parseAddress(holder_text);
    const owner = try parseAddress(owner_text);
    const spender = try parseAddress(spender_text);

    var balance_args = std.json.Array.init(std.testing.allocator);
    defer balance_args.deinit();
    try balance_args.append(.{ .string = token_text });
    try balance_args.append(.{ .string = holder_text });
    try balance_args.append(.{ .string = "0x55" });

    var balance_request = try makeRequest("hardhat_setERC20Balance", .{ .array = balance_args });
    defer balance_request.deinit(std.testing.allocator);

    var balance_response = try dispatcher.dispatch(std.testing.allocator, balance_request, &handlers);
    defer balance_response.deinit(std.testing.allocator);

    try std.testing.expect(balance_response.error_value == null);
    try std.testing.expect(balance_response.result.?.bool);
    try std.testing.expectEqual(@as(u256, 0x55), try rt.getStorage(token, dev_erc20.balanceSlot(holder)));

    var allowance_args = std.json.Array.init(std.testing.allocator);
    defer allowance_args.deinit();
    try allowance_args.append(.{ .string = token_text });
    try allowance_args.append(.{ .string = owner_text });
    try allowance_args.append(.{ .string = spender_text });
    try allowance_args.append(.{ .string = "0x66" });

    var allowance_request = try makeRequest("anvil_setERC20Allowance", .{ .array = allowance_args });
    defer allowance_request.deinit(std.testing.allocator);

    var allowance_response = try dispatcher.dispatch(std.testing.allocator, allowance_request, &handlers);
    defer allowance_response.deinit(std.testing.allocator);

    try std.testing.expect(allowance_response.error_value == null);
    try std.testing.expect(allowance_response.result.?.bool);
    try std.testing.expectEqual(@as(u256, 0x66), try rt.getStorage(token, dev_erc20.allowanceSlot(owner, spender)));
}
