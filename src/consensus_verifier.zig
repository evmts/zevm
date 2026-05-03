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
const UPDATE_TIMEOUT: u64 = primitives.ConsensusSpec.SLOTS_PER_SYNC_COMMITTEE_PERIOD;
const CURRENT_SYNC_COMMITTEE_GINDEX: u64 = 54;
const NEXT_SYNC_COMMITTEE_GINDEX: u64 = 55;
const FINALIZED_ROOT_GINDEX: u64 = 105;
const CURRENT_SYNC_COMMITTEE_GINDEX_ELECTRA: u64 = 86;
const NEXT_SYNC_COMMITTEE_GINDEX_ELECTRA: u64 = 87;
const FINALIZED_ROOT_GINDEX_ELECTRA: u64 = 169;
const MAX_NORMALIZED_BRANCH_DEPTH: usize = 7;

const ExecutionPayloadHeaderFork = enum {
    bellatrix,
    capella,
    deneb,
    electra,
};

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
    allocator: std.mem.Allocator,
) !void {
    if (!try isHeaderExecutionPayloadProofValid(bootstrap.header, fork_config, allocator)) {
        return ConsensusVerifierError.InvalidExecutionPayloadProof;
    }

    const committee_root = try syncCommitteeRoot(
        bootstrap.current_sync_committee_pubkeys,
        bootstrap.current_sync_committee_aggregate_pubkey,
        allocator,
    );

    if (!isCurrentCommitteeProofValid(
        bootstrap.header.beacon.state_root,
        committee_root,
        bootstrap.currentSyncCommitteeBranch(),
        bootstrap.header.beacon.slot,
        fork_config,
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

    if (!try isHeaderExecutionPayloadProofValid(update.attested_header, fork_config, allocator)) {
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
        if (finalized_header.beacon.slot != 0) {
            const finality_branch = update.finality_branch orelse return ConsensusVerifierError.InvalidFinalityProof;

            if (!try isHeaderExecutionPayloadProofValid(finalized_header, fork_config, allocator)) {
                return ConsensusVerifierError.InvalidExecutionPayloadProof;
            }

            if (!isFinalityProofValid(
                update.attested_header.beacon.state_root,
                beaconHeaderRoot(finalized_header.beacon),
                finality_branch,
                update.attested_header.beacon.slot,
                fork_config,
            )) {
                return ConsensusVerifierError.InvalidFinalityProof;
            }
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

        if (update_attested_period == store_period) {
            if (store.next_sync_committee_pubkeys) |known_next_sync_committee_pubkeys| {
                if (!std.mem.eql(u8, std.mem.asBytes(&known_next_sync_committee_pubkeys), std.mem.asBytes(&next_sync_committee_pubkeys))) {
                    return ConsensusVerifierError.InvalidNextSyncCommitteeProof;
                }

                if (store.next_sync_committee_aggregate_pubkey) |known_next_sync_committee_aggregate_pubkey| {
                    if (!std.mem.eql(u8, known_next_sync_committee_aggregate_pubkey[0..], next_sync_committee_aggregate_pubkey[0..])) {
                        return ConsensusVerifierError.InvalidNextSyncCommitteeProof;
                    }
                } else {
                    return ConsensusVerifierError.InvalidNextSyncCommitteeProof;
                }
            }
        }

        if (!isNextCommitteeProofValid(
            update.attested_header.beacon.state_root,
            next_committee_root,
            next_sync_committee_branch,
            update.attested_header.beacon.slot,
            fork_config,
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
    store.best_valid_update = null;
    store.optimistic_header = bootstrap.header;
    store.previous_max_active_participants = 0;
    store.current_max_active_participants = 0;
}

pub fn applyUpdate(
    store: *primitives.LightClientUpdate.LightClientStore,
    update: primitives.LightClientUpdate.GenericUpdate,
) ?[32]u8 {
    const active_participants = participantCount(update.sync_committee_bits);

    const should_replace_best_update = if (store.best_valid_update) |*best_valid_update|
        isBetterUpdate(update, best_valid_update.toGeneric())
    else
        true;
    if (should_replace_best_update) {
        store.best_valid_update = primitives.LightClientUpdate.StoredGenericUpdate.fromGeneric(update) catch null;
    }

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

    const checkpoint = applyUpdateNoQuorumCheck(store, update);
    store.best_valid_update = null;
    return checkpoint;
}

pub fn safetyThreshold(store: primitives.LightClientUpdate.LightClientStore) u64 {
    return @max(
        store.current_max_active_participants,
        store.previous_max_active_participants,
    ) / 2;
}

pub fn isBetterUpdate(
    new_update: primitives.LightClientUpdate.GenericUpdate,
    old_update: primitives.LightClientUpdate.GenericUpdate,
) bool {
    const new_active_participants = participantCount(new_update.sync_committee_bits);
    const old_active_participants = participantCount(old_update.sync_committee_bits);
    const new_has_supermajority = new_active_participants * 3 >= primitives.ConsensusSpec.SYNC_COMMITTEE_SIZE * 2;
    const old_has_supermajority = old_active_participants * 3 >= primitives.ConsensusSpec.SYNC_COMMITTEE_SIZE * 2;
    if (new_has_supermajority != old_has_supermajority) {
        return new_has_supermajority;
    }
    if (!new_has_supermajority and new_active_participants != old_active_participants) {
        return new_active_participants > old_active_participants;
    }

    const new_has_relevant_sync_committee = hasSyncUpdate(new_update) and
        primitives.consensus.calcSyncPeriod(new_update.attested_header.beacon.slot) ==
            primitives.consensus.calcSyncPeriod(new_update.signature_slot);
    const old_has_relevant_sync_committee = hasSyncUpdate(old_update) and
        primitives.consensus.calcSyncPeriod(old_update.attested_header.beacon.slot) ==
            primitives.consensus.calcSyncPeriod(old_update.signature_slot);
    if (new_has_relevant_sync_committee != old_has_relevant_sync_committee) {
        return new_has_relevant_sync_committee;
    }

    const new_has_finality = hasFinalityUpdate(new_update);
    const old_has_finality = hasFinalityUpdate(old_update);
    if (new_has_finality != old_has_finality) {
        return new_has_finality;
    }

    if (new_has_finality) {
        const new_finalized_slot = new_update.finalized_header.?.beacon.slot;
        const old_finalized_slot = old_update.finalized_header.?.beacon.slot;
        const new_has_sync_committee_finality = primitives.consensus.calcSyncPeriod(new_finalized_slot) ==
            primitives.consensus.calcSyncPeriod(new_update.attested_header.beacon.slot);
        const old_has_sync_committee_finality = primitives.consensus.calcSyncPeriod(old_finalized_slot) ==
            primitives.consensus.calcSyncPeriod(old_update.attested_header.beacon.slot);
        if (new_has_sync_committee_finality != old_has_sync_committee_finality) {
            return new_has_sync_committee_finality;
        }
    }

    if (new_active_participants != old_active_participants) {
        return new_active_participants > old_active_participants;
    }

    if (new_update.attested_header.beacon.slot != old_update.attested_header.beacon.slot) {
        return new_update.attested_header.beacon.slot < old_update.attested_header.beacon.slot;
    }

    return new_update.signature_slot < old_update.signature_slot;
}

pub fn processLightClientStoreForceUpdate(
    store: *primitives.LightClientUpdate.LightClientStore,
    current_slot: u64,
) ?[32]u8 {
    if (current_slot <= store.finalized_header.beacon.slot + UPDATE_TIMEOUT or store.best_valid_update == null) {
        return null;
    }

    if (store.best_valid_update) |*best_valid_update| {
        const best_finalized_slot = if (best_valid_update.finalized_header) |finalized_header|
            finalized_header.beacon.slot
        else
            0;

        if (best_finalized_slot <= store.finalized_header.beacon.slot) {
            best_valid_update.finalized_header = best_valid_update.attested_header;
        }

        const checkpoint = applyUpdateNoQuorumCheck(store, best_valid_update.toGeneric());
        store.best_valid_update = null;
        return checkpoint;
    }

    return null;
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
    fork_config: primitives.ForkConfig.ForkConfig,
    allocator: std.mem.Allocator,
) !bool {
    _ = fork_config;
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
    var field_roots: [17][32]u8 = undefined;
    var field_count: usize = 0;

    field_roots[field_count] = execution.parent_hash;
    field_count += 1;
    field_roots[field_count] = fixedBytesRoot(execution.fee_recipient[0..]);
    field_count += 1;
    field_roots[field_count] = execution.state_root;
    field_count += 1;
    field_roots[field_count] = execution.receipts_root;
    field_count += 1;
    field_roots[field_count] = try primitives.Ssz.merkle.hashTreeRoot(allocator, execution.logs_bloom[0..]);
    field_count += 1;
    field_roots[field_count] = execution.prev_randao;
    field_count += 1;
    field_roots[field_count] = primitives.Ssz.merkle.hashTreeRootBasic(u64, execution.block_number);
    field_count += 1;
    field_roots[field_count] = primitives.Ssz.merkle.hashTreeRootBasic(u64, execution.gas_limit);
    field_count += 1;
    field_roots[field_count] = primitives.Ssz.merkle.hashTreeRootBasic(u64, execution.gas_used);
    field_count += 1;
    field_roots[field_count] = primitives.Ssz.merkle.hashTreeRootBasic(u64, execution.timestamp);
    field_count += 1;
    field_roots[field_count] = try byteListRoot(allocator, execution.extraData());
    field_count += 1;
    field_roots[field_count] = primitives.Ssz.merkle.hashTreeRootBasic(u256, execution.base_fee_per_gas);
    field_count += 1;
    field_roots[field_count] = execution.block_hash;
    field_count += 1;
    field_roots[field_count] = execution.transactions_root;
    field_count += 1;

    if (execution.fork.hasWithdrawalsRoot()) {
        field_roots[field_count] = execution.withdrawals_root;
        field_count += 1;
    }
    if (execution.fork.hasBlobGasFields()) {
        field_roots[field_count] = primitives.Ssz.merkle.hashTreeRootBasic(u64, execution.blob_gas_used);
        field_count += 1;
        field_roots[field_count] = primitives.Ssz.merkle.hashTreeRootBasic(u64, execution.excess_blob_gas);
        field_count += 1;
    }

    var container_data: [17 * 32]u8 = undefined;
    for (field_roots[0..field_count], 0..) |field_root, index| {
        @memcpy(container_data[(index * 32)..][0..32], field_root[0..]);
    }

    return primitives.Ssz.merkle.hashTreeRoot(allocator, container_data[0 .. field_count * 32]);
}

fn byteListRoot(allocator: std.mem.Allocator, bytes: []const u8) ![32]u8 {
    _ = allocator;
    if (bytes.len > 32) return error.ExtraDataTooLong;

    var chunk: [32]u8 = [_]u8{0} ** 32;
    @memcpy(chunk[0..bytes.len], bytes);

    var length_chunk: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, length_chunk[0..8], bytes.len, .little);
    return primitives.Ssz.merkle.hashPair(chunk, length_chunk);
}

fn fixedBytesRoot(bytes: []const u8) [32]u8 {
    var root: [32]u8 = [_]u8{0} ** 32;
    @memcpy(root[0..bytes.len], bytes);
    return root;
}

fn isCurrentCommitteeProofValid(
    attested_state_root: [32]u8,
    committee_root: [32]u8,
    branch: []const [32]u8,
    slot: u64,
    fork_config: primitives.ForkConfig.ForkConfig,
) bool {
    const gindex = if (isElectraOrLater(slot, fork_config))
        CURRENT_SYNC_COMMITTEE_GINDEX_ELECTRA
    else
        CURRENT_SYNC_COMMITTEE_GINDEX;
    return isGeneralizedIndexProofValid(committee_root, branch, gindex, attested_state_root);
}

fn isNextCommitteeProofValid(
    attested_state_root: [32]u8,
    committee_root: [32]u8,
    branch: []const [32]u8,
    slot: u64,
    fork_config: primitives.ForkConfig.ForkConfig,
) bool {
    const gindex = if (isElectraOrLater(slot, fork_config))
        NEXT_SYNC_COMMITTEE_GINDEX_ELECTRA
    else
        NEXT_SYNC_COMMITTEE_GINDEX;
    return isGeneralizedIndexProofValid(committee_root, branch, gindex, attested_state_root);
}

fn isFinalityProofValid(
    attested_state_root: [32]u8,
    finality_root: [32]u8,
    branch: []const [32]u8,
    slot: u64,
    fork_config: primitives.ForkConfig.ForkConfig,
) bool {
    const gindex = if (isElectraOrLater(slot, fork_config))
        FINALIZED_ROOT_GINDEX_ELECTRA
    else
        FINALIZED_ROOT_GINDEX;
    return isGeneralizedIndexProofValid(finality_root, branch, gindex, attested_state_root);
}

fn isElectraOrLater(slot: u64, fork_config: primitives.ForkConfig.ForkConfig) bool {
    const epoch = slot / primitives.ConsensusSpec.SLOTS_PER_EPOCH;
    return epoch >= fork_config.electra.epoch;
}

fn isGeneralizedIndexProofValid(
    leaf: [32]u8,
    branch: []const [32]u8,
    gindex: u64,
    root: [32]u8,
) bool {
    return primitives.consensus.isValidMerkleBranch(
        leaf,
        branch,
        generalizedIndexDepth(gindex),
        gindex,
        root,
    );
}

fn generalizedIndexDepth(gindex: u64) u6 {
    var value = gindex;
    var depth: u6 = 0;
    while (value > 1) : (value >>= 1) {
        depth += 1;
    }
    return depth;
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

fn testHash(marker: u8) [32]u8 {
    return [_]u8{marker} ** 32;
}

fn fillTestBranch(branch: [][32]u8, start_marker: u8) void {
    for (branch, 0..) |*entry, i| {
        entry.* = testHash(start_marker + @as(u8, @intCast(i)));
    }
}

fn testRootFromBranch(leaf: [32]u8, branch: []const [32]u8, gindex: u64) [32]u8 {
    var derived_root = leaf;
    for (branch, 0..) |branch_item, i| {
        if (((gindex >> @intCast(i)) & 1) == 1) {
            derived_root = primitives.Ssz.merkle.hashPair(branch_item, derived_root);
        } else {
            derived_root = primitives.Ssz.merkle.hashPair(derived_root, branch_item);
        }
    }
    return derived_root;
}

test "committee proofs select Electra generalized indices at the fork epoch" {
    const fork_config = primitives.ForkConfig.ForkConfig.mainnet();
    const pre_electra_slot = (fork_config.electra.epoch - 1) * primitives.ConsensusSpec.SLOTS_PER_EPOCH;
    const electra_slot = fork_config.electra.epoch * primitives.ConsensusSpec.SLOTS_PER_EPOCH;
    const committee_root = testHash(0x11);

    var pre_electra_branch: [5][32]u8 = undefined;
    fillTestBranch(pre_electra_branch[0..], 0x20);
    const pre_electra_root = testRootFromBranch(
        committee_root,
        pre_electra_branch[0..],
        CURRENT_SYNC_COMMITTEE_GINDEX,
    );

    var electra_branch: [6][32]u8 = undefined;
    fillTestBranch(electra_branch[0..], 0x30);
    const electra_root = testRootFromBranch(
        committee_root,
        electra_branch[0..],
        CURRENT_SYNC_COMMITTEE_GINDEX_ELECTRA,
    );

    try std.testing.expect(isCurrentCommitteeProofValid(
        pre_electra_root,
        committee_root,
        pre_electra_branch[0..],
        pre_electra_slot,
        fork_config,
    ));
    try std.testing.expect(!isCurrentCommitteeProofValid(
        pre_electra_root,
        committee_root,
        pre_electra_branch[0..],
        electra_slot,
        fork_config,
    ));
    try std.testing.expect(isCurrentCommitteeProofValid(
        electra_root,
        committee_root,
        electra_branch[0..],
        electra_slot,
        fork_config,
    ));
}

test "finality proofs select Electra generalized indices at the fork epoch" {
    const fork_config = primitives.ForkConfig.ForkConfig.mainnet();
    const pre_electra_slot = (fork_config.electra.epoch - 1) * primitives.ConsensusSpec.SLOTS_PER_EPOCH;
    const electra_slot = fork_config.electra.epoch * primitives.ConsensusSpec.SLOTS_PER_EPOCH;
    const finality_root = testHash(0x44);

    var pre_electra_branch: [6][32]u8 = undefined;
    fillTestBranch(pre_electra_branch[0..], 0x50);
    const pre_electra_root = testRootFromBranch(
        finality_root,
        pre_electra_branch[0..],
        FINALIZED_ROOT_GINDEX,
    );

    var electra_branch: [7][32]u8 = undefined;
    fillTestBranch(electra_branch[0..], 0x60);
    const electra_root = testRootFromBranch(
        finality_root,
        electra_branch[0..],
        FINALIZED_ROOT_GINDEX_ELECTRA,
    );

    try std.testing.expect(isFinalityProofValid(
        pre_electra_root,
        finality_root,
        pre_electra_branch[0..],
        pre_electra_slot,
        fork_config,
    ));
    try std.testing.expect(!isFinalityProofValid(
        pre_electra_root,
        finality_root,
        pre_electra_branch[0..],
        electra_slot,
        fork_config,
    ));
    try std.testing.expect(isFinalityProofValid(
        electra_root,
        finality_root,
        electra_branch[0..],
        electra_slot,
        fork_config,
    ));
}
