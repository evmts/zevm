const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");
const guillotine_mini = @import("guillotine_mini");
const runtime_mod = @import("../node/runtime.zig");
const dispatcher = @import("../rpc/dispatcher.zig");
const dispatch_wiring = @import("../rpc/dispatch_wiring.zig");
const rpc_server = @import("../rpc/server.zig");
const simulation = @import("../rpc/handlers/simulation.zig");
const precompile_compat = @import("../precompile_compat.zig");

fn postRpc(
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    body: []const u8,
) !std.json.Parsed(std.json.Value) {
    const raw = (try rpc_server.handlePost(allocator, body, handlers)) orelse return error.MissingResponse;
    defer allocator.free(raw);
    return try std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always });
}

fn parseHexU64(text: []const u8) !u64 {
    if (!std.mem.startsWith(u8, text, "0x")) return error.InvalidHex;
    return try std.fmt.parseInt(u64, text[2..], 16);
}

fn fuzzDecodeRevertReason(_: void, input: []const u8) anyerror!void {
    if (simulation.decodeRevertReason(input)) |reason| {
        // Returned slice must point inside input (or be a static Panic string) and never crash on access.
        var checksum: u8 = 0;
        for (reason) |b| checksum ^= b;
        std.mem.doNotOptimizeAway(checksum);
    }
}

test "fuzz: simulation.decodeRevertReason on arbitrary ABI and malformed revert bytes" {
    // Valid Error(string) "boom": selector 08c379a0 + offset 0x20 + len 4 + "boom"
    const valid_error = "\x08\xc3\x79\xa0" ++
        ("\x00" ** 31) ++ "\x20" ++
        ("\x00" ** 31) ++ "\x04" ++
        "boom" ++ ("\x00" ** 28);
    // Solidity 0x4e487b71 (arithmetic overflow)
    const valid_panic = "\x4e\x48\x7b\x71" ++ ("\x00" ** 31) ++ "\x11";
    // Huge offset / huge length attacks
    const huge_offset = "\x08\xc3\x79\xa0" ++ ("\xff" ** 32) ++ ("\x00" ** 32);
    const huge_len = "\x08\xc3\x79\xa0" ++ ("\x00" ** 31) ++ "\x20" ++ ("\xff" ** 32);
    try fuzzDecodeRevertReason({}, "");
    try std.testing.fuzz({}, fuzzDecodeRevertReason, .{ .corpus = &.{
        "\x08\xc3\x79\xa0",
        valid_error,
        valid_error[0 .. valid_error.len - 10],
        valid_panic,
        "\x4e\x48\x7b\x71",
        huge_offset,
        huge_len,
    } });
}

fn fuzzPrecompileCompat(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    if (input.len < 4) return;

    const forks = [_]guillotine_mini.Hardfork{
        .FRONTIER,
        .HOMESTEAD,
        .BYZANTIUM,
        .ISTANBUL,
        .BERLIN,
        .LONDON,
        .SHANGHAI,
        .CANCUN,
        .PRAGUE,
        .OSAKA,
    };
    const addrs = [_]u256{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x0100 };

    const fork = forks[input[0] % forks.len];
    const addr_id = addrs[input[1] % addrs.len];
    const gas_limit: u64 = @as(u64, std.mem.readInt(u16, input[2..4], .little)) * 4;
    const payload = input[4..@min(input.len, 1024)];

    const address = primitives.Address.fromU256(addr_id);
    if (precompile_compat.execute(allocator, address, payload, gas_limit, fork)) |res| {
        defer allocator.free(res.output);
        try std.testing.expect(res.gas_used <= gas_limit);

        // Differential checks for deterministic algebraic precompiles.
        if (addr_id == 4) {
            // Identity precompile must return exact input bytes!
            try std.testing.expectEqualSlices(u8, payload, res.output);
        } else if (addr_id == 2) {
            // SHA-256 precompile must match std.crypto.hash.sha2.Sha256!
            var expected: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(payload, &expected, .{});
            try std.testing.expectEqualSlices(u8, &expected, res.output);
        } else if (addr_id == 1) {
            // Ecrecover output is always either 0 bytes or 32 bytes with 12 leading zero bytes.
            try std.testing.expect(res.output.len == 0 or res.output.len == 32);
            if (res.output.len == 32) {
                try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 12), res.output[0..12]);
            }
            try std.testing.expectEqual(@as(u64, 3000), res.gas_used);
        } else if (addr_id == 0x0100 and fork.isAtLeast(.OSAKA)) {
            // P256VERIFY output is always 0 bytes or 32 bytes (0x..01).
            try std.testing.expect(res.output.len == 0 or res.output.len == 32);
            if (res.output.len == 32) {
                try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 31 ++ [_]u8{1}), res.output);
            }
        }
    } else |err| {
        if (err == error.OutOfMemory) return err;
    }
}

test "fuzz: precompile_compat.execute across all precompiles 0x01..0x11 and 0x0100 across Frontier..Osaka" {
    try std.testing.fuzz({}, fuzzPrecompileCompat, .{
        .corpus = &.{
            "\x09\x00\x00\x04" ++ ("\x00" ** 128), // ecrecover
            "\x09\x01\x00\x04hello world", // sha256
            "\x09\x02\x00\x04hello world", // ripemd160
            "\x09\x03\x00\x04identity payload", // identity
            "\x09\x04\x00\x10" ++ ("\x00" ** 31) ++ "\x01" ++ ("\x00" ** 31) ++ "\x01" ++ ("\x00" ** 31) ++ "\x01\x02\x03\x05", // modexp
            "\x09\x05\x00\x10" ++ ("\x00" ** 128), // ecAdd
            "\x09\x06\x00\x10" ++ ("\x00" ** 96), // ecMul
            "\x09\x07\xff\xff" ++ ("\x00" ** 192), // ecPairing
            "\x09\x08\x00\x10" ++ ("\x00" ** 212) ++ "\x01", // blake2f
            "\x09\x09\xff\xff" ++ ("\x00" ** 192), // kzg point eval
            "\x09\x11\xff\xff" ++ ("\x00" ** 160), // P256VERIFY on Osaka
            "\x08\x11\xff\xff" ++ ("\x00" ** 160), // P256VERIFY on Prague
        },
    });
}

test "property: ecrecover precompile recovers exact signer address for random secp256k1 keys and rejects mutations" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xec1e_c0de_2026_0001);
    const random = prng.random();

    for (0..64) |_| {
        var key: crypto.Crypto.PrivateKey = undefined;
        while (true) {
            random.bytes(&key);
            const s = std.mem.readInt(u256, &key, .big);
            if (s != 0 and s < crypto.Crypto.SECP256K1_N) break;
        }
        const pubkey = try std.crypto.ecc.Secp256k1.basePoint.mul(key, .big);
        const uncompressed = pubkey.toUncompressedSec1();
        const digest = primitives.Hash.keccak256(uncompressed[1..]);
        const expected_addr = digest[12..32];

        var msg_hash: [32]u8 = undefined;
        random.bytes(&msg_hash);
        const sig = try crypto.Crypto.unaudited_signHash(msg_hash, key);

        var input = [_]u8{0} ** 128;
        @memcpy(input[0..32], &msg_hash);
        input[63] = sig.v;
        std.mem.writeInt(u256, input[64..96], sig.r, .big);
        std.mem.writeInt(u256, input[96..128], sig.s, .big);

        const res = try precompile_compat.execute(allocator, primitives.Address.fromU256(1), &input, 3000, .OSAKA);
        defer allocator.free(res.output);
        try std.testing.expectEqual(@as(usize, 32), res.output.len);
        try std.testing.expectEqualSlices(u8, expected_addr, res.output[12..32]);

        // OutOfGas at 2999 gas!
        try std.testing.expectError(error.OutOfGas, precompile_compat.execute(allocator, primitives.Address.fromU256(1), &input, 2999, .OSAKA));

        // Invalid v (not 27 or 28) returns empty output without error.
        input[63] = 29;
        const bad_v = try precompile_compat.execute(allocator, primitives.Address.fromU256(1), &input, 3000, .OSAKA);
        defer allocator.free(bad_v.output);
        try std.testing.expectEqual(@as(usize, 0), bad_v.output.len);
    }
}

fn fuzzSimulationRpcPayloads(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    if (input.len == 0 or input.len > 16 * 1024) return;

    var rt = try runtime_mod.NodeRuntime.init(allocator, null);
    defer rt.deinit();

    // Seed a tiny contract so calls that hit address 0x..1000 execute real EVM code.
    const target = primitives.Address.fromU256(0x1000);
    // SLOAD(0), ADD 1, DUP1, SSTORE(0), MSTORE(0), RETURN(0, 32)
    const counter_code = [_]u8{
        0x60, 0x00, 0x54, 0x60, 0x01, 0x01, 0x80, 0x60,
        0x00, 0x55, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60,
        0x00, 0xf3,
    };
    try rt.setCode(target, &counter_code);

    const before_slot = try rt.getStorage(target, 0);
    const before_head = rt.head_block_number;

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const methods = [_][]const u8{
        "eth_call",
        "eth_estimateGas",
        "eth_createAccessList",
        "eth_simulateV1",
    };
    const method = methods[input[0] % methods.len];
    const params_raw = input[1..];

    const request_body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params_raw },
    );
    defer allocator.free(request_body);

    const response_raw = (try rpc_server.handlePost(allocator, request_body, &handlers)) orelse return error.MissingResponse;
    defer allocator.free(response_raw);

    // Every response MUST be valid JSON-RPC 2.0.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_raw, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);

    // CRITICAL ZERO-MUTATION INVARIANT: simulation methods MUST NEVER mutate canonical state!
    try std.testing.expectEqual(before_head, rt.head_block_number);
    try std.testing.expectEqual(before_slot, try rt.getStorage(target, 0));
}

test "fuzz: simulation RPC methods (eth_call, estimateGas, createAccessList, simulateV1) never mutate state or leak" {
    try std.testing.fuzz({}, fuzzSimulationRpcPayloads, .{ .corpus = &.{
        "\x00[{\"to\":\"0x0000000000000000000000000000000000001000\"},\"latest\"]",
        "\x00[{\"to\":\"0x0000000000000000000000000000000000001000\"},\"latest\",{\"0x0000000000000000000000000000000000001000\":{\"stateDiff\":{\"0x0000000000000000000000000000000000000000000000000000000000000000\":\"0x0000000000000000000000000000000000000000000000000000000000000029\"}}}]",
        "\x01[{\"to\":\"0x0000000000000000000000000000000000001000\"}]",
        "\x02[{\"to\":\"0x0000000000000000000000000000000000001000\"},\"latest\"]",
        "\x03[{\"blockStateCalls\":[{\"calls\":[{\"to\":\"0x0000000000000000000000000000000000001000\"}]}]},\"latest\"]",
        "\x04[{\"to\":\"0x0000000000000000000000000000000000001000\"},\"latest\",{\"disableStack\":false,\"enableMemory\":true}]",
        "\x00[{\"data\":\"0x600160005260206000f3\"},\"latest\"]",
        "\x01[{\"data\":\"0x60006000fd\"}]",
        "\x03[{\"blockStateCalls\":[]}]",
        "\x04[{},\"latest\",{\"unknownOption\":true}]",
    } });
}

test "property: metamorphic eth_estimateGas soundness, eth_call zero-mutation and eth_createAccessList equivalence" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x51a0_1a7e_e571_9a50);
    const random = prng.random();

    var rt = try runtime_mod.NodeRuntime.init(allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const sender = runtime_mod.DEFAULT_DEV_ACCOUNTS[0];
    var sender_hex_buf: [42]u8 = undefined;
    const sender_hex = try std.fmt.bufPrint(&sender_hex_buf, "0x{x}", .{&sender.bytes});

    for (0..32) |i| {
        const contract_addr = primitives.Address.fromU256(0x2000 + i);
        var contract_hex_buf: [42]u8 = undefined;
        const contract_hex = try std.fmt.bufPrint(&contract_hex_buf, "0x{x}", .{&contract_addr.bytes});

        const should_revert = (i % 4 == 3);
        const slot_val: u8 = random.intRangeAtMost(u8, 1, 250);
        const loop_writes: u8 = random.intRangeAtMost(u8, 1, 4);

        var code = std.ArrayList(u8).empty;
        defer code.deinit(allocator);

        // Write `loop_writes` storage slots, expand memory slightly, then return or revert.
        for (0..loop_writes) |k| {
            try code.appendSlice(allocator, &.{ 0x60, slot_val +% @as(u8, @intCast(k)), 0x60, @intCast(k), 0x55 });
        }
        // SLOAD slot 0 -> MSTORE 0 -> RETURN(0, 32) or REVERT(0, 32)
        try code.appendSlice(allocator, &.{ 0x60, 0x00, 0x54, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, if (should_revert) 0xfd else 0xf3 });
        try rt.setCode(contract_addr, code.items);

        const snap_before = try rt.getStorage(contract_addr, 0);
        const bal_before = try rt.getBalance(sender);
        const nonce_before = try rt.getNonce(sender);

        // 1. eth_estimateGas
        const est_req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_estimateGas\",\"params\":[{{\"from\":\"{s}\",\"to\":\"{s}\"}}]}}",
            .{ sender_hex, contract_hex },
        );
        defer allocator.free(est_req);
        var est_res = try postRpc(allocator, &handlers, est_req);
        defer est_res.deinit();

        // Zero-mutation check after estimateGas
        try std.testing.expectEqual(snap_before, try rt.getStorage(contract_addr, 0));
        try std.testing.expectEqual(bal_before, try rt.getBalance(sender));
        try std.testing.expectEqual(nonce_before, try rt.getNonce(sender));

        if (should_revert) {
            // Reverting contract MUST cause eth_estimateGas to return an error!
            try std.testing.expect(est_res.value.object.get("error") != null);
            continue;
        }

        try std.testing.expect(est_res.value.object.get("error") == null);
        const estimated_gas = try parseHexU64(est_res.value.object.get("result").?.string);
        try std.testing.expect(estimated_gas >= 21_000);
        try std.testing.expect(estimated_gas <= rt.dev_runtime.config.block_gas_limit);

        // 2. eth_call with the exact estimated gas MUST succeed and return slot_val!
        const call_req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_call\",\"params\":[{{\"from\":\"{s}\",\"to\":\"{s}\",\"gas\":\"0x{x}\"}},\"latest\"]}}",
            .{ sender_hex, contract_hex, estimated_gas },
        );
        defer allocator.free(call_req);
        var call_res = try postRpc(allocator, &handlers, call_req);
        defer call_res.deinit();
        try std.testing.expect(call_res.value.object.get("error") == null);
        const expected_ret = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{slot_val});
        defer allocator.free(expected_ret);
        try std.testing.expectEqualStrings(expected_ret, call_res.value.object.get("result").?.string);

        // Zero-mutation check after eth_call
        try std.testing.expectEqual(snap_before, try rt.getStorage(contract_addr, 0));

        // 3. eth_createAccessList must return valid accessList + gasUsed and leave state unchanged.
        const al_req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"eth_createAccessList\",\"params\":[{{\"from\":\"{s}\",\"to\":\"{s}\"}},\"latest\"]}}",
            .{ sender_hex, contract_hex },
        );
        defer allocator.free(al_req);
        var al_res = try postRpc(allocator, &handlers, al_req);
        defer al_res.deinit();
        try std.testing.expect(al_res.value.object.get("error") == null);
        const al_obj = al_res.value.object.get("result").?.object;
        try std.testing.expect(al_obj.get("accessList").? == .array);
        const al_gas = try parseHexU64(al_obj.get("gasUsed").?.string);
        try std.testing.expect(al_gas >= 21_000);
        try std.testing.expectEqual(snap_before, try rt.getStorage(contract_addr, 0));

        // 4. Actually mine the tx with the exact estimated gas — MUST succeed on-chain!
        const send_req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"eth_sendTransaction\",\"params\":[{{\"from\":\"{s}\",\"to\":\"{s}\",\"gas\":\"0x{x}\"}}]}}",
            .{ sender_hex, contract_hex, estimated_gas },
        );
        defer allocator.free(send_req);
        var send_res = try postRpc(allocator, &handlers, send_req);
        defer send_res.deinit();
        try std.testing.expect(send_res.value.object.get("error") == null);
        const tx_hash = send_res.value.object.get("result").?.string;

        const rcpt_req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"eth_getTransactionReceipt\",\"params\":[\"{s}\"]}}",
            .{tx_hash},
        );
        defer allocator.free(rcpt_req);
        var rcpt_res = try postRpc(allocator, &handlers, rcpt_req);
        defer rcpt_res.deinit();
        const rcpt = rcpt_res.value.object.get("result").?.object;
        try std.testing.expectEqualStrings("0x1", rcpt.get("status").?.string);
        const actual_gas = try parseHexU64(rcpt.get("gasUsed").?.string);
        try std.testing.expect(actual_gas <= estimated_gas);
        try std.testing.expectEqual(@as(u256, slot_val), try rt.getStorage(contract_addr, 0));
    }
}

test "property: DELEGATECALL preserves CALLVALUE for arbitrary nonzero values" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xde1e_9a7e_0034_cafe);
    const random = prng.random();

    var rt = try runtime_mod.NodeRuntime.init(allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    // Delegate target: CALLVALUE (0x34), PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    const target_addr = primitives.Address.fromU256(0x9001);
    const target_code = [_]u8{ 0x34, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    try rt.setCode(target_addr, &target_code);

    // Caller proxy: DELEGATECALL(gas, 0x9001, 0, 0, 0, 32) -> RETURN(0, 32)
    const proxy_addr = primitives.Address.fromU256(0x9002);
    const proxy_code = [_]u8{
        0x60, 0x20, // retSize = 32
        0x60, 0x00, // retOffset = 0
        0x60, 0x00, // argsSize = 0
        0x60, 0x00, // argsOffset = 0
        0x61, 0x90, 0x01, // addr = 0x9001
        0x5a, // GAS
        0xf4, // DELEGATECALL
        0x50, // POP
        0x60, 0x20, 0x60, 0x00, 0xf3, // RETURN(0, 32)
    };
    try rt.setCode(proxy_addr, &proxy_code);

    const sender = runtime_mod.DEFAULT_DEV_ACCOUNTS[0];
    var sender_hex_buf: [42]u8 = undefined;
    const sender_hex = try std.fmt.bufPrint(&sender_hex_buf, "0x{x}", .{&sender.bytes});

    for (0..32) |_| {
        const value: u64 = 1 + random.int(u48);
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{{\"from\":\"{s}\",\"to\":\"0x0000000000000000000000000000000000009002\",\"value\":\"0x{x}\"}},\"latest\"]}}",
            .{ sender_hex, value },
        );
        defer allocator.free(req);
        var res = try postRpc(allocator, &handlers, req);
        defer res.deinit();
        try std.testing.expect(res.value.object.get("error") == null);
        const expected = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{value});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, res.value.object.get("result").?.string);
    }
}

test "property: 0-value self-CALL reads CALLVALUE 0 for arbitrary nonzero outer values" {
    // Regression for the removed CALLVALUE opcode override. It treated any
    // 0-value frame whose parent shared its address and caller as a
    // DELEGATECALL and returned the parent's value. A 0-value CALL to self
    // from a transaction sent by the contract address itself matches that
    // shape, so the inner frame read the outer value instead of 0.
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5e1f_ca11_0034_0000);
    const random = prng.random();

    var rt = try runtime_mod.NodeRuntime.init(allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    // Outer frame (calldata empty): CALL(gas, self, 0, 0, 1, 0, 32) then
    // RETURN(0, 32). Inner frame (calldata non-empty): return CALLVALUE.
    const self_addr = primitives.Address.fromU256(0x9003);
    const self_code = [_]u8{
        0x36, // CALLDATASIZE
        0x60, 0x19, // PUSH1 inner (25)
        0x57, // JUMPI
        0x60, 0x20, // retSize = 32
        0x60, 0x00, // retOffset = 0
        0x60, 0x01, // argsSize = 1 (marks the inner frame)
        0x60, 0x00, // argsOffset = 0
        0x60, 0x00, // value = 0
        0x30, // ADDRESS (self)
        0x5a, // GAS
        0xf1, // CALL
        0x50, // POP
        0x60, 0x20, 0x60, 0x00, 0xf3, // RETURN(0, 32)
        0xfe, // INVALID (unreachable padding)
        0xfe,
        0x5b, // JUMPDEST inner (offset 25)
        0x34, // CALLVALUE
        0x60, 0x00, 0x52, // MSTORE(0, callvalue)
        0x60, 0x20, 0x60, 0x00, 0xf3, // RETURN(0, 32)
    };
    comptime std.debug.assert(self_code[25] == 0x5b);
    try rt.setCode(self_addr, &self_code);

    const zero_word = "0x" ++ "0" ** 64;
    const senders = [_][]const u8{
        // Contract calls itself as the transaction sender: parent and child
        // share both address and caller, the shape the old override misread.
        "0x0000000000000000000000000000000000009003",
        // Ordinary external sender.
        "0x0000000000000000000000000000000000009004",
    };

    for (0..16) |_| {
        const value: u64 = 1 + random.int(u48);
        for (senders) |sender_hex| {
            const req = try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{{\"from\":\"{s}\",\"to\":\"0x0000000000000000000000000000000000009003\",\"value\":\"0x{x}\"}},\"latest\",{{\"{s}\":{{\"balance\":\"0xffffffffffffffffffff\"}}}}]}}",
                .{ sender_hex, value, sender_hex },
            );
            defer allocator.free(req);
            var res = try postRpc(allocator, &handlers, req);
            defer res.deinit();
            try std.testing.expect(res.value.object.get("error") == null);
            try std.testing.expectEqualStrings(zero_word, res.value.object.get("result").?.string);
        }
    }
}
