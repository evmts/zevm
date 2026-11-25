const std = @import("std");
const primitives = @import("primitives");
const config = @import("config.zig");
const exex = @import("exex.zig");
const runtime = @import("node/runtime.zig");
const dispatcher = @import("rpc/dispatcher.zig");
const wiring = @import("rpc/dispatch_wiring.zig");
const parse = @import("rpc/parse.zig");
const server = @import("rpc/server.zig");

const allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Runtime = runtime.NodeRuntime;
const Event = exex.Event;
const EventTag = std.meta.Tag(Event);
const Address = primitives.Address;

const Returns = struct {
    pub fn run(_: *Runtime, _: *exex.EventIterator) void {}
};

const Fails = struct {
    pub fn run(_: *Runtime, _: *exex.EventIterator) !void {
        return error.DeliberateExtensionExit;
    }
};

// Each recorder owns the events from its iterator. The test reads the logs
// only after stopExtensions drains the queues and joins their writers.
fn RecordedNode(comptime mode: enum { single, pair, detach }) type {
    return struct {
        const Self = @This();
        const Node = exex.NodeWith(Runtime, switch (mode) {
            .single => .{Recorder(0)},
            .pair => .{ Recorder(0), Recorder(1) },
            .detach => .{ Recorder(0), Returns, Fails },
        });
        node: Node = undefined,
        logs: [if (mode == .pair) 2 else 1]std.ArrayList(Event) = @splat(.empty),

        fn Recorder(comptime index: usize) type {
            return struct {
                pub fn run(rt: *Runtime, iterator: *exex.EventIterator) std.mem.Allocator.Error!void {
                    const node: *Node = @alignCast(@fieldParentPtr("runtime", rt));
                    const fixture: *Self = @alignCast(@fieldParentPtr("node", node));
                    while (iterator.next()) |owned| {
                        var event = owned;
                        errdefer event.deinit(iterator.allocator);
                        try fixture.logs[index].append(iterator.allocator, event);
                    }
                }
            };
        }

        fn init(self: *Self, cfg: runtime.NodeConfig) !void {
            try self.node.init(allocator, cfg);
            errdefer self.deinit();
            try self.node.startExtensions();
        }

        fn finish(self: *Self) !Cursor {
            self.node.stopExtensions();
            for (self.node.iterators) |iterator| try expectEqual(0, iterator.missedCount());
            return .{ .events = self.logs[0].items };
        }

        fn deinit(self: *Self) void {
            self.node.deinit();
            for (&self.logs) |*log| {
                for (log.items) |*event| event.deinit(allocator);
                log.deinit(allocator);
            }
        }
    };
}

const Cursor = struct {
    events: []const Event,

    fn take(self: *Cursor, comptime tag: EventTag) !std.meta.TagPayload(Event, tag) {
        try expect(self.events.len > 0);
        const event = self.events[0];
        try expectEqual(tag, std.meta.activeTag(event));
        self.events = self.events[1..];
        return @field(event, @tagName(tag));
    }
};

// Go through the same JSON parser, method routing and serializer as an HTTP
// request. The parsed result owns its strings after the wire buffer is freed.
fn rpc(rt: *Runtime, method: []const u8, params: []const u8) !std.json.Parsed(std.json.Value) {
    var handlers = dispatcher.HandlerRegistry{};
    wiring.install(&handlers, rt);
    const request = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":1,"method":"{s}","params":{s}}}
    , .{ method, params });
    defer allocator.free(request);
    const response = (try server.handlePost(allocator, request, &handlers)) orelse return error.MissingRpcResponse;
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    parsed.value = parsed.value.object.get("result") orelse {
        std.debug.print("{s} returned {s}\n", .{ method, response });
        return error.MissingRpcResult;
    };
    return parsed;
}

fn transfer(rt: *Runtime, from: Address, to: Address, nonce: u64, value: u64) ![32]u8 {
    var buf: [256]u8 = undefined;
    const params = try std.fmt.bufPrint(&buf,
        \\[{{"from":"0x{x}","to":"0x{x}","nonce":"0x{x}","value":"0x{x}","gas":"0x5208"}}]
    , .{ &from.bytes, &to.bytes, nonce, value });
    const result = try rpc(rt, "eth_sendTransaction", params);
    defer result.deinit();
    return parse.parseHash32Value(result.value);
}

test "empty extension tuple adds no storage and runs a normal mining lifecycle" {
    const Node = exex.NodeWith(runtime.NodeRuntime, .{});
    inline for (.{ "hub", "threads", "iterators", "started" }) |field|
        try expectEqual(0, @sizeOf(@FieldType(Node, field)));
    try expectEqual(@sizeOf(Runtime), @sizeOf(Node));
    var node: Node = undefined;
    try node.init(allocator, .{ .mining_config = .manual });
    defer node.deinit();
    try node.startExtensions();
    try expect(node.runtime.event_hub == null);
    node.runtime.notifyNodeStarted("127.0.0.1", 8545);
    node.runtime.setNextBlockTimestamp(1);
    try node.runtime.mineBlocks(1, 0);
    try expectEqual(1, node.runtime.head_block_number);
    node.runtime.notifyNodeStopping();
    node.stopExtensions();
}

test "two extensions independently receive startup on the bound RPC listener and shutdown" {
    var f: RecordedNode(.pair) = .{};
    try f.init(.{});
    defer f.deinit();
    const rt = &f.node.runtime;
    var handlers = dispatcher.HandlerRegistry{};
    wiring.install(&handlers, rt);
    var port: u16 = undefined;
    {
        var listener = try server.TestListener.init(allocator, "127.0.0.1", &handlers);
        defer listener.deinit();
        try listener.start();
        port = listener.address().getPort();
        try expect(port != 0);
        var host: [64]u8 = undefined;
        rt.notifyNodeStarted(listener.server.boundHost(&host), port);
        rt.setChainId(44);
        rt.notifyNodeStopping();
    }
    _ = try f.finish();
    for (f.logs) |log| {
        var cursor = Cursor{ .events = log.items };
        const started = try cursor.take(.node_started);
        try expectEqual(.trusted, started.mode);
        try expectEqual(runtime.DEFAULT_CHAIN_ID, started.chain_id);
        try expectEqualStrings("127.0.0.1", started.host);
        try expectEqual(port, started.port);
        try expectEqual(44, (try cursor.take(.chain_id_changed)).new_chain_id);
        try expectEqual(.trusted, (try cursor.take(.node_stopping)).mode);
        try expectEqual(0, cursor.events.len);
    }
    try expect(f.logs[0].items[0].node_started.host.ptr != f.logs[1].items[0].node_started.host.ptr);
}

test "returning and failing extensions detach while a surviving extension observes mining" {
    var f: RecordedNode(.detach) = .{};
    try f.init(.{ .mining_config = .manual });
    defer f.deinit();
    // Join just the two short-lived workers, before any node shutdown. This
    // observes their actual detach without sleeps or scheduler-dependent polling.
    for (1..3) |i| {
        f.node.threads[i].?.join();
        f.node.threads[i] = null;
        try expect(f.node.iterators[i].isDetached());
    }
    try expect(!f.node.iterators[0].isClosed());
    const rt = &f.node.runtime;
    rt.setNextBlockTimestamp(1);
    try rt.mineBlocks(1, 0);
    rt.notifyNodeStopping();
    var cursor = try f.finish();
    _ = try cursor.take(.time_adjusted);
    while (cursor.events.len > 0 and cursor.events[0] == .state_change) _ = try cursor.take(.state_change);
    try expectEqual(1, (try cursor.take(.block_committed)).block_number);
    _ = try cursor.take(.node_stopping);
    try expectEqual(0, cursor.events.len);
}

test "submission, mining and snapshot rollback deliver causally ordered events" {
    var f: RecordedNode(.single) = .{};
    try f.init(.{ .mining_config = .manual });
    defer f.deinit();
    const rt = &f.node.runtime;
    const sender = rt.managedAccountAddress(1);
    const recipient = rt.managedAccountAddress(2);
    const balance = try rt.getBalance(recipient);
    const genesis = rt.blockchain.getCanonicalHash(0).?;
    const snapshot = try rt.snapshot();
    rt.setNextBlockTimestamp(1);
    const tx = try transfer(rt, sender, recipient, 0, 17);
    try expectEqual(1, rt.pool.pendingCount());
    try rt.mineBlocks(1, 0);
    const mined = rt.blockchain.getCanonicalHash(1) orelse return error.MissingMinedBlock;
    try expectEqual(balance + 17, try rt.getBalance(recipient));
    try expect(try rt.revertToSnapshot(snapshot));
    try expectEqual(0, rt.head_block_number);
    try expect(rt.blockchain.getCanonicalHash(1) == null);
    try expectEqual(balance, try rt.getBalance(recipient));

    var cursor = try f.finish();
    const created = try cursor.take(.snapshot_created);
    try expectEqual(snapshot, created.snapshot_id);
    try expectEqual(0, created.block_number);
    _ = try cursor.take(.time_adjusted);
    const added = try cursor.take(.tx_pool_add);
    try expectEqual(tx, added.tx_hash);
    try expectEqual(sender.bytes, added.sender);
    try expectEqual(0, added.nonce);

    var changes: usize = 0;
    var credited = false;
    var drops: usize = 0;
    while (cursor.events.len > 0) switch (cursor.events[0]) {
        .state_change => {
            const change = try cursor.take(.state_change);
            changes += 1;
            if (change.field == .balance and std.mem.eql(u8, &change.address, &recipient.bytes)) {
                try expectEqual(balance, change.old_u256.?);
                try expectEqual(balance + 17, change.new_u256.?);
                credited = true;
            }
        },
        .tx_pool_drop => {
            const drop = try cursor.take(.tx_pool_drop);
            try expectEqual(tx, drop.tx_hash);
            try expectEqual(.mined, drop.reason);
            drops += 1;
        },
        else => break,
    };
    try expect(credited);
    try expectEqual(1, drops);
    const commit = try cursor.take(.block_committed);
    try expectEqual(1, commit.block_number);
    try expectEqual(mined, commit.block_hash);
    try expectEqual(genesis, commit.parent_hash);
    try expectEqual(1, commit.tx_count);
    try std.testing.expectEqualSlices([32]u8, &.{tx}, commit.tx_hashes);
    try expectEqual(1, commit.receipt_count);
    try expectEqual(changes, commit.state_diff_count);
    const removed = try cursor.take(.block_reverted);
    try expectEqual(1, removed.reverted_block_number);
    try expectEqual(0, removed.new_head_number);
    try expectEqual(genesis, removed.new_head_hash);
    const reverted = try cursor.take(.snapshot_reverted);
    try expectEqual(snapshot, reverted.snapshot_id);
    try expect(reverted.success);
    try expectEqual(0, reverted.new_head_number);
    try expectEqual(0, cursor.events.len);
}

// Historical answers are keyed by the requested block, independently of the
// current head. At block 101 the outsider has spent nonce 0 and the remote
// recipient has received another 63 wei.
const Upstream = struct {
    const first_url = "http://upstream.invalid";
    const second_url = "http://replacement.invalid";
    const outsider: Address = .{ .bytes = @splat(0xcc) };
    const recipient: Address = .{ .bytes = @splat(0xbb) };
    head: u64 = 100,
    expected_url: []const u8 = first_url,
    head_queries: usize = 0,

    fn nodeConfig(self: *Upstream, follow: bool) runtime.NodeConfig {
        return .{
            .fork_url = first_url,
            .fork_block_number = 100,
            .fork_follow = follow,
            .fork_rpc_resolver = .{ .context = self, .resolve = resolve },
            .mining_config = .manual,
        };
    }

    fn resolve(ctx: ?*anyopaque, a: std.mem.Allocator, request: runtime.ForkRpcRequest) ![]u8 {
        const self: *Upstream = @ptrCast(@alignCast(ctx.?));
        try expectEqualStrings(self.expected_url, request.url);
        const method = request.method;
        if (std.mem.eql(u8, method, "eth_blockNumber")) {
            try expectEqualStrings("[]", request.params_json);
            self.head_queries += 1;
            return std.fmt.allocPrint(a, "\"0x{x}\"", .{self.head});
        }
        // Exercise the runtime's scalar fallback for providers without proofs.
        if (std.mem.eql(u8, method, "eth_getProof")) return error.MethodNotFound;
        const params = try std.json.parseFromSlice([]const []const u8, a, request.params_json, .{});
        defer params.deinit();
        const args = params.value;
        const storage = std.mem.eql(u8, method, "eth_getStorageAt");
        try expectEqual(@as(usize, if (storage) 3 else 2), args.len);
        const address = try parse.parseAddressString(args[0]);
        const block = try parse.parseQuantityString(u64, args[args.len - 1]);
        try expect(block == 100 or block == 101);
        if (std.mem.eql(u8, method, "eth_getCode")) return a.dupe(u8, "\"0x\"");
        const value: u256 = if (std.mem.eql(u8, method, "eth_getBalance")) balance: {
            if (std.meta.eql(address, outsider)) break :balance runtime.DEFAULT_BALANCE;
            if (std.meta.eql(address, recipient)) break :balance if (block == 100) 7 else 70;
            break :balance 0;
        } else if (std.mem.eql(u8, method, "eth_getTransactionCount"))
            @intFromBool(std.meta.eql(address, outsider) and block == 101)
        else if (storage)
            0
        else
            return error.UnexpectedForkRpcMethod;
        return std.fmt.allocPrint(a, "\"0x{x}\"", .{value});
    }
};

test "trusted control operations deliver their new settings to an extension" {
    var upstream = Upstream{};
    var f: RecordedNode(.single) = .{};
    try f.init(upstream.nodeConfig(false));
    defer f.deinit();
    const rt = &f.node.runtime;
    const coinbase = rt.coinbase;
    const limit = rt.dev_runtime.config.block_gas_limit;
    const account = rt.managedAccountAddress(2);
    try rt.setMiningConfig(.auto);
    rt.setChainId(99);
    try rt.impersonateAccount(account);
    _ = try rt.increaseTime(37);
    rt.setCoinbase(account);
    rt.setBlockGasLimit(limit + 1000);
    try rt.setRpcUrl(Upstream.second_url);

    var cursor = try f.finish();
    const mining = try cursor.take(.mining_mode_changed);
    try expectEqual(.auto, mining.mode);
    try expectEqual(0, mining.interval_seconds);
    const chain = try cursor.take(.chain_id_changed);
    try expectEqual(runtime.DEFAULT_CHAIN_ID, chain.old_chain_id);
    try expectEqual(99, chain.new_chain_id);
    const impersonation = try cursor.take(.impersonation_changed);
    try expectEqual(account.bytes, impersonation.address.?);
    try expect(impersonation.impersonating);
    try expect(!impersonation.auto_impersonate);
    try expectEqual(@as(?i64, 37), (try cursor.take(.time_adjusted)).delta_seconds);
    const beneficiary = try cursor.take(.coinbase_changed);
    try expectEqual(coinbase.bytes, beneficiary.old_coinbase);
    try expectEqual(account.bytes, beneficiary.new_coinbase);
    const gas = try cursor.take(.block_gas_limit_changed);
    try expectEqual(limit, gas.old_gas_limit);
    try expectEqual(limit + 1000, gas.new_gas_limit);
    const fork = try cursor.take(.fork_changed);
    try expect(fork.enabled);
    try expect(!fork.follow);
    try expectEqualStrings(Upstream.second_url, fork.url.?);
    try expectEqual(@as(?u64, 100), fork.block_number);
    try expectEqual(0, cursor.events.len);
}

test "light sync progress publishes status, readiness, checkpoint and head transitions" {
    const checkpoint = [_]u8{0xa7} ** 32;
    var f: RecordedNode(.single) = .{};
    try f.init(.{
        .mode = .light,
        .light = .{ .checkpoint = checkpoint, .consensus_rpc_url = "http://beacon.invalid", .advance_on_request = false },
    });
    defer f.deinit();
    const rt = &f.node.runtime;
    try expect(!rt.isLightReady());
    try rt.setLightSyncProgress(.synced, 12, 11, 10, 120);
    try expect(rt.isLightReady());
    // Reporting the same progress again must not repeat a transition.
    try rt.setLightSyncProgress(.synced, 12, 11, 10, 120);
    const cursor = try f.finish();
    var seen = std.EnumSet(EventTag).initEmpty();
    for (cursor.events) |event| {
        const tag = std.meta.activeTag(event);
        try expect(!seen.contains(tag));
        seen.insert(tag);
        switch (event) {
            .sync_status_changed => |status| {
                try expectEqual(.syncing, status.old_status);
                try expectEqual(.synced, status.new_status);
                try expect(status.ready);
            },
            .readiness_changed => |ready| try expect(ready.ready),
            .checkpoint_accepted => |accepted| try expectEqual(checkpoint, accepted.checkpoint),
            .head_updated => |head| {
                try expectEqual(12, head.optimistic_slot);
                try expectEqual(11, head.safe_slot);
                try expectEqual(10, head.finalized_slot);
            },
            else => return error.UnexpectedLightEvent,
        }
    }
    try expectEqual(4, seen.count());
}

test "fork follow requires a trusted fork with an upstream URL" {
    try std.testing.expectError(error.InvalidConfig, config.load(allocator, &.{"--fork-follow"}));
    // Supply a valid light configuration and add only the incompatible flag.
    const light_args = [_][]const u8{ "--mode", "light", "--consensus-rpc-url", "http://beacon.invalid", "--checkpoint", "0x" ++ "11" ** 32 };
    var light = try config.load(allocator, &light_args);
    defer light.deinit(allocator);
    try std.testing.expectError(error.InvalidConfig, config.load(allocator, &(light_args ++ [_][]const u8{"--fork-follow"})));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "follow.json", .data = 
        \\{"mode":{"trusted":{"fork":{"follow":true}}}}
    });
    const path = try tmp.dir.realpathAlloc(allocator, "follow.json");
    defer allocator.free(path);
    try std.testing.expectError(error.InvalidConfig, config.load(allocator, &.{ "--config", path }));
}

test "a new upstream head carries, drops and reexecutes local transactions in mining order" {
    var upstream = Upstream{};
    var f: RecordedNode(.single) = .{};
    try f.init(upstream.nodeConfig(true));
    defer f.deinit();
    const rt = &f.node.runtime;
    const sender = rt.managedAccountAddress(1);
    const stable_recipient = rt.managedAccountAddress(2);
    const original_balance = try rt.getBalance(stable_recipient);

    const carried = try transfer(rt, sender, stable_recipient, 0, 11);
    rt.setNextBlockTimestamp(1);
    try rt.mineBlocks(1, 0);
    try rt.impersonateAccount(Upstream.outsider);
    const conflicted = try transfer(rt, Upstream.outsider, rt.managedAccountAddress(3), 0, 13);
    rt.setNextBlockTimestamp(2);
    try rt.mineBlocks(1, 0);
    const executed = try transfer(rt, sender, Upstream.recipient, 1, 17);
    rt.setNextBlockTimestamp(3);
    try rt.mineBlocks(1, 0);
    for ([_][32]u8{ carried, conflicted, executed }) |hash|
        try expect(rt.receipt_index.getByTxHash(hash) != null);
    try expectEqual(0, rt.pool.items().len);
    try expectEqual(7 + 17, try rt.getBalance(Upstream.recipient));
    const snapshot = try rt.snapshot();

    try expect((try rt.pollUpstreamAndRebase()) == null);
    upstream.head = 101;
    const summary = (try rt.pollUpstreamAndRebase()) orelse return error.MissingRebase;
    try expectEqual(100, summary.old_fork_block);
    try expectEqual(101, summary.new_fork_block);
    try expectEqual(2, summary.replayed_count);
    try expectEqual(1, summary.dropped_count);
    try expectEqual(1, summary.skipped_reexecution_count);
    try expectEqual(101, rt.rebase_tracker.?.current_fork_block);
    try expect((try rt.pollUpstreamAndRebase()) == null);
    try expectEqual(3, upstream.head_queries);

    // The successful transfers retained their effects and relative positions.
    // The last credit starts at the new upstream balance, so reusing its old
    // poststate would be observable even if a replay event claimed success.
    try expectEqual(original_balance + 11, try rt.getBalance(stable_recipient));
    try expectEqual(70 + 17, try rt.getBalance(Upstream.recipient));
    try expectEqual(2, try rt.getNonce(sender));
    const first = rt.receipt_index.locateByTxHash(carried) orelse return error.MissingReplayReceipt;
    const last = rt.receipt_index.locateByTxHash(executed) orelse return error.MissingReplayReceipt;
    const first_height = (rt.blockchain.getBlockLocal(first.block_hash) orelse return error.MissingReplayBlock).header.number;
    const last_height = (rt.blockchain.getBlockLocal(last.block_hash) orelse return error.MissingReplayBlock).header.number;
    try expectEqual(first.block_hash, rt.blockchain.getCanonicalHash(first_height).?);
    try expectEqual(last.block_hash, rt.blockchain.getCanonicalHash(last_height).?);
    try expect(first_height < last_height or (first_height == last_height and first.tx_index < last.tx_index));
    try expect(rt.receipt_index.getByTxHash(conflicted) == null);
    try expectEqual(1, rt.pool.pendingCount());
    try expectEqual(1, rt.pool.items().len);
    const pending = rt.pool.items()[0];
    try expectEqual(conflicted, pending.hash);
    try expectEqual(Upstream.outsider.bytes, pending.sender.bytes);
    try expectEqual(0, pending.nonce);
    try expect(!(try rt.revertToSnapshot(snapshot)));
    var params_buf: [32]u8 = undefined;
    const revert = try rpc(rt, "zevm_revert", try std.fmt.bufPrint(&params_buf, "[\"0x{x}\"]", .{snapshot}));
    defer revert.deinit();
    try expectEqual(false, revert.value.bool);

    // PRD 13.4 orders the rebase events. Pool notifications for the returned
    // transaction may also be present in this same extension's event stream.
    const all = try f.finish();
    var rebase_events: [5]Event = undefined;
    var count: usize = 0;
    for (all.events) |event| switch (event) {
        .rebase_started, .rebase_tx_replayed, .rebase_tx_dropped, .rebase_completed => {
            try expect(count < rebase_events.len);
            rebase_events[count] = event;
            count += 1;
        },
        else => {},
    };
    try expectEqual(rebase_events.len, count);
    var cursor = Cursor{ .events = &rebase_events };
    const started = try cursor.take(.rebase_started);
    try expectEqual(100, started.old_fork_block);
    try expectEqual(101, started.new_upstream_head);
    const cached = try cursor.take(.rebase_tx_replayed);
    try expectEqual(carried, cached.tx_hash);
    try expectEqual(first_height, cached.new_block_number);
    try expect(cached.skipped_execution);
    const dropped = try cursor.take(.rebase_tx_dropped);
    try expectEqual(conflicted, dropped.tx_hash);
    try expectEqualStrings("NonceMismatch", dropped.reason);
    const replayed = try cursor.take(.rebase_tx_replayed);
    try expectEqual(executed, replayed.tx_hash);
    try expectEqual(last_height, replayed.new_block_number);
    try expect(!replayed.skipped_execution);
    const completed = try cursor.take(.rebase_completed);
    try expectEqual(summary.new_fork_block, completed.new_fork_block);
    try expectEqual(summary.replayed_count, completed.replayed_count);
    try expectEqual(summary.dropped_count, completed.dropped_count);
}

fn objectField(value: std.json.Value, key: []const u8) !std.json.Value {
    try expect(value == .object);
    return value.object.get(key) orelse error.MissingRpcField;
}

fn expectForkRpcState(rt: *Runtime, enabled: bool, follow: bool) !void {
    for ([_][]const u8{ "zevm_metadata", "anvil_metadata", "hardhat_metadata" }) |method| {
        const result = try rpc(rt, method, "[]");
        defer result.deinit();
        try expectEqual(enabled, (try objectField(result.value, "forking")).bool);
        try expectEqual(follow, (try objectField(result.value, "forkFollow")).bool);
    }
    for ([_][]const u8{ "zevm_nodeInfo", "anvil_nodeInfo" }) |method| {
        const result = try rpc(rt, method, "[]");
        defer result.deinit();
        const fork = try objectField(result.value, "fork");
        try expectEqual(enabled, (try objectField(fork, "enabled")).bool);
        try expectEqual(follow, (try objectField(fork, "follow")).bool);
    }
}

fn expectRpcSuccess(rt: *Runtime, method: []const u8, params: []const u8) !void {
    const result = try rpc(rt, method, params);
    defer result.deinit();
    try expect(result.value == .bool and result.value.bool);
}

test "RPC metadata and nodeInfo aliases track reset and setRpcUrl follow state" {
    var upstream = Upstream{};
    var rt = try Runtime.init(allocator, upstream.nodeConfig(false));
    defer rt.deinit();
    try expectForkRpcState(&rt, true, false);
    const follow_params =
        \\[{"url":"http://upstream.invalid","blockNumber":"0x64","follow":true}]
    ;
    try expectRpcSuccess(&rt, "zevm_reset", follow_params);
    try expect(rt.fork_config.?.follow);
    try expect(rt.rebase_tracker.?.follow);
    try expectForkRpcState(&rt, true, true);
    try expectRpcSuccess(&rt, "zevm_setRpcUrl",
        \\["http://replacement.invalid"]
    );
    upstream.expected_url = Upstream.second_url;
    try expectEqualStrings(Upstream.second_url, rt.fork_config.?.url);
    try expect(rt.fork_config.?.follow);
    const tracker = rt.rebase_tracker orelse return error.MissingTracker;
    try expect(tracker.follow);
    const url = try tracker.getUrlAlloc(allocator);
    defer allocator.free(url);
    try expectEqualStrings(Upstream.second_url, url);
    try expect((try rt.pollUpstreamAndRebase()) == null);
    try expectEqual(1, upstream.head_queries);
    try expectForkRpcState(&rt, true, true);

    try expectRpcSuccess(&rt, "zevm_reset",
        \\[{"url":"http://replacement.invalid","blockNumber":"0x64","follow":false}]
    );
    try expect(rt.isForkingEnabled());
    try expect(!rt.fork_config.?.follow);
    try expect(rt.rebase_tracker == null);
    try std.testing.expectError(error.ForkFollowDisabled, rt.pollUpstreamAndRebase());
    try expectForkRpcState(&rt, true, false);

    upstream.expected_url = Upstream.first_url;
    try expectRpcSuccess(&rt, "zevm_reset", follow_params);
    try expectRpcSuccess(&rt, "zevm_reset", "[null]");
    try expect(!rt.isForkingEnabled());
    try expect(rt.rebase_tracker == null);
    try expectForkRpcState(&rt, false, false);
}
