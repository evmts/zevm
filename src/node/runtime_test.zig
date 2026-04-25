const std = @import("std");
const runtime = @import("runtime.zig");
const mining = @import("../mining.zig");
const primitives = @import("primitives");

test "NodeRuntime.init uses deterministic defaults" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 31337), rt.chain_id);
    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[0], rt.coinbase);
}

test "NodeRuntime.init seeds dev account balances" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    for (&runtime.DEFAULT_DEV_ACCOUNTS) |addr| {
        const balance = try rt.state.getBalance(addr);
        try std.testing.expectEqual(runtime.DEFAULT_BALANCE, balance);
    }
}

test "NodeRuntime.init respects custom config" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .chain_id = 1,
        .coinbase_index = 2,
        .initial_balance = 42,
    });
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 1), rt.chain_id);
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[2], rt.coinbase);

    const balance = try rt.state.getBalance(runtime.DEFAULT_DEV_ACCOUNTS[0]);
    try std.testing.expectEqual(@as(u256, 42), balance);
}

test "NodeRuntime.init head block number starts at 0" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
}

test "NodeRuntime.deinit releases state" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    rt.deinit();
    // If allocator leaks, testing.allocator will detect it
}

test "NodeRuntime initializes with default auto mining config" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectEqual(mining.MiningConfigType.auto, std.meta.activeTag(rt.mining_config));
}

test "NodeRuntime setMiningConfig updates to interval" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.setMiningConfig(.{ .interval = .{ .block_time = 12 } });
    try std.testing.expectEqual(mining.MiningConfigType.interval, std.meta.activeTag(rt.mining_config));
    switch (rt.mining_config) {
        .interval => |iv| try std.testing.expectEqual(@as(u64, 12), iv.block_time),
        else => return error.TestUnexpectedResult,
    }
}

test "NodeRuntime setMiningConfig updates to manual" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.setMiningConfig(.manual);
    try std.testing.expectEqual(mining.MiningConfigType.manual, std.meta.activeTag(rt.mining_config));
}

test "NodeRuntime init respects custom mining config" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .mining_config = .{ .interval = .{ .block_time = 5 } },
    });
    defer rt.deinit();

    try std.testing.expectEqual(mining.MiningConfigType.interval, std.meta.activeTag(rt.mining_config));
}

const MockForkResolver = struct {
    url_a: []const u8,
    url_b: []const u8,
    balance_a: u256,
    balance_b: u256,
    nonce_a: u64,
    nonce_b: u64,
    storage_slot: u256,
    storage_a: u256,
    storage_b: u256,
    code_a: []const u8,
    code_b: []const u8,
    request_count: usize = 0,

    fn asResolver(self: *MockForkResolver) runtime.ForkRpcResolver {
        return .{
            .context = self,
            .resolve = &resolve,
        };
    }

    fn resolve(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: runtime.ForkRpcRequest,
    ) ![]u8 {
        const raw_context = context orelse return error.InvalidContext;
        const self: *MockForkResolver = @ptrCast(@alignCast(raw_context));
        self.request_count += 1;

        const use_b = std.mem.eql(u8, request.url, self.url_b);
        const balance = if (use_b) self.balance_b else self.balance_a;
        const nonce = if (use_b) self.nonce_b else self.nonce_a;
        const storage_value = if (use_b) self.storage_b else self.storage_a;
        const code_bytes = if (use_b) self.code_b else self.code_a;

        if (std.mem.eql(u8, request.method, "eth_getCode")) {
            const code_hex = try primitives.Hex.bytesToHex(allocator, code_bytes);
            defer allocator.free(code_hex);
            return try std.fmt.allocPrint(allocator, "\"{s}\"", .{code_hex});
        }

        if (!std.mem.eql(u8, request.method, "eth_getProof")) {
            return error.UnsupportedMethod;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.params_json, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const params = switch (parsed.value) {
            .array => |array| array.items,
            else => return error.InvalidParams,
        };

        var has_slot = false;
        if (params.len >= 2 and params[1] == .array) {
            has_slot = params[1].array.items.len > 0;
        }

        if (!has_slot) {
            return try std.fmt.allocPrint(
                allocator,
                "{{\"nonce\":\"0x{x}\",\"balance\":\"0x{x}\",\"codeHash\":\"{s}\",\"storageHash\":\"{s}\",\"storageProof\":[]}}",
                .{ nonce, balance, ZERO_HASH_HEX, ZERO_HASH_HEX },
            );
        }

        const slot_text = switch (params[1].array.items[0]) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        const slot = try parseHexU256(slot_text);
        const encoded_slot = if (slot == self.storage_slot) slot else @as(u256, 0);
        const encoded_value = if (slot == self.storage_slot) storage_value else @as(u256, 0);

        return try std.fmt.allocPrint(
            allocator,
            "{{\"nonce\":\"0x{x}\",\"balance\":\"0x{x}\",\"codeHash\":\"{s}\",\"storageHash\":\"{s}\",\"storageProof\":[{{\"key\":\"0x{x:0>64}\",\"value\":\"0x{x}\"}}]}}",
            .{ nonce, balance, ZERO_HASH_HEX, ZERO_HASH_HEX, encoded_slot, encoded_value },
        );
    }
};

const ZERO_HASH_HEX = "0x0000000000000000000000000000000000000000000000000000000000000000";

fn parseHexU256(text: []const u8) !u256 {
    if (text.len < 3) return error.InvalidHex;
    if (!(text[0] == '0' and (text[1] == 'x' or text[1] == 'X'))) return error.InvalidHex;
    return std.fmt.parseInt(u256, text[2..], 16);
}

fn testAddress() primitives.Address {
    return parseAddr("0x0000000000000000000000000000000000000042");
}

fn parseAddr(comptime hex: *const [42]u8) primitives.Address {
    var out: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex[2..]) catch unreachable;
    return .{ .bytes = out };
}

test "forked runtime reads remote account code and storage" {
    var resolver = MockForkResolver{
        .url_a = "https://rpc-a.example",
        .url_b = "https://rpc-b.example",
        .balance_a = 0x2a,
        .balance_b = 0x99,
        .nonce_a = 7,
        .nonce_b = 1,
        .storage_slot = 5,
        .storage_a = 0x55,
        .storage_b = 0xaa,
        .code_a = &[_]u8{ 0x60, 0x01 },
        .code_b = &[_]u8{ 0x60, 0x02 },
    };

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = resolver.url_a,
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    const addr = testAddress();
    try std.testing.expectEqual(@as(u256, 0x2a), try rt.getBalance(addr));
    try std.testing.expectEqual(@as(u64, 7), try rt.getNonce(addr));
    try std.testing.expectEqual(@as(u256, 0x55), try rt.getStorage(addr, 5));

    const code = try rt.getCode(addr);
    try std.testing.expectEqual(@as(usize, 2), code.len);
    try std.testing.expectEqual(@as(u8, 0x60), code[0]);
    try std.testing.expectEqual(@as(u8, 0x01), code[1]);
}

test "local overlay writes override fork-backed reads" {
    var resolver = MockForkResolver{
        .url_a = "https://rpc-a.example",
        .url_b = "https://rpc-b.example",
        .balance_a = 100,
        .balance_b = 200,
        .nonce_a = 0,
        .nonce_b = 0,
        .storage_slot = 1,
        .storage_a = 0,
        .storage_b = 0,
        .code_a = &[_]u8{},
        .code_b = &[_]u8{},
    };

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = resolver.url_a,
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    const addr = testAddress();
    const remote = try rt.getBalance(addr);
    try std.testing.expectEqual(@as(u256, 100), remote);

    const count_before_overlay = resolver.request_count;
    try rt.setBalance(addr, 999);
    try std.testing.expectEqual(@as(u256, 999), try rt.getBalance(addr));
    try std.testing.expectEqual(count_before_overlay, resolver.request_count);
}

test "snapshot and revert restore local overlays and fork URL state" {
    var resolver = MockForkResolver{
        .url_a = "https://rpc-a.example",
        .url_b = "https://rpc-b.example",
        .balance_a = 11,
        .balance_b = 22,
        .nonce_a = 0,
        .nonce_b = 0,
        .storage_slot = 1,
        .storage_a = 0,
        .storage_b = 0,
        .code_a = &[_]u8{},
        .code_b = &[_]u8{},
    };

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = resolver.url_a,
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    const addr = testAddress();
    try std.testing.expectEqual(@as(u256, 11), try rt.getBalance(addr));

    const snap = try rt.snapshot();
    try rt.setBalance(addr, 444);
    try rt.setRpcUrl(resolver.url_b);
    try std.testing.expectEqual(@as(u256, 444), try rt.getBalance(addr));
    try std.testing.expectEqualStrings(resolver.url_b, rt.fork_config.?.url);

    const reverted = try rt.revertToSnapshot(snap);
    try std.testing.expect(reverted);
    try std.testing.expectEqualStrings(resolver.url_a, rt.fork_config.?.url);
    try std.testing.expectEqual(@as(u256, 11), try rt.getBalance(addr));
}

test "reset keep/disable/replace follows fork semantics without changing chain id" {
    var resolver = MockForkResolver{
        .url_a = "https://rpc-a.example",
        .url_b = "https://rpc-b.example",
        .balance_a = 50,
        .balance_b = 75,
        .nonce_a = 0,
        .nonce_b = 0,
        .storage_slot = 1,
        .storage_a = 0,
        .storage_b = 0,
        .code_a = &[_]u8{},
        .code_b = &[_]u8{},
    };

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .chain_id = 999,
        .fork_url = resolver.url_a,
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    const addr = testAddress();
    const snapshot_id = try rt.snapshot();
    try rt.setBalance(addr, 123);

    try rt.reset(.keep_current);
    try std.testing.expect(rt.isForkingEnabled());
    try std.testing.expectEqualStrings(resolver.url_a, rt.fork_config.?.url);
    try std.testing.expectEqual(@as(u256, 50), try rt.getBalance(addr));
    try std.testing.expectEqual(@as(u64, 999), rt.chain_id);
    try std.testing.expect(!(try rt.revertToSnapshot(snapshot_id)));

    try rt.reset(.disable);
    try std.testing.expect(!rt.isForkingEnabled());
    try std.testing.expectEqual(@as(u256, 0), try rt.state.getBalance(addr));
    try std.testing.expectEqual(@as(u64, 999), rt.chain_id);

    try rt.reset(.{ .replace = .{
        .url = resolver.url_b,
        .block_number = 7,
    } });
    try std.testing.expect(rt.isForkingEnabled());
    try std.testing.expectEqualStrings(resolver.url_b, rt.fork_config.?.url);
    try std.testing.expectEqual(@as(?u64, 7), rt.fork_config.?.block_number);
    try std.testing.expectEqual(@as(u64, 999), rt.chain_id);
    try std.testing.expectEqual(@as(u256, 75), try rt.getBalance(addr));
}

test "setRpcUrl requires fork mode to be enabled" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectError(error.ForkNotEnabled, rt.setRpcUrl("https://rpc.example"));
}
