const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");
const runtime_mod = @import("../node/runtime.zig");
const dispatcher = @import("../rpc/dispatcher.zig");
const dispatch_wiring = @import("../rpc/dispatch_wiring.zig");
const rpc_server = @import("../rpc/server.zig");
const rpc_parse = @import("../rpc/parse.zig");
const transaction_encoding = @import("../transaction_encoding.zig");
const chain_import = @import("../chain_import.zig");
const dev_erc20 = @import("../rpc/handlers/dev_erc20.zig");

fn postRpc(
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    body: []const u8,
) !std.json.Parsed(std.json.Value) {
    const raw = (try rpc_server.handlePost(allocator, body, handlers)) orelse return error.MissingResponse;
    defer allocator.free(raw);
    return try std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always });
}

fn parseHexBytesAlloc(allocator: std.mem.Allocator, hex_text: []const u8) ![]u8 {
    if (hex_text.len < 2 or !std.mem.startsWith(u8, hex_text, "0x")) return error.InvalidHex;
    const digits = hex_text[2..];
    if (digits.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, digits.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, digits);
    return out;
}

fn verifyEthGetProof(
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    rt: *runtime_mod.NodeRuntime,
    addr: primitives.Address,
    slot: u256,
) !void {
    const head = try rt.blockchain.getCanonicalHeadBlock();
    var addr_buf: [42]u8 = undefined;
    const addr_hex = try std.fmt.bufPrint(&addr_buf, "0x{x}", .{&addr.bytes});

    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getProof\",\"params\":[\"{s}\",[\"0x{x:0>64}\"],\"latest\"]}}",
        .{ addr_hex, slot },
    );
    defer allocator.free(req);

    var res = try postRpc(allocator, handlers, req);
    defer res.deinit();
    try std.testing.expect(res.value.object.get("error") == null);

    const proof_obj = res.value.object.get("result").?.object;
    const claimed_balance = try rpc_parse.parseQuantityValue(u256, proof_obj.get("balance").?);
    const claimed_nonce = try rpc_parse.parseQuantityValue(u64, proof_obj.get("nonce").?);
    try std.testing.expectEqual(try rt.getBalance(addr), claimed_balance);
    try std.testing.expectEqual(try rt.getNonce(addr), claimed_nonce);

    const storage_proofs = proof_obj.get("storageProof").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), storage_proofs.len);
    const sp = storage_proofs[0].object;
    const claimed_val = try rpc_parse.parseQuantityValue(u256, sp.get("value").?);
    try std.testing.expectEqual(try rt.getStorage(addr, slot), claimed_val);

    // Cryptographically verify account proof against the canonical block's state_root!
    const acc_nodes_json = proof_obj.get("accountProof").?.array.items;
    var acc_nodes = try allocator.alloc([]u8, acc_nodes_json.len);
    var acc_built: usize = 0;
    defer {
        for (acc_nodes[0..acc_built]) |n| allocator.free(n);
        allocator.free(acc_nodes);
    }
    for (acc_nodes_json, 0..) |item, i| {
        acc_nodes[i] = try parseHexBytesAlloc(allocator, item.string);
        acc_built += 1;
    }

    const storage_root = try rpc_parse.parseHash32Value(proof_obj.get("storageHash").?);
    const code_hash = try rpc_parse.parseHash32Value(proof_obj.get("codeHash").?);

    // If account is present in state (non-empty), verify its exact RLP encoding in state_root!
    const code = try rt.getCode(addr);
    const is_empty = claimed_balance == 0 and claimed_nonce == 0 and code.len == 0;
    if (!is_empty and acc_nodes.len > 0) {
        const account_state = primitives.AccountState.AccountState.from(.{
            .nonce = claimed_nonce,
            .balance = claimed_balance,
            .storage_root = storage_root,
            .code_hash = code_hash,
        });
        const encoded_acc = try account_state.rlpEncode(allocator);
        defer allocator.free(encoded_acc);
        var const_nodes = try allocator.alloc([]const u8, acc_nodes.len);
        defer allocator.free(const_nodes);
        for (acc_nodes, 0..) |n, i| const_nodes[i] = n;

        try std.testing.expect(try primitives.Proof.verifyAccountProof(
            allocator,
            &head.header.state_root,
            &addr.bytes,
            encoded_acc,
            const_nodes,
        ));
    }

    // If storage slot is nonzero, verify its storage proof against storageHash!
    if (claimed_val != 0) {
        const slot_nodes_json = sp.get("proof").?.array.items;
        var slot_nodes = try allocator.alloc([]u8, slot_nodes_json.len);
        var slot_built: usize = 0;
        defer {
            for (slot_nodes[0..slot_built]) |n| allocator.free(n);
            allocator.free(slot_nodes);
        }
        for (slot_nodes_json, 0..) |item, i| {
            slot_nodes[i] = try parseHexBytesAlloc(allocator, item.string);
            slot_built += 1;
        }
        var const_slot_nodes = try allocator.alloc([]const u8, slot_nodes.len);
        defer allocator.free(const_slot_nodes);
        for (slot_nodes, 0..) |n, i| const_slot_nodes[i] = n;

        var slot_key: [32]u8 = undefined;
        std.mem.writeInt(u256, &slot_key, slot, .big);
        const rlp_val = try primitives.Rlp.encode(allocator, claimed_val);
        defer allocator.free(rlp_val);

        try std.testing.expect(try primitives.Proof.verifyStorageSlotProof(
            allocator,
            &storage_root,
            &slot_key,
            rlp_val,
            const_slot_nodes,
        ));
    }
}

const AccountShadow = struct {
    balance: u256 = 0,
    nonce: u64 = 0,
    slot0: u256 = 0,
    slot1: u256 = 0,
};

const SnapshotShadow = struct {
    id: u64,
    block_number: u64,
    accounts: [4]AccountShadow,
};

fn runStatefulNodeStream(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    var rt = try runtime_mod.NodeRuntime.init(allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const addrs = [_]primitives.Address{
        runtime_mod.DEFAULT_DEV_ACCOUNTS[0],
        runtime_mod.DEFAULT_DEV_ACCOUNTS[1],
        primitives.Address.fromU256(0x4001),
        primitives.Address.fromU256(0x4002),
    };
    var addr_hexes: [4][42]u8 = undefined;
    for (addrs, 0..) |addr, i| {
        _ = try std.fmt.bufPrint(&addr_hexes[i], "0x{x}", .{&addr.bytes});
    }

    var snaps = std.ArrayList(SnapshotShadow).empty;
    defer snaps.deinit(allocator);

    var step_idx: usize = 0;
    const max_steps = @min(input.len / 3, 28);
    while (step_idx < max_steps) : (step_idx += 1) {
        const op = input[step_idx * 3] % 14;
        const a_idx = input[step_idx * 3 + 1] % 4;
        const arg = input[step_idx * 3 + 2];

        switch (op) {
            0 => {
                // anvil_setBalance + read-back verification via eth_getBalance
                const new_bal: u256 = (@as(u256, arg) + 1) * 1_000_000_000_000_000_000;
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"anvil_setBalance\",\"params\":[\"{s}\",\"0x{x}\"]}}",
                    .{ addr_hexes[a_idx], new_bal },
                );
                defer allocator.free(req);
                var res = try postRpc(allocator, &handlers, req);
                defer res.deinit();
                try std.testing.expect(res.value.object.get("error") == null);
                try std.testing.expectEqual(new_bal, try rt.getBalance(addrs[a_idx]));

                const get_req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_getBalance\",\"params\":[\"{s}\",\"latest\"]}}",
                    .{addr_hexes[a_idx]},
                );
                defer allocator.free(get_req);
                var get_res = try postRpc(allocator, &handlers, get_req);
                defer get_res.deinit();
                try std.testing.expectEqual(new_bal, try rpc_parse.parseQuantityValue(u256, get_res.value.object.get("result").?));
            },
            1 => {
                // anvil_setNonce + read-back verification via eth_getTransactionCount
                const new_nonce: u64 = arg;
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"anvil_setNonce\",\"params\":[\"{s}\",\"0x{x}\"]}}",
                    .{ addr_hexes[a_idx], new_nonce },
                );
                defer allocator.free(req);
                var res = try postRpc(allocator, &handlers, req);
                defer res.deinit();
                try std.testing.expect(res.value.object.get("error") == null);
                try std.testing.expectEqual(new_nonce, try rt.getNonce(addrs[a_idx]));
            },
            2 => {
                // anvil_setStorageAt + eth_getStorageAt cross-check
                const slot: u256 = arg & 1;
                const val: u256 = if (arg & 2 == 0) 0 else (@as(u256, arg) << 8) | 0x42;
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"anvil_setStorageAt\",\"params\":[\"{s}\",\"0x{x:0>64}\",\"0x{x:0>64}\"]}}",
                    .{ addr_hexes[a_idx], slot, val },
                );
                defer allocator.free(req);
                var res = try postRpc(allocator, &handlers, req);
                defer res.deinit();
                try std.testing.expect(res.value.object.get("error") == null);
                try std.testing.expectEqual(val, try rt.getStorage(addrs[a_idx], slot));
            },
            3 => {
                // anvil_setCode + eth_getCode cross-check
                const code_hex = if (arg & 1 == 0) "0x600160005500" else "0x602a60005260206000f3";
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"anvil_setCode\",\"params\":[\"{s}\",\"{s}\"]}}",
                    .{ addr_hexes[a_idx], code_hex },
                );
                defer allocator.free(req);
                var res = try postRpc(allocator, &handlers, req);
                defer res.deinit();
                try std.testing.expect(res.value.object.get("error") == null);

                const get_req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_getCode\",\"params\":[\"{s}\",\"latest\"]}}",
                    .{addr_hexes[a_idx]},
                );
                defer allocator.free(get_req);
                var get_res = try postRpc(allocator, &handlers, get_req);
                defer get_res.deinit();
                try std.testing.expectEqualStrings(code_hex, get_res.value.object.get("result").?.string);
            },
            4 => {
                // evm_snapshot: record exact shadow state!
                if (snaps.items.len < 6) {
                    var res = try postRpc(allocator, &handlers, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"evm_snapshot\",\"params\":[]}");
                    defer res.deinit();
                    try std.testing.expect(res.value.object.get("error") == null);
                    const snap_id = try rpc_parse.parseQuantityValue(u64, res.value.object.get("result").?);
                    var acc_shadow: [4]AccountShadow = undefined;
                    for (addrs, 0..) |addr, i| {
                        acc_shadow[i] = .{
                            .balance = try rt.getBalance(addr),
                            .nonce = try rt.getNonce(addr),
                            .slot0 = try rt.getStorage(addr, 0),
                            .slot1 = try rt.getStorage(addr, 1),
                        };
                    }
                    try snaps.append(allocator, .{
                        .id = snap_id,
                        .block_number = rt.head_block_number,
                        .accounts = acc_shadow,
                    });
                }
            },
            5 => {
                // evm_revert: revert to a captured snapshot and verify EXACT restoration!
                if (snaps.items.len > 0) {
                    const pick = arg % snaps.items.len;
                    const expected = snaps.items[pick];
                    const req = try std.fmt.allocPrint(
                        allocator,
                        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"evm_revert\",\"params\":[\"0x{x}\"]}}",
                        .{expected.id},
                    );
                    defer allocator.free(req);
                    var res = try postRpc(allocator, &handlers, req);
                    defer res.deinit();
                    try std.testing.expect(res.value.object.get("error") == null);
                    try std.testing.expect(res.value.object.get("result").?.bool);

                    // Verify exact block number and all tracked accounts restored!
                    try std.testing.expectEqual(expected.block_number, rt.head_block_number);
                    for (addrs, 0..) |addr, i| {
                        try std.testing.expectEqual(expected.accounts[i].balance, try rt.getBalance(addr));
                        try std.testing.expectEqual(expected.accounts[i].nonce, try rt.getNonce(addr));
                        try std.testing.expectEqual(expected.accounts[i].slot0, try rt.getStorage(addr, 0));
                        try std.testing.expectEqual(expected.accounts[i].slot1, try rt.getStorage(addr, 1));
                    }

                    // Reverting the same snapshot a second time MUST return false!
                    var res2 = try postRpc(allocator, &handlers, req);
                    defer res2.deinit();
                    try std.testing.expect(!res2.value.object.get("result").?.bool);

                    snaps.items.len = pick;
                }
            },
            6 => {
                // evm_mine + block number advancement + debug_getRawHeader hash verification!
                const before_num = rt.head_block_number;
                var res = try postRpc(allocator, &handlers, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"evm_mine\",\"params\":[]}");
                defer res.deinit();
                try std.testing.expect(res.value.object.get("error") == null);
                try std.testing.expectEqual(before_num + 1, rt.head_block_number);

                // Verify debug_getRawHeader hashes to the exact canonical block hash!
                const head = try rt.blockchain.getCanonicalHeadBlock();
                const hdr_req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"debug_getRawHeader\",\"params\":[\"0x{x}\"]}}",
                    .{rt.head_block_number},
                );
                defer allocator.free(hdr_req);
                var hdr_res = try postRpc(allocator, &handlers, hdr_req);
                defer hdr_res.deinit();
                const raw_hdr = try parseHexBytesAlloc(allocator, hdr_res.value.object.get("result").?.string);
                defer allocator.free(raw_hdr);
                var computed_hash: [32]u8 = undefined;
                std.crypto.hash.sha3.Keccak256.hash(raw_hdr, &computed_hash, .{});
                try std.testing.expectEqual(head.hash, computed_hash);
            },
            7 => {
                // Send a real transfer tx from dev account 0 to target address & check receipt + debug_getRawTransaction!
                const to_idx = (a_idx % 3) + 1;
                const val: u64 = @as(u64, arg) * 1000 + 1;
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendTransaction\",\"params\":[{{\"from\":\"{s}\",\"to\":\"{s}\",\"value\":\"0x{x}\",\"gas\":\"0x186a0\"}}]}}",
                    .{ addr_hexes[0], addr_hexes[to_idx], val },
                );
                defer allocator.free(req);
                var res = try postRpc(allocator, &handlers, req);
                defer res.deinit();
                if (res.value.object.get("result")) |tx_hash_val| {
                    const tx_hash = tx_hash_val.string;
                    // Query txpool_status + eth_getTransactionByHash
                    const tx_req = try std.fmt.allocPrint(
                        allocator,
                        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_getTransactionByHash\",\"params\":[\"{s}\"]}}",
                        .{tx_hash},
                    );
                    defer allocator.free(tx_req);
                    var tx_res = try postRpc(allocator, &handlers, tx_req);
                    defer tx_res.deinit();
                    try std.testing.expect(tx_res.value.object.get("error") == null);
                }
            },
            8 => {
                // Toggle automine (manual <-> auto)
                const enable = (arg & 1) == 1;
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"evm_setAutomine\",\"params\":[{s}]}}",
                    .{if (enable) "true" else "false"},
                );
                defer allocator.free(req);
                var res = try postRpc(allocator, &handlers, req);
                defer res.deinit();
                try std.testing.expect(res.value.object.get("error") == null);
            },
            9 => {
                // Impersonate & stop impersonating
                const method = if (arg & 1 == 0) "anvil_impersonateAccount" else "anvil_stopImpersonatingAccount";
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":[\"{s}\"]}}",
                    .{ method, addr_hexes[a_idx] },
                );
                defer allocator.free(req);
                var res = try postRpc(allocator, &handlers, req);
                defer res.deinit();
                try std.testing.expect(res.value.object.get("error") == null);
            },
            10 => {
                // ERC20 deal / allowance slot calculation & storage verification
                const val: u256 = @as(u256, arg) + 1;
                if (arg & 1 == 0) {
                    const req = try std.fmt.allocPrint(
                        allocator,
                        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zevm_dealErc20\",\"params\":[\"{s}\",\"{s}\",\"0x{x}\"]}}",
                        .{ addr_hexes[2], addr_hexes[a_idx], val },
                    );
                    defer allocator.free(req);
                    var res = try postRpc(allocator, &handlers, req);
                    defer res.deinit();
                    if (res.value.object.get("error") == null) {
                        try std.testing.expectEqual(val, try rt.getStorage(addrs[2], dev_erc20.balanceSlot(addrs[a_idx])));
                    }
                } else {
                    const req = try std.fmt.allocPrint(
                        allocator,
                        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zevm_setErc20Allowance\",\"params\":[\"{s}\",\"{s}\",\"{s}\",\"0x{x}\"]}}",
                        .{ addr_hexes[2], addr_hexes[a_idx], addr_hexes[(a_idx + 1) % 4], val },
                    );
                    defer allocator.free(req);
                    var res = try postRpc(allocator, &handlers, req);
                    defer res.deinit();
                    if (res.value.object.get("error") == null) {
                        try std.testing.expectEqual(val, try rt.getStorage(addrs[2], dev_erc20.allowanceSlot(addrs[a_idx], addrs[(a_idx + 1) % 4])));
                    }
                }
            },
            11 => {
                // Advance time + mine & verify timestamp monotonicity
                const prev_ts = (try rt.blockchain.getCanonicalHeadBlock()).header.timestamp;
                const inc: u64 = @as(u64, arg) + 1;
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"evm_increaseTime\",\"params\":[\"0x{x}\"]}}",
                    .{inc},
                );
                defer allocator.free(req);
                var res = try postRpc(allocator, &handlers, req);
                defer res.deinit();
                try std.testing.expect(res.value.object.get("error") == null);

                var m_res = try postRpc(allocator, &handlers, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"evm_mine\",\"params\":[]}");
                defer m_res.deinit();
                const new_ts = (try rt.blockchain.getCanonicalHeadBlock()).header.timestamp;
                try std.testing.expect(new_ts > prev_ts);
            },
            12 => {
                // Verify eth_getProof cryptographically against canonical block stateRoot!
                // Mine first so all dirty account writes are flushed into the latest block's stateRoot.
                var m_res = try postRpc(allocator, &handlers, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"evm_mine\",\"params\":[]}");
                defer m_res.deinit();
                try verifyEthGetProof(allocator, &handlers, &rt, addrs[a_idx], arg & 1);
            },
            else => {
                // Read-only suite: eth_feeHistory, txpool_status, txpool_content, txpool_inspect, eth_getBlockByNumber, eth_getLogs
                const queries = [_][]const u8{
                    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_feeHistory\",\"params\":[\"0x4\",\"latest\",[25,50,75]]}",
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"txpool_status\",\"params\":[]}",
                    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"txpool_content\",\"params\":[]}",
                    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"txpool_inspect\",\"params\":[]}",
                    "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"eth_getBlockByNumber\",\"params\":[\"latest\",true]}",
                    "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"eth_getLogs\",\"params\":[{\"fromBlock\":\"0x0\",\"toBlock\":\"latest\"}]}",
                };
                const q = queries[arg % queries.len];
                var q_res = try postRpc(allocator, &handlers, q);
                defer q_res.deinit();
                try std.testing.expect(q_res.value.object.get("error") == null);
            },
        }
    }
}

test "fuzz: stateful NodeRuntime + JSON-RPC state machine, snapshots, mining and EIP-1186 proof verification" {
    try runStatefulNodeStream({}, "");
    try std.testing.fuzz({}, runStatefulNodeStream, .{ .corpus = &.{
        "\x00\x02\x05\x02\x02\x03\x04\x00\x00\x06\x00\x00\x0c\x02\x01\x05\x00\x00",
        "\x04\x00\x00\x00\x01\x10\x01\x01\x07\x03\x02\x00\x07\x00\x05\x05\x00\x00",
        "\x08\x00\x00\x07\x00\x02\x0d\x00\x01\x0d\x00\x02\x0d\x00\x03\x06\x00\x00",
        "\x0a\x01\x04\x0a\x01\x05\x0b\x00\x0c\x0c\x02\x00\x0d\x00\x00",
        "\x09\x03\x00\x00\x03\x02\x09\x03\x01\x06\x00\x00\x0d\x00\x04",
    } });
}

test "property: stateful NodeRuntime randomized multi-block RPC workload preserves all invariants" {
    var prng = std.Random.DefaultPrng.init(0x90de_57a7_ef01_2026);
    const random = prng.random();
    for (0..24) |_| {
        var stream: [72]u8 = undefined;
        random.bytes(&stream);
        try runStatefulNodeStream({}, &stream);
    }
}

fn fuzzRawRpcAgainstRealNode(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    if (input.len == 0 or input.len > 16 * 1024) return;

    const is_light = (input[0] & 1) == 1;
    const payload = input[1..];

    var rt = try runtime_mod.NodeRuntime.init(allocator, if (is_light) .{
        .mode = .light,
        .light = .{
            .network = .mainnet,
            .consensus_rpc_url = "http://127.0.0.1:1",
            .advance_on_request = false,
        },
    } else null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const response = rpc_server.handlePost(allocator, payload, &handlers) catch |err| {
        if (err == error.OutOfMemory) return err;
        return;
    };
    if (response) |bytes| {
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object or parsed.value == .array);
    }
}

test "fuzz: arbitrary JSON-RPC requests and batches against live trusted and light NodeRuntime" {
    try std.testing.fuzz({}, fuzzRawRpcAgainstRealNode, .{ .corpus = &.{
        "\x00{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\",\"params\":[]}",
        "\x01{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zevm_lightSyncStatus\",\"params\":[]}",
        "\x01{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{},\"latest\"]}",
        "\x00{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendRawTransaction\",\"params\":[\"0x02c0\"]}",
        "\x00{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zevm_setAccount\",\"params\":[\"0x0000000000000000000000000000000000000001\",{\"balance\":\"0x10\",\"nonce\":\"0x2\"}]}",
        "\x00{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zevm_getAccount\",\"params\":[\"0x0000000000000000000000000000000000000001\"]}",
        "\x00{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"debug_getRawBlock\",\"params\":[\"0x0\"]}",
        "\x00{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"debug_getRawReceipts\",\"params\":[\"0x0\"]}",
        "\x00{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zevm_reset\",\"params\":[null]}",
        "\x00[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"web3_sha3\",\"params\":[\"0x68656c6c6f\"]},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"rpc_modules\"}]",
        "\x00{",
        "\x01[]",
    } });
}

test "property: debug_getRawBlock round-trips through chain_import for blocks with legacy transactions" {
    const allocator = std.testing.allocator;
    var rt = try runtime_mod.NodeRuntime.init(allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    // Send a signed legacy transaction so block 1 has a real transaction and receipt.
    const sender_key = runtime_mod.DEFAULT_DEV_ACCOUNTS[0];
    _ = sender_key;
    const priv = @import("../genesis.zig").DEV_ACCOUNTS[0].private_key;
    const unsigned = primitives.Transaction.LegacyTransaction{
        .nonce = 0,
        .gas_price = 2_000_000_000,
        .gas_limit = 21_000,
        .to = runtime_mod.DEFAULT_DEV_ACCOUNTS[1],
        .value = 12345,
        .data = &.{},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    const signed = try transaction_encoding.signLegacyTransaction(allocator, unsigned, priv, rt.chain_id);
    const raw_tx = try transaction_encoding.encodeLegacyTransactionEnvelope(allocator, signed);
    defer allocator.free(raw_tx);

    const raw_tx_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{raw_tx});
    defer allocator.free(raw_tx_hex);
    const send_req = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendRawTransaction\",\"params\":[\"{s}\"]}}",
        .{raw_tx_hex},
    );
    defer allocator.free(send_req);
    var send_res = try postRpc(allocator, &handlers, send_req);
    defer send_res.deinit();
    try std.testing.expect(send_res.value.object.get("error") == null);

    // Fetch raw RLP block 1 via debug_getRawBlock.
    var raw_blk_res = try postRpc(allocator, &handlers, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"debug_getRawBlock\",\"params\":[\"0x1\"]}");
    defer raw_blk_res.deinit();
    try std.testing.expect(raw_blk_res.value.object.get("error") == null);
    const raw_blk_bytes = try parseHexBytesAlloc(allocator, raw_blk_res.value.object.get("result").?.string);
    defer allocator.free(raw_blk_bytes);

    // Re-import block 1 into a fresh Blockchain via chain_import!
    var fresh = try runtime_mod.NodeRuntime.init(allocator, null);
    defer fresh.deinit();
    var owned_bodies = std.ArrayList(chain_import.OwnedBlockBody).empty;
    defer {
        for (owned_bodies.items) |*body| body.deinit(allocator);
        owned_bodies.deinit(allocator);
    }
    const summary = try chain_import.importChainBytesWithOptions(
        allocator,
        &fresh.blockchain,
        &owned_bodies,
        raw_blk_bytes,
        .{
            .hardfork_config = fresh.hardfork_config,
        },
    );
    try std.testing.expectEqual(@as(usize, 1), summary.block_count);
    try std.testing.expectEqual(@as(usize, 1), summary.transaction_count);
    try std.testing.expectEqual(@as(u64, 1), summary.head_block_number);

    // Exact canonical hash, state root, and transaction equality across the independently imported chain!
    const orig_head = try rt.blockchain.getCanonicalHeadBlock();
    const imported_head = try fresh.blockchain.getCanonicalHeadBlock();
    try std.testing.expectEqual(orig_head.hash, imported_head.hash);
    try std.testing.expectEqual(orig_head.header.state_root, imported_head.header.state_root);
    try std.testing.expectEqual(orig_head.header.transactions_root, imported_head.header.transactions_root);
    try std.testing.expectEqual(orig_head.header.receipts_root, imported_head.header.receipts_root);
    try std.testing.expectEqualSlices(u8, raw_tx, imported_head.body.transactions[0].raw);
}
