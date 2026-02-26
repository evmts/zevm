const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");

pub const ConsensusVerifierError = error{
    InvalidExecutionPayloadProof,
    InvalidCurrentSyncCommitteeProof,
    InvalidHeaderHash,
    InsufficientParticipation,
    InvalidTimestamp,
    InvalidPeriod,
    NotRelevant,
    InvalidFinalityProof,
    InvalidNextSyncCommitteeProof,
    MissingNextSyncCommittee,
    InvalidSignature,
};

const SYNC_COMMITTEE_DOMAIN_TYPE: [4]u8 = .{ 7, 0, 0, 0 };
const ZERO_CHUNK: [32]u8 = [_]u8{0} ** 32;

pub fn computeDomain(domain_type: [4]u8, fork_data_root: [32]u8) [32]u8 {
    var domain: [32]u8 = [_]u8{0} ** 32;
    @memcpy(domain[0..4], domain_type[0..]);
    @memcpy(domain[4..32], fork_data_root[0..28]);
    return domain;
}

pub fn computeForkDataRoot(fork_version: [4]u8, genesis_validators_root: [32]u8) ![32]u8 {
    var fork_version_root: [32]u8 = [_]u8{0} ** 32;
    @memcpy(fork_version_root[0..4], fork_version[0..]);
    return primitives.Ssz.merkle.hashPair(fork_version_root, genesis_validators_root);
}

pub fn computeSigningRoot(object_root: [32]u8, domain: [32]u8) [32]u8 {
    return primitives.Ssz.merkle.hashPair(object_root, domain);
}

pub fn computeCommitteeSignRoot(header_root: [32]u8, fork_data_root: [32]u8) [32]u8 {
    const domain = computeDomain(SYNC_COMMITTEE_DOMAIN_TYPE, fork_data_root);
    return computeSigningRoot(header_root, domain);
}

pub const ParticipatingKeys = struct {
    keys: [512][48]u8,
    len: usize,

    pub fn get(self: ParticipatingKeys, index: usize) [48]u8 {
        return self.keys[index];
    }

    pub fn constSlice(self: *const ParticipatingKeys) []const [48]u8 {
        return self.keys[0..self.len];
    }
};

pub fn getParticipatingKeys(
    committee_pubkeys: [512][48]u8,
    sync_committee_bits: [64]u8,
) ParticipatingKeys {
    var result = ParticipatingKeys{ .keys = undefined, .len = 0 };

    for (committee_pubkeys, 0..) |pubkey, index| {
        const byte_index = index / 8;
        const bit_index: u3 = @intCast(index % 8);
        if ((sync_committee_bits[byte_index] & (@as(u8, 1) << bit_index)) != 0) {
            result.keys[result.len] = pubkey;
            result.len += 1;
        }
    }

    return result;
}

pub fn verifyBootstrap(
    bootstrap: primitives.LightClientUpdate.LightClientBootstrap,
    checkpoint: [32]u8,
    fork_config: primitives.ForkConfig.ForkConfig,
    genesis_validators_root: [32]u8,
    allocator: std.mem.Allocator,
) !void {
    _ = fork_config;
    _ = genesis_validators_root;

    if (!try isHeaderExecutionPayloadProofValid(bootstrap.header, allocator)) {
        return ConsensusVerifierError.InvalidExecutionPayloadProof;
    }

    const committee_root = try syncCommitteeRoot(
        bootstrap.current_sync_committee_pubkeys,
        bootstrap.current_sync_committee_aggregate_pubkey,
        allocator,
    );

    if (!primitives.consensus.isCurrentCommitteeProofValid(
        bootstrap.header.beacon.state_root,
        committee_root,
        bootstrap.current_sync_committee_branch[0..],
    )) {
        return ConsensusVerifierError.InvalidCurrentSyncCommitteeProof;
    }

    const header_root = beaconHeaderRoot(bootstrap.header.beacon);
    if (!std.mem.eql(u8, header_root[0..], checkpoint[0..])) {
        return ConsensusVerifierError.InvalidHeaderHash;
    }
}

pub fn verifyUpdate(
    update: primitives.LightClientUpdate.GenericUpdate,
    expected_current_slot: u64,
    store: primitives.LightClientUpdate.LightClientStore,
    genesis_root: [32]u8,
    fork_config: primitives.ForkConfig.ForkConfig,
    allocator: std.mem.Allocator,
) !void {
    const active_participants = participantCount(update.sync_committee_bits);
    if (active_participants == 0) {
        return ConsensusVerifierError.InsufficientParticipation;
    }

    if (!try isHeaderExecutionPayloadProofValid(update.attested_header, allocator)) {
        return ConsensusVerifierError.InvalidExecutionPayloadProof;
    }

    const finalized_slot = if (update.finalized_header) |finalized_header|
        finalized_header.beacon.slot
    else
        0;

    const valid_time = expected_current_slot >= update.signature_slot and
        update.signature_slot > update.attested_header.beacon.slot and
        update.attested_header.beacon.slot >= finalized_slot;
    if (!valid_time) {
        return ConsensusVerifierError.InvalidTimestamp;
    }

    const store_period = primitives.consensus.calcSyncPeriod(store.finalized_header.beacon.slot);
    const update_signature_period = primitives.consensus.calcSyncPeriod(update.signature_slot);
    const valid_period = if (store.next_sync_committee_pubkeys != null)
        update_signature_period == store_period or update_signature_period == store_period + 1
    else
        update_signature_period == store_period;
    if (!valid_period) {
        return ConsensusVerifierError.InvalidPeriod;
    }

    const update_attested_period = primitives.consensus.calcSyncPeriod(update.attested_header.beacon.slot);
    const update_has_next_committee = store.next_sync_committee_pubkeys == null and
        hasSyncUpdate(update) and
        update_attested_period == store_period;
    if (update.attested_header.beacon.slot <= store.finalized_header.beacon.slot and !update_has_next_committee) {
        return ConsensusVerifierError.NotRelevant;
    }

    if (update.finalized_header) |finalized_header| {
        const finality_branch = update.finality_branch orelse return ConsensusVerifierError.InvalidFinalityProof;

        if (!try isHeaderExecutionPayloadProofValid(finalized_header, allocator)) {
            return ConsensusVerifierError.InvalidExecutionPayloadProof;
        }

        if (!primitives.consensus.isFinalityProofValid(
            update.attested_header.beacon.state_root,
            beaconHeaderRoot(finalized_header.beacon),
            finality_branch,
        )) {
            return ConsensusVerifierError.InvalidFinalityProof;
        }
    } else if (update.finality_branch != null) {
        return ConsensusVerifierError.InvalidFinalityProof;
    }

    if (update.next_sync_committee_pubkeys) |next_sync_committee_pubkeys| {
        const next_sync_committee_aggregate_pubkey = update.next_sync_committee_aggregate_pubkey orelse return ConsensusVerifierError.InvalidNextSyncCommitteeProof;
        const next_sync_committee_branch = update.next_sync_committee_branch orelse return ConsensusVerifierError.InvalidNextSyncCommitteeProof;

        const next_committee_root = try syncCommitteeRoot(
            next_sync_committee_pubkeys,
            next_sync_committee_aggregate_pubkey,
            allocator,
        );

        if (!primitives.consensus.isNextCommitteeProofValid(
            update.attested_header.beacon.state_root,
            next_committee_root,
            next_sync_committee_branch,
        )) {
            return ConsensusVerifierError.InvalidNextSyncCommitteeProof;
        }
    } else if (update.next_sync_committee_aggregate_pubkey != null or update.next_sync_committee_branch != null) {
        return ConsensusVerifierError.InvalidNextSyncCommitteeProof;
    }

    const signature_committee_pubkeys = if (update_signature_period == store_period)
        store.current_sync_committee_pubkeys
    else if (store.next_sync_committee_pubkeys) |next_sync_committee_pubkeys|
        next_sync_committee_pubkeys
    else
        return ConsensusVerifierError.MissingNextSyncCommittee;

    const participating_keys = getParticipatingKeys(signature_committee_pubkeys, update.sync_committee_bits);

    var public_keys = std.array_list.Managed(crypto.bls12_381.PublicKey).init(allocator);
    defer public_keys.deinit();

    for (participating_keys.constSlice()) |pubkey_bytes| {
        const parsed_public_key = crypto.bls12_381.PublicKey.fromCompressed(&pubkey_bytes) catch {
            return ConsensusVerifierError.InvalidSignature;
        };
        try public_keys.append(parsed_public_key);
    }

    var public_key_refs = std.array_list.Managed(*const crypto.bls12_381.PublicKey).init(allocator);
    defer public_key_refs.deinit();

    for (public_keys.items) |*public_key| {
        try public_key_refs.append(public_key);
    }

    const aggregate_public_key = crypto.bls12_381.aggregatePublicKeys(public_key_refs.items) catch {
        return ConsensusVerifierError.InvalidSignature;
    };

    const signature = crypto.bls12_381.Signature.fromCompressed(&update.sync_committee_signature) catch {
        return ConsensusVerifierError.InvalidSignature;
    };

    const signature_epoch = (update.signature_slot -| 1) / primitives.ConsensusSpec.SLOTS_PER_EPOCH;
    const fork_version = fork_config.forkVersionForEpoch(signature_epoch);
    const fork_data_root = try computeForkDataRoot(fork_version, genesis_root);

    const signing_root = computeCommitteeSignRoot(
        beaconHeaderRoot(update.attested_header.beacon),
        fork_data_root,
    );

    const valid_signature = crypto.bls12_381.verify(
        &signature,
        &aggregate_public_key,
        signing_root[0..],
        crypto.bls12_381.DST.ETH2_SIGNATURE,
    ) catch {
        return ConsensusVerifierError.InvalidSignature;
    };

    if (!valid_signature) {
        return ConsensusVerifierError.InvalidSignature;
    }
}

pub fn applyBootstrap(
    store: *primitives.LightClientUpdate.LightClientStore,
    bootstrap: primitives.LightClientUpdate.LightClientBootstrap,
) void {
    store.finalized_header = bootstrap.header;
    store.current_sync_committee_pubkeys = bootstrap.current_sync_committee_pubkeys;
    store.current_sync_committee_aggregate_pubkey = bootstrap.current_sync_committee_aggregate_pubkey;
    store.next_sync_committee_pubkeys = null;
    store.next_sync_committee_aggregate_pubkey = null;
    store.optimistic_header = bootstrap.header;
    store.previous_max_active_participants = 0;
    store.current_max_active_participants = 0;
}

pub fn applyUpdate(
    store: *primitives.LightClientUpdate.LightClientStore,
    update: primitives.LightClientUpdate.GenericUpdate,
) ?[32]u8 {
    const active_participants = participantCount(update.sync_committee_bits);

    store.current_max_active_participants = @max(
        store.current_max_active_participants,
        active_participants,
    );

    if (active_participants > safetyThreshold(store.*) and
        update.attested_header.beacon.slot > store.optimistic_header.beacon.slot)
    {
        store.optimistic_header = update.attested_header;
    }

    const update_attested_period = primitives.consensus.calcSyncPeriod(update.attested_header.beacon.slot);
    const update_finalized_slot = if (update.finalized_header) |finalized_header|
        finalized_header.beacon.slot
    else
        0;
    const update_finalized_period = primitives.consensus.calcSyncPeriod(update_finalized_slot);

    const update_has_finalized_next_committee = store.next_sync_committee_pubkeys == null and
        hasSyncUpdate(update) and
        hasFinalityUpdate(update) and
        update_finalized_period == update_attested_period;

    const has_majority = active_participants * 3 >= primitives.ConsensusSpec.SYNC_COMMITTEE_SIZE * 2;
    const update_is_newer = update_finalized_slot > store.finalized_header.beacon.slot;
    const should_apply_update = has_majority and (update_is_newer or update_has_finalized_next_committee);

    if (!should_apply_update) {
        return null;
    }

    return applyUpdateNoQuorumCheck(store, update);
}

pub fn safetyThreshold(store: primitives.LightClientUpdate.LightClientStore) u64 {
    return @max(
        store.current_max_active_participants,
        store.previous_max_active_participants,
    ) / 2;
}

fn applyUpdateNoQuorumCheck(
    store: *primitives.LightClientUpdate.LightClientStore,
    update: primitives.LightClientUpdate.GenericUpdate,
) ?[32]u8 {
    const store_period = primitives.consensus.calcSyncPeriod(store.finalized_header.beacon.slot);
    const update_finalized_slot = if (update.finalized_header) |finalized_header|
        finalized_header.beacon.slot
    else
        0;
    const update_finalized_period = primitives.consensus.calcSyncPeriod(update_finalized_slot);

    if (store.next_sync_committee_pubkeys == null) {
        if (update_finalized_period != store_period) {
            return null;
        }

        store.next_sync_committee_pubkeys = update.next_sync_committee_pubkeys;
        store.next_sync_committee_aggregate_pubkey = update.next_sync_committee_aggregate_pubkey;
    } else if (update_finalized_period == store_period + 1) {
        if (store.next_sync_committee_pubkeys) |next_sync_committee_pubkeys| {
            store.current_sync_committee_pubkeys = next_sync_committee_pubkeys;
        }

        if (store.next_sync_committee_aggregate_pubkey) |next_sync_committee_aggregate_pubkey| {
            store.current_sync_committee_aggregate_pubkey = next_sync_committee_aggregate_pubkey;
        }

        store.next_sync_committee_pubkeys = update.next_sync_committee_pubkeys;
        store.next_sync_committee_aggregate_pubkey = update.next_sync_committee_aggregate_pubkey;
        store.previous_max_active_participants = store.current_max_active_participants;
        store.current_max_active_participants = 0;
    }

    if (update.finalized_header) |finalized_header| {
        if (finalized_header.beacon.slot > store.finalized_header.beacon.slot) {
            store.finalized_header = finalized_header;

            if (store.finalized_header.beacon.slot > store.optimistic_header.beacon.slot) {
                store.optimistic_header = store.finalized_header;
            }

            if (store.finalized_header.beacon.slot % primitives.ConsensusSpec.SLOTS_PER_EPOCH == 0) {
                return beaconHeaderRoot(store.finalized_header.beacon);
            }
        }
    }

    return null;
}

fn participantCount(sync_committee_bits: [64]u8) u64 {
    var count: u64 = 0;
    for (sync_committee_bits) |byte| {
        count += @as(u64, @intCast(@popCount(byte)));
    }
    return count;
}

fn hasSyncUpdate(update: primitives.LightClientUpdate.GenericUpdate) bool {
    return update.next_sync_committee_pubkeys != null and
        update.next_sync_committee_aggregate_pubkey != null and
        update.next_sync_committee_branch != null;
}

fn hasFinalityUpdate(update: primitives.LightClientUpdate.GenericUpdate) bool {
    return update.finalized_header != null and update.finality_branch != null;
}

fn syncCommitteeRoot(
    committee_pubkeys: [512][48]u8,
    committee_aggregate_pubkey: [48]u8,
    allocator: std.mem.Allocator,
) ![32]u8 {
    const sync_committee = primitives.SyncCommittee.SyncCommittee{
        .pubkeys = committee_pubkeys,
        .aggregate_pubkey = committee_aggregate_pubkey,
    };
    return sync_committee.hashTreeRoot(allocator);
}

fn isHeaderExecutionPayloadProofValid(
    header: primitives.LightClientHeader.LightClientHeader,
    allocator: std.mem.Allocator,
) !bool {
    const execution_root = try executionPayloadHeaderFieldsRoot(header.execution, allocator);
    return primitives.consensus.isExecutionPayloadProofValid(
        header.beacon.body_root,
        execution_root,
        header.execution_branch,
    );
}

fn executionPayloadHeaderFieldsRoot(
    execution: primitives.LightClientHeader.LightClientHeader.ExecutionPayloadHeaderFields,
    allocator: std.mem.Allocator,
) ![32]u8 {
    var field_roots: [16][32]u8 = undefined;
    field_roots[0] = execution.parent_hash;
    field_roots[1] = fixedBytesRoot(execution.fee_recipient[0..]);
    field_roots[2] = execution.state_root;
    field_roots[3] = execution.receipts_root;
    field_roots[4] = try primitives.Ssz.merkle.hashTreeRoot(allocator, execution.logs_bloom[0..]);
    field_roots[5] = execution.prev_randao;
    field_roots[6] = primitives.Ssz.merkle.hashTreeRootBasic(u64, execution.block_number);
    field_roots[7] = primitives.Ssz.merkle.hashTreeRootBasic(u64, execution.gas_limit);
    field_roots[8] = primitives.Ssz.merkle.hashTreeRootBasic(u64, execution.gas_used);
    field_roots[9] = primitives.Ssz.merkle.hashTreeRootBasic(u64, execution.timestamp);
    field_roots[10] = primitives.Ssz.merkle.hashTreeRootBasic(u256, execution.base_fee_per_gas);
    field_roots[11] = execution.block_hash;
    field_roots[12] = execution.transactions_root;
    field_roots[13] = execution.withdrawals_root;
    field_roots[14] = primitives.Ssz.merkle.hashTreeRootBasic(u64, execution.blob_gas_used);
    field_roots[15] = primitives.Ssz.merkle.hashTreeRootBasic(u64, execution.excess_blob_gas);

    var container_data: [16 * 32]u8 = undefined;
    for (field_roots, 0..) |field_root, index| {
        @memcpy(container_data[(index * 32)..][0..32], field_root[0..]);
    }

    return primitives.Ssz.merkle.hashTreeRoot(allocator, container_data[0..]);
}

fn fixedBytesRoot(bytes: []const u8) [32]u8 {
    var root: [32]u8 = [_]u8{0} ** 32;
    @memcpy(root[0..bytes.len], bytes);
    return root;
}

pub fn beaconHeaderRoot(beacon_header: primitives.LightClientHeader.LightClientHeader.BeaconBlockHeader) [32]u8 {
    const slot_root = primitives.Ssz.merkle.hashTreeRootBasic(u64, beacon_header.slot);
    const proposer_index_root = primitives.Ssz.merkle.hashTreeRootBasic(u64, beacon_header.proposer_index);

    const first_layer_0 = primitives.Ssz.merkle.hashPair(slot_root, proposer_index_root);
    const first_layer_1 = primitives.Ssz.merkle.hashPair(beacon_header.parent_root, beacon_header.state_root);
    const first_layer_2 = primitives.Ssz.merkle.hashPair(beacon_header.body_root, ZERO_CHUNK);
    const first_layer_3 = primitives.Ssz.merkle.hashPair(ZERO_CHUNK, ZERO_CHUNK);

    const second_layer_0 = primitives.Ssz.merkle.hashPair(first_layer_0, first_layer_1);
    const second_layer_1 = primitives.Ssz.merkle.hashPair(first_layer_2, first_layer_3);

    return primitives.Ssz.merkle.hashPair(second_layer_0, second_layer_1);
}
