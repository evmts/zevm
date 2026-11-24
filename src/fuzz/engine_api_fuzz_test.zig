const std = @import("std");
const runtime_mod = @import("../node/runtime.zig");
const dispatcher = @import("../rpc/dispatcher.zig");
const dispatch_wiring = @import("../rpc/dispatch_wiring.zig");
const rpc_server = @import("../rpc/server.zig");
const block_spec = @import("../rpc/handlers/block_spec.zig");

fn postRpc(
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    body: []const u8,
) !std.json.Parsed(std.json.Value) {
    const raw = (try rpc_server.handlePost(allocator, body, handlers)) orelse return error.MissingResponse;
    defer allocator.free(raw);
    return try std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always });
}

fn fuzzEngineApiRaw(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    if (input.len == 0 or input.len > 16 * 1024) return;

    var rt = try runtime_mod.NodeRuntime.init(allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const methods = [_][]const u8{
        "engine_getClientVersionV1",
        "engine_exchangeCapabilities",
        "engine_exchangeTransitionConfigurationV1",
        "engine_forkchoiceUpdatedV1",
        "engine_forkchoiceUpdatedV2",
        "engine_forkchoiceUpdatedV3",
        "engine_forkchoiceUpdatedV4",
        "engine_newPayloadV1",
        "engine_newPayloadV2",
        "engine_newPayloadV3",
        "engine_newPayloadV4",
        "engine_getPayloadV1",
        "engine_getPayloadV2",
        "engine_getPayloadV3",
        "engine_getPayloadV4",
        "engine_getPayloadV5",
        "engine_getPayloadBodiesByHashV1",
        "engine_getPayloadBodiesByHashV2",
        "engine_getPayloadBodiesByRangeV1",
        "engine_getPayloadBodiesByRangeV2",
        "engine_getBlobsV1",
        "engine_getBlobsV2",
        "engine_getBlobsV3",
        "testing_buildBlockV1",
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

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_raw, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
}

test "fuzz: Engine API and testing_buildBlockV1 JSON-RPC methods on arbitrary payloads" {
    const z32 = "0x" ++ ("00" ** 32);
    const z20 = "0x" ++ ("00" ** 20);
    try std.testing.fuzz({}, fuzzEngineApiRaw, .{ .corpus = &.{
        "\x00[{\"code\":\"CL\",\"name\":\"fuzz\",\"version\":\"v0.1\",\"commit\":\"0x01020304\"}]",
        "\x01[[\"engine_newPayloadV3\",\"engine_forkchoiceUpdatedV3\"]]",
        "\x02[{\"terminalTotalDifficulty\":\"0x0\",\"terminalBlockHash\":\"" ++ z32 ++ "\",\"terminalBlockNumber\":\"0x0\"}]",
        "\x05[{\"headBlockHash\":\"" ++ z32 ++ "\",\"safeBlockHash\":\"" ++ z32 ++ "\",\"finalizedBlockHash\":\"" ++ z32 ++ "\"},null]",
        "\x05[{\"headBlockHash\":\"" ++ z32 ++ "\",\"safeBlockHash\":\"" ++ z32 ++ "\",\"finalizedBlockHash\":\"" ++ z32 ++ "\"},{\"timestamp\":\"0x10\",\"prevRandao\":\"" ++ z32 ++ "\",\"suggestedFeeRecipient\":\"" ++ z20 ++ "\",\"withdrawals\":[],\"parentBeaconBlockRoot\":\"" ++ z32 ++ "\"}]",
        "\x09[{},[],\"" ++ z32 ++ "\"]",
        "\x0a[{},[],\"" ++ z32 ++ "\",[]]",
        "\x0d[\"0x0000000000000001\"]",
        "\x10[[\"" ++ z32 ++ "\"]]",
        "\x12[\"0x0\",\"0x2\"]",
        "\x14[[\"" ++ z32 ++ "\"]]",
        "\x16[[\"" ++ z32 ++ "\"]]",
        "\x17[{\"parentBlockHash\":\"" ++ z32 ++ "\",\"payloadAttributes\":{\"timestamp\":\"0x10\",\"prevRandao\":\"" ++ z32 ++ "\",\"suggestedFeeRecipient\":\"" ++ z20 ++ "\",\"withdrawals\":[],\"parentBeaconBlockRoot\":\"" ++ z32 ++ "\"}}]",
    } });
}

test "property: Engine API forkchoice -> getPayload -> newPayload -> forkchoice lifecycle and tamper rejection" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xe491_4e00_7c03_0001);
    const random = prng.random();

    var rt = try runtime_mod.NodeRuntime.init(allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var timestamp: u64 = 12;
    var finalized_hash = (try rt.blockchain.getCanonicalHeadBlock()).hash;
    var safe_hash = finalized_hash;

    for (0..10) |step| {
        const head = try rt.blockchain.getCanonicalHeadBlock();
        var head_hex_buf: [66]u8 = undefined;
        var safe_hex_buf: [66]u8 = undefined;
        var fin_hex_buf: [66]u8 = undefined;
        const head_hex = try std.fmt.bufPrint(&head_hex_buf, "0x{x}", .{&head.hash});
        const safe_hex = try std.fmt.bufPrint(&safe_hex_buf, "0x{x}", .{&safe_hash});
        const fin_hex = try std.fmt.bufPrint(&fin_hex_buf, "0x{x}", .{&finalized_hash});

        var prev_randao: [32]u8 = undefined;
        var beacon_root: [32]u8 = undefined;
        var fee_recipient: [20]u8 = undefined;
        random.bytes(&prev_randao);
        random.bytes(&beacon_root);
        random.bytes(&fee_recipient);
        fee_recipient[0] |= 1;

        var randao_buf: [66]u8 = undefined;
        var beacon_buf: [66]u8 = undefined;
        var fee_buf: [42]u8 = undefined;
        const randao_hex = try std.fmt.bufPrint(&randao_buf, "0x{x}", .{&prev_randao});
        const beacon_hex = try std.fmt.bufPrint(&beacon_buf, "0x{x}", .{&beacon_root});
        const fee_hex = try std.fmt.bufPrint(&fee_buf, "0x{x}", .{&fee_recipient});

        // 1. Trigger payload build via engine_forkchoiceUpdatedV3.
        const fcu_build = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"engine_forkchoiceUpdatedV3\",\"params\":[{{\"headBlockHash\":\"{s}\",\"safeBlockHash\":\"{s}\",\"finalizedBlockHash\":\"{s}\"}},{{\"timestamp\":\"0x{x}\",\"prevRandao\":\"{s}\",\"suggestedFeeRecipient\":\"{s}\",\"withdrawals\":[],\"parentBeaconBlockRoot\":\"{s}\"}}]}}",
            .{ head_hex, safe_hex, fin_hex, timestamp, randao_hex, fee_hex, beacon_hex },
        );
        defer allocator.free(fcu_build);

        var fcu_res = try postRpc(allocator, &handlers, fcu_build);
        defer fcu_res.deinit();
        try std.testing.expect(fcu_res.value.object.get("error") == null);
        const fcu_obj = fcu_res.value.object.get("result").?.object;
        const status_obj = fcu_obj.get("payloadStatus").?.object;
        try std.testing.expectEqualStrings("VALID", status_obj.get("status").?.string);
        const payload_id = fcu_obj.get("payloadId").?.string;

        // 2. Fetch payload via engine_getPayloadV3.
        const get_req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"engine_getPayloadV3\",\"params\":[\"{s}\"]}}",
            .{payload_id},
        );
        defer allocator.free(get_req);
        var get_res = try postRpc(allocator, &handlers, get_req);
        defer get_res.deinit();
        try std.testing.expect(get_res.value.object.get("error") == null);
        const exec_payload = get_res.value.object.get("result").?.object.get("executionPayload").?;
        const built_block_hash = exec_payload.object.get("blockHash").?.string;

        // 3. Tamper test on odd steps: mutating stateRoot MUST NOT be accepted as VALID!
        if (step % 2 == 1) {
            const payload_json = try std.json.Stringify.valueAlloc(allocator, exec_payload, .{});
            defer allocator.free(payload_json);
            // Flip the last hex nibble of blockHash inside the serialized payload.
            const tampered_req = try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"engine_newPayloadV3\",\"params\":[{s},[],\"{s}\"]}}",
                .{ payload_json, beacon_hex },
            );
            defer allocator.free(tampered_req);
            // Tamper the parentBeaconBlockRoot so it mismatches the built block header!
            var bad_beacon = beacon_root;
            bad_beacon[31] ^= 0xff;
            var bad_beacon_buf: [66]u8 = undefined;
            const bad_beacon_hex = try std.fmt.bufPrint(&bad_beacon_buf, "0x{x}", .{&bad_beacon});
            const bad_req = try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"engine_newPayloadV3\",\"params\":[{s},[],\"{s}\"]}}",
                .{ payload_json, bad_beacon_hex },
            );
            defer allocator.free(bad_req);
            var bad_res = try postRpc(allocator, &handlers, bad_req);
            defer bad_res.deinit();
            if (bad_res.value.object.get("result")) |r_val| {
                const st = r_val.object.get("status").?.string;
                try std.testing.expect(!std.mem.eql(u8, st, "VALID"));
            }
        }

        // 4. Submit authentic payload via engine_newPayloadV3 -> MUST return VALID!
        const payload_json = try std.json.Stringify.valueAlloc(allocator, exec_payload, .{});
        defer allocator.free(payload_json);
        const new_req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"engine_newPayloadV3\",\"params\":[{s},[],\"{s}\"]}}",
            .{ payload_json, beacon_hex },
        );
        defer allocator.free(new_req);
        var new_res = try postRpc(allocator, &handlers, new_req);
        defer new_res.deinit();
        try std.testing.expect(new_res.value.object.get("error") == null);
        try std.testing.expectEqualStrings("VALID", new_res.value.object.get("result").?.object.get("status").?.string);

        // 5. Advance canonical head/safe/finalized via engine_forkchoiceUpdatedV3.
        const fcu_apply = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"engine_forkchoiceUpdatedV3\",\"params\":[{{\"headBlockHash\":\"{s}\",\"safeBlockHash\":\"{s}\",\"finalizedBlockHash\":\"{s}\"}},null]}}",
            .{ built_block_hash, head_hex, safe_hex },
        );
        defer allocator.free(fcu_apply);
        var apply_res = try postRpc(allocator, &handlers, fcu_apply);
        defer apply_res.deinit();
        try std.testing.expect(apply_res.value.object.get("error") == null);
        try std.testing.expectEqualStrings("VALID", apply_res.value.object.get("result").?.object.get("payloadStatus").?.object.get("status").?.string);

        // Verify head advanced by 1 and safe/finalized block specs resolve coherently!
        try std.testing.expectEqual(@as(u64, step + 1), rt.head_block_number);
        const safe_num = try block_spec.resolveBlockNumber(&rt, .{ .value = .{ .string = "safe" } });
        const fin_num = try block_spec.resolveBlockNumber(&rt, .{ .value = .{ .string = "finalized" } });
        try std.testing.expect(fin_num <= safe_num);
        try std.testing.expect(safe_num <= rt.head_block_number);

        // 6. Query engine_getPayloadBodiesByHashV1 for the newly applied block.
        const bodies_req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"engine_getPayloadBodiesByHashV1\",\"params\":[[\"{s}\"]]}}",
            .{built_block_hash},
        );
        defer allocator.free(bodies_req);
        var bodies_res = try postRpc(allocator, &handlers, bodies_req);
        defer bodies_res.deinit();
        try std.testing.expect(bodies_res.value.object.get("error") == null);
        try std.testing.expectEqual(@as(usize, 1), bodies_res.value.object.get("result").?.array.items.len);
        try std.testing.expect(bodies_res.value.object.get("result").?.array.items[0] == .object);

        finalized_hash = safe_hash;
        safe_hash = head.hash;
        timestamp += 12;
    }
}
