const std = @import("std");
const beacon_api = @import("beacon_api.zig");

test "hexToBytes parses 20/32/48/96 byte values" {
    const value_20 = [_]u8{0x11} ** 20;
    const value_20_hex = beacon_api.bytesToHex(20, value_20);
    const parsed_20 = try beacon_api.hexToBytes(20, value_20_hex[0..]);
    try std.testing.expectEqualSlices(u8, &value_20, &parsed_20);

    const value_32 = [_]u8{0x22} ** 32;
    const value_32_hex = beacon_api.bytesToHex(32, value_32);
    const parsed_32 = try beacon_api.hexToBytes(32, value_32_hex[0..]);
    try std.testing.expectEqualSlices(u8, &value_32, &parsed_32);

    const value_48 = [_]u8{0x33} ** 48;
    const value_48_hex = beacon_api.bytesToHex(48, value_48);
    const parsed_48 = try beacon_api.hexToBytes(48, value_48_hex[0..]);
    try std.testing.expectEqualSlices(u8, &value_48, &parsed_48);

    const value_96 = [_]u8{0x44} ** 96;
    const value_96_hex = beacon_api.bytesToHex(96, value_96);
    const parsed_96 = try beacon_api.hexToBytes(96, value_96_hex[0..]);
    try std.testing.expectEqualSlices(u8, &value_96, &parsed_96);
}

test "parseU64 parses valid and edge decimal strings" {
    try std.testing.expectEqual(@as(u64, 0), try beacon_api.parseU64("0"));
    try std.testing.expectEqual(@as(u64, 42), try beacon_api.parseU64("42"));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), try beacon_api.parseU64("18446744073709551615"));
    try std.testing.expectError(error.InvalidDecimalValue, beacon_api.parseU64("18446744073709551616"));
}

test "bytesToHex encodes to 0x-prefixed lowercase string" {
    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const encoded = beacon_api.bytesToHex(4, bytes);
    try std.testing.expectEqualStrings("0xdeadbeef", encoded[0..]);
}

test "url building for bootstrap updates finality and optimistic endpoints" {
    const client = beacon_api.BeaconApi{
        .endpoint_url = "https://ethereum.operationsolarstorm.org/",
    };

    const checkpoint = [_]u8{0xaa} ** 32;
    const checkpoint_hex = beacon_api.bytesToHex(32, checkpoint);

    const bootstrap_url = try client.buildBootstrapUrl(std.testing.allocator, checkpoint);
    defer std.testing.allocator.free(bootstrap_url);
    const expected_bootstrap_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "https://ethereum.operationsolarstorm.org/eth/v1/beacon/light_client/bootstrap/{s}",
        .{checkpoint_hex[0..]},
    );
    defer std.testing.allocator.free(expected_bootstrap_url);
    try std.testing.expectEqualStrings(expected_bootstrap_url, bootstrap_url);

    const updates_url = try client.buildUpdatesUrl(std.testing.allocator, 1234, 16);
    defer std.testing.allocator.free(updates_url);
    try std.testing.expectEqualStrings(
        "https://ethereum.operationsolarstorm.org/eth/v1/beacon/light_client/updates?start_period=1234&count=16",
        updates_url,
    );

    const finality_url = try client.buildFinalityUpdateUrl(std.testing.allocator);
    defer std.testing.allocator.free(finality_url);
    try std.testing.expectEqualStrings(
        "https://ethereum.operationsolarstorm.org/eth/v1/beacon/light_client/finality_update",
        finality_url,
    );

    const optimistic_url = try client.buildOptimisticUpdateUrl(std.testing.allocator);
    defer std.testing.allocator.free(optimistic_url);
    try std.testing.expectEqualStrings(
        "https://ethereum.operationsolarstorm.org/eth/v1/beacon/light_client/optimistic_update",
        optimistic_url,
    );
}

test "parse optimistic update json response" {
    const beacon_parent_root = beacon_api.bytesToHex(32, [_]u8{0x01} ** 32);
    const beacon_state_root = beacon_api.bytesToHex(32, [_]u8{0x02} ** 32);
    const beacon_body_root = beacon_api.bytesToHex(32, [_]u8{0x03} ** 32);

    const execution_parent_hash = beacon_api.bytesToHex(32, [_]u8{0x04} ** 32);
    const execution_fee_recipient = beacon_api.bytesToHex(20, [_]u8{0x05} ** 20);
    const execution_state_root = beacon_api.bytesToHex(32, [_]u8{0x06} ** 32);
    const execution_receipts_root = beacon_api.bytesToHex(32, [_]u8{0x07} ** 32);
    const execution_logs_bloom = beacon_api.bytesToHex(256, [_]u8{0x08} ** 256);
    const execution_prev_randao = beacon_api.bytesToHex(32, [_]u8{0x09} ** 32);
    const execution_block_hash = beacon_api.bytesToHex(32, [_]u8{0x0a} ** 32);
    const execution_transactions_root = beacon_api.bytesToHex(32, [_]u8{0x0b} ** 32);
    const execution_withdrawals_root = beacon_api.bytesToHex(32, [_]u8{0x0c} ** 32);

    const execution_branch_0 = beacon_api.bytesToHex(32, [_]u8{0x0d} ** 32);
    const execution_branch_1 = beacon_api.bytesToHex(32, [_]u8{0x0e} ** 32);
    const execution_branch_2 = beacon_api.bytesToHex(32, [_]u8{0x0f} ** 32);
    const execution_branch_3 = beacon_api.bytesToHex(32, [_]u8{0x10} ** 32);

    const sync_committee_bits = [_]u8{0xaa} ** 64;
    const sync_committee_bits_hex = beacon_api.bytesToHex(64, sync_committee_bits);
    const sync_committee_signature = [_]u8{0xbb} ** 96;
    const sync_committee_signature_hex = beacon_api.bytesToHex(96, sync_committee_signature);

    var json_builder = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json_builder.deinit();
    const json_writer = &json_builder.writer;

    try json_writer.writeAll("{\"data\":{\"attested_header\":{\"beacon\":{\"slot\":\"8000000\",\"proposer_index\":\"123\",\"parent_root\":\"");
    try json_writer.writeAll(beacon_parent_root[0..]);
    try json_writer.writeAll("\",\"state_root\":\"");
    try json_writer.writeAll(beacon_state_root[0..]);
    try json_writer.writeAll("\",\"body_root\":\"");
    try json_writer.writeAll(beacon_body_root[0..]);
    try json_writer.writeAll("\"},\"execution\":{\"parent_hash\":\"");
    try json_writer.writeAll(execution_parent_hash[0..]);
    try json_writer.writeAll("\",\"fee_recipient\":\"");
    try json_writer.writeAll(execution_fee_recipient[0..]);
    try json_writer.writeAll("\",\"state_root\":\"");
    try json_writer.writeAll(execution_state_root[0..]);
    try json_writer.writeAll("\",\"receipts_root\":\"");
    try json_writer.writeAll(execution_receipts_root[0..]);
    try json_writer.writeAll("\",\"logs_bloom\":\"");
    try json_writer.writeAll(execution_logs_bloom[0..]);
    try json_writer.writeAll("\",\"prev_randao\":\"");
    try json_writer.writeAll(execution_prev_randao[0..]);
    try json_writer.writeAll("\",\"block_number\":\"9000000\",\"gas_limit\":\"30000000\",\"gas_used\":\"12000000\",\"timestamp\":\"1700000000\",\"base_fee_per_gas\":\"1000000000\",\"block_hash\":\"");
    try json_writer.writeAll(execution_block_hash[0..]);
    try json_writer.writeAll("\",\"transactions_root\":\"");
    try json_writer.writeAll(execution_transactions_root[0..]);
    try json_writer.writeAll("\",\"withdrawals_root\":\"");
    try json_writer.writeAll(execution_withdrawals_root[0..]);
    try json_writer.writeAll("\",\"blob_gas_used\":\"0\",\"excess_blob_gas\":\"0\"},\"execution_branch\":[\"");
    try json_writer.writeAll(execution_branch_0[0..]);
    try json_writer.writeAll("\",\"");
    try json_writer.writeAll(execution_branch_1[0..]);
    try json_writer.writeAll("\",\"");
    try json_writer.writeAll(execution_branch_2[0..]);
    try json_writer.writeAll("\",\"");
    try json_writer.writeAll(execution_branch_3[0..]);
    try json_writer.writeAll("\"]},\"sync_aggregate\":{\"sync_committee_bits\":\"");
    try json_writer.writeAll(sync_committee_bits_hex[0..]);
    try json_writer.writeAll("\",\"sync_committee_signature\":\"");
    try json_writer.writeAll(sync_committee_signature_hex[0..]);
    try json_writer.writeAll("\"},\"signature_slot\":\"8000001\"}}");

    const json_fixture = try json_builder.toOwnedSlice();
    defer std.testing.allocator.free(json_fixture);

    const optimistic_update = try beacon_api.parseOptimisticUpdateResponse(std.testing.allocator, json_fixture);
    try std.testing.expectEqual(@as(u64, 8_000_000), optimistic_update.attested_header.beacon.slot);
    try std.testing.expectEqual(@as(u64, 123), optimistic_update.attested_header.beacon.proposer_index);
    try std.testing.expectEqual(@as(u64, 8_000_001), optimistic_update.signature_slot);
    try std.testing.expectEqualSlices(u8, &sync_committee_bits, &optimistic_update.sync_committee_bits);
    try std.testing.expectEqualSlices(u8, &sync_committee_signature, &optimistic_update.sync_committee_signature);
}
