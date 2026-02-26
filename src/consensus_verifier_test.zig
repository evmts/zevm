const std = @import("std");
const primitives = @import("primitives");
const consensus_verifier = @import("consensus_verifier.zig");

fn fixtureHeader(slot: u64, marker: u8) primitives.LightClientHeader.LightClientHeader {
    return primitives.LightClientHeader.LightClientHeader.from(
        primitives.LightClientHeader.LightClientHeader.BeaconBlockHeader.from(
            slot,
            slot + 1,
            [_]u8{marker} ** 32,
            [_]u8{marker +% 1} ** 32,
            [_]u8{marker +% 2} ** 32,
        ),
        primitives.LightClientHeader.LightClientHeader.ExecutionPayloadHeaderFields.from(
            [_]u8{marker +% 3} ** 32,
            [_]u8{marker +% 4} ** 20,
            [_]u8{marker +% 5} ** 32,
            [_]u8{marker +% 6} ** 32,
            [_]u8{marker +% 7} ** 256,
            [_]u8{marker +% 8} ** 32,
            slot + 10,
            30_000_000,
            15_000_000,
            1_700_000_000 + slot,
            @as(u256, marker) + 1,
            [_]u8{marker +% 9} ** 32,
            [_]u8{marker +% 10} ** 32,
            [_]u8{marker +% 11} ** 32,
            slot + 12,
            slot + 13,
        ),
        [_][32]u8{[_]u8{marker +% 12} ** 32} ** 4,
    );
}

fn fixtureCommitteePubkeys(marker: u8) [512][48]u8 {
    var pubkeys = [_][48]u8{[_]u8{0} ** 48} ** 512;

    for (0..512) |i| {
        for (0..48) |j| {
            const value = i * 3 + j;
            pubkeys[i][j] = marker +% @as(u8, @truncate(value));
        }
    }

    return pubkeys;
}

fn setFirstParticipants(bits: *[64]u8, count: usize) void {
    @memset(bits, 0);
    var i: usize = 0;
    while (i < count and i < 512) : (i += 1) {
        const byte_index = i / 8;
        const bit_index: u3 = @intCast(i % 8);
        bits[byte_index] |= @as(u8, 1) << bit_index;
    }
}

fn canonicalBeacon(
    beacon: primitives.LightClientHeader.LightClientHeader.BeaconBlockHeader,
) primitives.BeaconBlockHeader.BeaconBlockHeader {
    return primitives.BeaconBlockHeader.BeaconBlockHeader.from(
        beacon.slot,
        beacon.proposer_index,
        beacon.parent_root,
        beacon.state_root,
        beacon.body_root,
    );
}

test "computeDomain with known inputs" {
    const domain_type: [4]u8 = .{ 0x11, 0x22, 0x33, 0x44 };
    const fork_data_root: [32]u8 = .{
        0x00, 0x01, 0x02, 0x03,
        0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B,
        0x0C, 0x0D, 0x0E, 0x0F,
        0x10, 0x11, 0x12, 0x13,
        0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B,
        0x1C, 0x1D, 0x1E, 0x1F,
    };

    const actual = consensus_verifier.computeDomain(domain_type, fork_data_root);

    const expected: [32]u8 = .{
        0x11, 0x22, 0x33, 0x44,
        0x00, 0x01, 0x02, 0x03,
        0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B,
        0x0C, 0x0D, 0x0E, 0x0F,
        0x10, 0x11, 0x12, 0x13,
        0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B,
    };

    try std.testing.expectEqualSlices(u8, expected[0..], actual[0..]);
}

test "computeForkDataRoot" {
    const fork_version: [4]u8 = .{ 0xAA, 0xBB, 0xCC, 0xDD };
    const genesis_validators_root: [32]u8 = [_]u8{0x55} ** 32;

    const actual = try consensus_verifier.computeForkDataRoot(fork_version, genesis_validators_root);

    var fork_version_root: [32]u8 = [_]u8{0} ** 32;
    @memcpy(fork_version_root[0..4], fork_version[0..]);
    const expected = primitives.Ssz.merkle.hashPair(fork_version_root, genesis_validators_root);

    try std.testing.expectEqualSlices(u8, expected[0..], actual[0..]);
}

test "computeSigningRoot" {
    const object_root: [32]u8 = [_]u8{0x0A} ** 32;
    const domain: [32]u8 = [_]u8{0x0B} ** 32;

    const actual = consensus_verifier.computeSigningRoot(object_root, domain);
    const expected = primitives.Ssz.merkle.hashPair(object_root, domain);

    try std.testing.expectEqualSlices(u8, expected[0..], actual[0..]);
}

test "computeCommitteeSignRoot" {
    const header_root: [32]u8 = [_]u8{0xAA} ** 32;
    const fork_data_root: [32]u8 = [_]u8{0xBB} ** 32;

    const actual = consensus_verifier.computeCommitteeSignRoot(header_root, fork_data_root);

    const domain = consensus_verifier.computeDomain(.{ 7, 0, 0, 0 }, fork_data_root);
    const expected = consensus_verifier.computeSigningRoot(header_root, domain);

    try std.testing.expectEqualSlices(u8, expected[0..], actual[0..]);
}

test "getParticipatingKeys with various bit patterns" {
    var committee_pubkeys = [_][48]u8{[_]u8{0} ** 48} ** 512;
    for (0..512) |i| {
        committee_pubkeys[i][0] = @as(u8, @truncate(i));
        committee_pubkeys[i][1] = @as(u8, @truncate(i >> 8));
    }

    const empty_bits = [_]u8{0} ** 64;
    const no_participants = consensus_verifier.getParticipatingKeys(committee_pubkeys, empty_bits);
    try std.testing.expectEqual(@as(usize, 0), no_participants.len);

    var mixed_bits = [_]u8{0} ** 64;
    mixed_bits[0] |= 1 << 0; // index 0
    mixed_bits[1] |= 1 << 1; // index 9
    mixed_bits[63] |= 1 << 7; // index 511

    const mixed = consensus_verifier.getParticipatingKeys(committee_pubkeys, mixed_bits);
    try std.testing.expectEqual(@as(usize, 3), mixed.len);
    try std.testing.expectEqualSlices(u8, committee_pubkeys[0][0..], mixed.get(0)[0..]);
    try std.testing.expectEqualSlices(u8, committee_pubkeys[9][0..], mixed.get(1)[0..]);
    try std.testing.expectEqualSlices(u8, committee_pubkeys[511][0..], mixed.get(2)[0..]);

    const full_bits = [_]u8{0xFF} ** 64;
    const full = consensus_verifier.getParticipatingKeys(committee_pubkeys, full_bits);
    try std.testing.expectEqual(@as(usize, 512), full.len);
}

test "applyBootstrap initializes store correctly" {
    const bootstrap_header = fixtureHeader(96, 10);
    const bootstrap_pubkeys = fixtureCommitteePubkeys(0x20);
    const bootstrap_aggregate_pubkey: [48]u8 = [_]u8{0x33} ** 48;
    const bootstrap_branch: [5][32]u8 = [_][32]u8{[_]u8{0x44} ** 32} ** 5;

    const bootstrap = primitives.LightClientUpdate.LightClientBootstrap.from(
        bootstrap_header,
        bootstrap_pubkeys,
        bootstrap_aggregate_pubkey,
        bootstrap_branch,
    );

    var store = primitives.LightClientUpdate.LightClientStore.from(
        fixtureHeader(10, 1),
        fixtureCommitteePubkeys(2),
        [_]u8{3} ** 48,
        fixtureCommitteePubkeys(4),
        [_]u8{5} ** 48,
        fixtureHeader(11, 6),
        111,
        222,
    );

    consensus_verifier.applyBootstrap(&store, bootstrap);

    try std.testing.expect(store.finalized_header.equals(bootstrap.header));
    try std.testing.expect(store.optimistic_header.equals(bootstrap.header));
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&bootstrap.current_sync_committee_pubkeys),
        std.mem.asBytes(&store.current_sync_committee_pubkeys),
    );
    try std.testing.expectEqualSlices(
        u8,
        bootstrap.current_sync_committee_aggregate_pubkey[0..],
        store.current_sync_committee_aggregate_pubkey[0..],
    );
    try std.testing.expect(store.next_sync_committee_pubkeys == null);
    try std.testing.expect(store.next_sync_committee_aggregate_pubkey == null);
    try std.testing.expectEqual(@as(u64, 0), store.previous_max_active_participants);
    try std.testing.expectEqual(@as(u64, 0), store.current_max_active_participants);
}

test "applyUpdate handles majority and non-majority correctly" {
    var store = primitives.LightClientUpdate.LightClientStore.from(
        fixtureHeader(64, 1),
        fixtureCommitteePubkeys(2),
        [_]u8{3} ** 48,
        null,
        null,
        fixtureHeader(64, 1),
        0,
        0,
    );

    var low_bits = [_]u8{0} ** 64;
    setFirstParticipants(&low_bits, 20);
    const low_update = primitives.LightClientUpdate.GenericUpdate.from(
        fixtureHeader(65, 10),
        low_bits,
        [_]u8{0x11} ** 96,
        66,
        null,
        null,
        null,
        fixtureHeader(80, 11),
        null,
    );

    const low_checkpoint = consensus_verifier.applyUpdate(&store, low_update);
    try std.testing.expect(low_checkpoint == null);
    try std.testing.expectEqual(@as(u64, 64), store.finalized_header.beacon.slot);
    try std.testing.expectEqual(@as(u64, 65), store.optimistic_header.beacon.slot);

    var majority_bits = [_]u8{0} ** 64;
    setFirstParticipants(&majority_bits, 342);
    const majority_update = primitives.LightClientUpdate.GenericUpdate.from(
        fixtureHeader(100, 12),
        majority_bits,
        [_]u8{0x22} ** 96,
        101,
        null,
        null,
        null,
        fixtureHeader(96, 13),
        null,
    );

    const maybe_checkpoint = consensus_verifier.applyUpdate(&store, majority_update);
    try std.testing.expect(maybe_checkpoint != null);
    try std.testing.expectEqual(@as(u64, 96), store.finalized_header.beacon.slot);
    try std.testing.expectEqual(@as(u64, 100), store.optimistic_header.beacon.slot);

    const expected_checkpoint = try canonicalBeacon(store.finalized_header.beacon).hashTreeRoot(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, expected_checkpoint[0..], maybe_checkpoint.?[0..]);
}

test "safetyThreshold calculation" {
    const store = primitives.LightClientUpdate.LightClientStore.from(
        fixtureHeader(128, 1),
        fixtureCommitteePubkeys(2),
        [_]u8{3} ** 48,
        null,
        null,
        fixtureHeader(128, 1),
        300,
        120,
    );

    try std.testing.expectEqual(@as(u64, 150), consensus_verifier.safetyThreshold(store));
}
