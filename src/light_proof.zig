const std = @import("std");
const primitives = @import("primitives");
const beacon_api = @import("beacon_api.zig");

/// Upper bound on a single execution JSON-RPC response used for light proofs.
/// `eth_getCode` for a 24 KiB contract is ~48 KiB of hex; account and storage
/// proofs are a few KiB.
pub const MAX_PROOF_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

pub const RpcRequest = struct {
    url: []const u8,
    method: []const u8,
    params_json: []const u8,
};

pub const RpcResolver = struct {
    context: ?*anyopaque,
    resolve: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: RpcRequest,
    ) anyerror![]u8,
};

pub const ProofSource = struct {
    url: []const u8,
    resolver: ?RpcResolver = null,
};

const AccountProof = struct {
    nonce: u64,
    balance: u256,
    code_hash: [32]u8,
    storage_root: [32]u8,
    account_proof: [][]const u8,
    storage_proofs: []StorageProof,

    fn deinit(self: *AccountProof, allocator: std.mem.Allocator) void {
        freeProofNodes(allocator, self.account_proof);
        for (self.storage_proofs) |*storage_proof| {
            storage_proof.deinit(allocator);
        }
        allocator.free(self.storage_proofs);
    }
};

const StorageProof = struct {
    key: u256,
    value: u256,
    proof: [][]const u8,

    fn deinit(self: *StorageProof, allocator: std.mem.Allocator) void {
        freeProofNodes(allocator, self.proof);
    }
};

pub fn readBalance(
    allocator: std.mem.Allocator,
    source: ProofSource,
    state_root: [32]u8,
    address: primitives.Address,
    block_tag: []const u8,
) !u256 {
    var proof = try fetchAccountProof(allocator, source, address, null, block_tag);
    defer proof.deinit(allocator);

    const account = try verifyAccountProof(allocator, state_root, address, &proof);
    return account.balance;
}

pub fn readTransactionCount(
    allocator: std.mem.Allocator,
    source: ProofSource,
    state_root: [32]u8,
    address: primitives.Address,
    block_tag: []const u8,
) !u64 {
    var proof = try fetchAccountProof(allocator, source, address, null, block_tag);
    defer proof.deinit(allocator);

    const account = try verifyAccountProof(allocator, state_root, address, &proof);
    return account.nonce;
}

pub fn readStorage(
    allocator: std.mem.Allocator,
    source: ProofSource,
    state_root: [32]u8,
    address: primitives.Address,
    slot: u256,
    block_tag: []const u8,
) !u256 {
    var proof = try fetchAccountProof(allocator, source, address, slot, block_tag);
    defer proof.deinit(allocator);

    const account = try verifyAccountProof(allocator, state_root, address, &proof);
    const storage_proof = findStorageProof(&proof, slot) orelse return error.MalformedProof;

    const value_rlp = try storageValueRlp(allocator, storage_proof.value);
    defer if (value_rlp) |bytes| allocator.free(bytes);

    var slot_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &slot_bytes, slot, .big);

    const empty: []const u8 = &.{};
    const valid = primitives.Proof.verifyStorageSlotProof(
        allocator,
        &account.storage_root,
        &slot_bytes,
        value_rlp orelse empty,
        storage_proof.proof,
    ) catch |err| return proofVerificationError(err);
    if (!valid) return error.ProofVerifyFailed;

    return storage_proof.value;
}

pub fn readCode(
    allocator: std.mem.Allocator,
    source: ProofSource,
    state_root: [32]u8,
    address: primitives.Address,
    block_tag: []const u8,
) ![]u8 {
    var proof = try fetchAccountProof(allocator, source, address, null, block_tag);
    defer proof.deinit(allocator);

    const account = try verifyAccountProof(allocator, state_root, address, &proof);
    const code = try fetchCode(allocator, source, address, block_tag);
    errdefer allocator.free(code);

    const code_hash = primitives.Hash.keccak256(code);
    if (!std.mem.eql(u8, &code_hash, &account.code_hash)) {
        return error.ProofVerifyFailed;
    }

    return code;
}

fn fetchAccountProof(
    allocator: std.mem.Allocator,
    source: ProofSource,
    address: primitives.Address,
    storage_slot: ?u256,
    block_tag: []const u8,
) !AccountProof {
    const params_json = try accountProofParams(allocator, address, storage_slot, block_tag);
    defer allocator.free(params_json);

    const result_json = resolveJsonRpc(allocator, source, "eth_getProof", params_json) catch |err| return classifyResolveError(err);
    defer allocator.free(result_json);

    return parseAccountProof(allocator, result_json) catch |err| return classifyParseError(err);
}

fn fetchCode(
    allocator: std.mem.Allocator,
    source: ProofSource,
    address: primitives.Address,
    block_tag: []const u8,
) ![]u8 {
    const address_hex = addressHex(address);
    const params_json = try std.fmt.allocPrint(allocator, "[\"{s}\",\"{s}\"]", .{ address_hex[0..], block_tag });
    defer allocator.free(params_json);

    const result_json = resolveJsonRpc(allocator, source, "eth_getCode", params_json) catch |err| return classifyResolveError(err);
    defer allocator.free(result_json);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch |err| return classifyParseError(err);
    defer parsed.deinit();

    const code_hex = switch (parsed.value) {
        .string => |value| value,
        else => return error.MalformedProof,
    };
    return parseHexBytes(allocator, code_hex) catch |err| return classifyParseError(err);
}

/// Maps a resolver failure to the light-proof error domain. Allocation
/// failures stay `OutOfMemory`; malformed upstream payloads stay distinct; any
/// other failure (transport, HTTP status, JSON-RPC error object) is an
/// upstream failure, not a bad proof.
fn classifyResolveError(err: anyerror) error{ OutOfMemory, MalformedProof, InvalidUpstreamRpcResponse, UpstreamRpcFailed, UpstreamTimeout } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UpstreamTimeout, error.WouldBlock, error.ConnectionTimedOut => error.UpstreamTimeout,
        error.MalformedProof => error.MalformedProof,
        error.InvalidUpstreamRpcResponse => error.InvalidUpstreamRpcResponse,
        else => error.UpstreamRpcFailed,
    };
}

/// Maps a failure while decoding an upstream result. Everything except
/// allocation failure means the upstream returned a malformed proof.
fn classifyParseError(err: anyerror) error{ OutOfMemory, MalformedProof } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedProof,
    };
}

fn resolveJsonRpc(
    allocator: std.mem.Allocator,
    source: ProofSource,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    const request = RpcRequest{
        .url = source.url,
        .method = method,
        .params_json = params_json,
    };
    if (source.resolver) |resolver| {
        return resolver.resolve(resolver.context, allocator, request);
    }
    return resolveViaHttp(null, allocator, request);
}

pub fn resolveViaHttp(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: RpcRequest,
) ![]u8 {
    _ = context;

    const request_body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
        .{ request.method, request.params_json },
    );
    defer allocator.free(request_body);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(request.url);
    var http_request = client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .extra_headers = &[_]std.http.Header{
            .{
                .name = "content-type",
                .value = "application/json",
            },
        },
    }) catch |err| {
        if (err == error.ConnectionTimedOut) return error.UpstreamTimeout;
        return err;
    };
    defer {
        http_request.connection.?.closing = true;
        http_request.deinit();
    }

    var deadline: beacon_api.UpstreamDeadline = undefined;
    const connection = http_request.connection.?;
    try deadline.start(connection);
    defer deadline.stop();
    const response_body = receiveProofResponse(allocator, &http_request, request_body) catch |err| {
        try deadline.check(connection);
        return err;
    };
    defer allocator.free(response_body);
    try deadline.check(connection);
    return extractJsonRpcResult(allocator, response_body);
}

fn receiveProofResponse(allocator: std.mem.Allocator, http_request: *std.http.Client.Request, request_body: []u8) ![]u8 {
    try http_request.sendBodyComplete(request_body);
    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) return error.UpstreamRpcFailed;
    if (response.head.content_length) |content_length| {
        if (content_length > MAX_PROOF_RESPONSE_BYTES) return error.ProofResponseTooLarge;
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (response.head.content_encoding != .identity) allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    return readLimitedProofBody(allocator, reader, MAX_PROOF_RESPONSE_BYTES) catch |err| switch (err) {
        error.ReadFailed => return resolveProofBodyReadError(response.bodyErr()),
        else => return err,
    };
}

/// Maps a `ReadFailed` body read error using `response.bodyErr()` queried
/// *after* the read failed. Decompression failures leave `body_err == null`.
fn resolveProofBodyReadError(body_err: ?std.http.Reader.BodyError) (std.http.Reader.BodyError || error{InvalidCompressedResponse}) {
    return body_err orelse error.InvalidCompressedResponse;
}

/// Reads the whole (possibly decompressed) proof response body, accepting at
/// most `max_bytes`. Callers query `response.bodyErr()` only after `ReadFailed`.
fn readLimitedProofBody(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_bytes: usize,
) ![]u8 {
    // `allocRemaining` fails when the limit is reached, so allow one extra
    // byte to accept a body of exactly `max_bytes`.
    const body = reader.allocRemaining(allocator, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.StreamTooLong => return error.ProofResponseTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (body.len > max_bytes) {
        allocator.free(body);
        return error.ProofResponseTooLarge;
    }
    return body;
}

/// Returns the stringified `result` of a JSON-RPC 2.0 response envelope.
/// `"error": null` is treated as absent, as some servers emit it on success.
pub fn extractJsonRpcResult(allocator: std.mem.Allocator, response_body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidUpstreamRpcResponse,
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidUpstreamRpcResponse,
    };
    if (object.get("error")) |rpc_error| {
        if (rpc_error != .null) return error.UpstreamRpcFailed;
    }
    const result = object.get("result") orelse return error.InvalidUpstreamRpcResponse;
    return stringifyJsonValue(allocator, result);
}

fn proofVerificationError(err: anyerror) error{ OutOfMemory, ProofVerifyFailed } {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.ProofVerifyFailed;
}

fn verifyAccountProof(
    allocator: std.mem.Allocator,
    state_root: [32]u8,
    address: primitives.Address,
    proof: *const AccountProof,
) !primitives.AccountState.AccountState {
    const account = primitives.AccountState.AccountState.from(.{
        .nonce = proof.nonce,
        .balance = proof.balance,
        .storage_root = proof.storage_root,
        .code_hash = proof.code_hash,
    });

    if (account.isTotallyEmpty()) {
        const absent = primitives.Proof.verifyAccountProof(allocator, &state_root, &address.bytes, "", proof.account_proof) catch |err| return proofVerificationError(err);
        if (absent) return account;
    }

    const account_rlp = try account.rlpEncode(allocator);
    defer allocator.free(account_rlp);
    const valid = primitives.Proof.verifyAccountProof(allocator, &state_root, &address.bytes, account_rlp, proof.account_proof) catch |err| return proofVerificationError(err);
    if (!valid) return error.ProofVerifyFailed;
    return account;
}

fn parseAccountProof(allocator: std.mem.Allocator, result_json: []const u8) !AccountProof {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.MalformedProof,
    };

    const account_proof = try parseProofNodes(allocator, try objectField(object, "accountProof"));
    errdefer freeProofNodes(allocator, account_proof);

    const storage_proofs = if (object.get("storageProof")) |storage_proof_value|
        try parseStorageProofs(allocator, storage_proof_value)
    else
        try allocator.alloc(StorageProof, 0);
    errdefer {
        for (storage_proofs) |*storage_proof| {
            storage_proof.deinit(allocator);
        }
        allocator.free(storage_proofs);
    }

    return .{
        .nonce = try parseQuantityU64(try stringField(object, "nonce")),
        .balance = try parseQuantityU256(try stringField(object, "balance")),
        .code_hash = try parseHex32(try stringField(object, "codeHash")),
        .storage_root = if (object.get("storageHash")) |value|
            try parseHex32(try valueString(value))
        else if (object.get("storageRoot")) |value|
            try parseHex32(try valueString(value))
        else
            return error.MalformedProof,
        .account_proof = account_proof,
        .storage_proofs = storage_proofs,
    };
}

fn parseStorageProofs(allocator: std.mem.Allocator, value: std.json.Value) ![]StorageProof {
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.MalformedProof,
    };
    const proofs = try allocator.alloc(StorageProof, items.len);
    errdefer allocator.free(proofs);

    var count: usize = 0;
    errdefer {
        for (proofs[0..count]) |*proof| {
            proof.deinit(allocator);
        }
    }

    for (items, 0..) |item, index| {
        const object = switch (item) {
            .object => |obj| obj,
            else => return error.MalformedProof,
        };
        proofs[index] = .{
            .key = try parseQuantityU256(try stringField(object, "key")),
            .value = try parseQuantityU256(try stringField(object, "value")),
            .proof = try parseProofNodes(allocator, try objectField(object, "proof")),
        };
        count += 1;
    }

    return proofs;
}

fn parseProofNodes(allocator: std.mem.Allocator, value: std.json.Value) ![][]const u8 {
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.MalformedProof,
    };
    const nodes = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(nodes);

    var count: usize = 0;
    errdefer {
        for (nodes[0..count]) |node| {
            allocator.free(node);
        }
    }

    for (items, 0..) |item, index| {
        const hex = switch (item) {
            .string => |text| text,
            else => return error.MalformedProof,
        };
        nodes[index] = try parseHexBytes(allocator, hex);
        count += 1;
    }

    return nodes;
}

fn freeProofNodes(allocator: std.mem.Allocator, nodes: [][]const u8) void {
    for (nodes) |node| {
        allocator.free(node);
    }
    allocator.free(nodes);
}

fn findStorageProof(proof: *const AccountProof, slot: u256) ?*const StorageProof {
    for (proof.storage_proofs) |*storage_proof| {
        if (storage_proof.key == slot) return storage_proof;
    }
    return null;
}

fn storageValueRlp(allocator: std.mem.Allocator, value: u256) !?[]u8 {
    if (value == 0) return null;

    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, value, .big);

    var first_non_zero: usize = 0;
    while (first_non_zero < bytes.len and bytes[first_non_zero] == 0) : (first_non_zero += 1) {}
    return try primitives.Rlp.encodeBytes(allocator, bytes[first_non_zero..]);
}

fn accountProofParams(
    allocator: std.mem.Allocator,
    address: primitives.Address,
    storage_slot: ?u256,
    block_tag: []const u8,
) ![]u8 {
    const address_hex = addressHex(address);
    if (storage_slot) |slot| {
        var slot_buf: [66]u8 = undefined;
        const slot_hex = try std.fmt.bufPrint(&slot_buf, "0x{x:0>64}", .{slot});
        return std.fmt.allocPrint(
            allocator,
            "[\"{s}\",[\"{s}\"],\"{s}\"]",
            .{ address_hex[0..], slot_hex, block_tag },
        );
    }
    return std.fmt.allocPrint(allocator, "[\"{s}\",[],\"{s}\"]", .{ address_hex[0..], block_tag });
}

fn objectField(object: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return object.get(key) orelse error.MalformedProof;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return valueString(try objectField(object, key));
}

fn valueString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.MalformedProof,
    };
}

fn parseQuantityU64(text: []const u8) !u64 {
    if (!hasHexPrefix(text)) return error.MalformedProof;
    const raw = text[2..];
    if (raw.len == 0) return error.MalformedProof;
    return std.fmt.parseInt(u64, raw, 16) catch error.MalformedProof;
}

fn parseQuantityU256(text: []const u8) !u256 {
    if (!hasHexPrefix(text)) return error.MalformedProof;
    const raw = text[2..];
    if (raw.len == 0) return error.MalformedProof;
    return std.fmt.parseInt(u256, raw, 16) catch error.MalformedProof;
}

fn parseHex32(text: []const u8) ![32]u8 {
    if (!hasHexPrefix(text) or text.len != 66) return error.MalformedProof;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text[2..]) catch return error.MalformedProof;
    return out;
}

fn parseHexBytes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (!hasHexPrefix(text)) return error.MalformedProof;
    const hex = text[2..];
    if (hex.len % 2 != 0) return error.MalformedProof;

    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = std.fmt.hexToBytes(out, hex) catch return error.MalformedProof;
    return out;
}

fn hasHexPrefix(text: []const u8) bool {
    return text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X');
}

fn addressHex(address: primitives.Address) [42]u8 {
    var out: [42]u8 = undefined;
    out[0] = '0';
    out[1] = 'x';
    writeHexLower(out[2..], &address.bytes);
    return out;
}

fn writeHexLower(out: []u8, bytes: []const u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        out[index * 2] = alphabet[(byte >> 4) & 0x0f];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

test "empty-account proof verifies against empty state root" {
    const allocator = std.testing.allocator;
    const source = ProofSource{
        .url = "fixture://empty-account-proof",
        .resolver = .{
            .context = null,
            .resolve = &emptyAccountResolver,
        },
    };
    const address = primitives.Address{ .bytes = [_]u8{0x42} ** 20 };

    const balance = try readBalance(
        allocator,
        source,
        primitives.AccountState.EMPTY_TRIE_ROOT,
        address,
        "0x1",
    );
    try std.testing.expectEqual(@as(u256, 0), balance);

    const code = try readCode(
        allocator,
        source,
        primitives.AccountState.EMPTY_TRIE_ROOT,
        address,
        "0x1",
    );
    defer allocator.free(code);
    try std.testing.expectEqual(@as(usize, 0), code.len);
}

test "a divergent account leaf proves exclusion only against its authenticated root" {
    const allocator = std.testing.allocator;
    const present = primitives.Address{ .bytes = [_]u8{0x11} ** 20 };
    const absent = primitives.Address{ .bytes = [_]u8{0x22} ** 20 };
    const path = [_]u8{0x20} ++ primitives.Hash.keccak256(&present.bytes);
    const value = try primitives.AccountState.AccountState.from(.{ .balance = 1 }).rlpEncode(allocator);
    defer allocator.free(value);
    const leaf = try primitives.Rlp.encode(allocator, [_][]const u8{ &path, value });
    defer allocator.free(leaf);
    const root = primitives.Hash.keccak256(leaf);
    var nodes = [_][]const u8{leaf};
    const proof = AccountProof{
        .nonce = 0,
        .balance = 0,
        .storage_root = primitives.AccountState.EMPTY_TRIE_ROOT,
        .code_hash = primitives.AccountState.EMPTY_CODE_HASH,
        .account_proof = &nodes,
        .storage_proofs = &.{},
    };

    const account = try verifyAccountProof(allocator, root, absent, &proof);
    try std.testing.expect(account.isTotallyEmpty());
    try std.testing.expectError(error.ProofVerifyFailed, verifyAccountProof(allocator, root, present, &proof));
    leaf[leaf.len - 1] ^= 1;
    try std.testing.expectError(error.ProofVerifyFailed, verifyAccountProof(allocator, root, absent, &proof));
}

test "canonical empty account leaf proves inclusion" {
    const allocator = std.testing.allocator;
    const present = primitives.Address{ .bytes = [_]u8{0x11} ** 20 };
    const path = [_]u8{0x20} ++ primitives.Hash.keccak256(&present.bytes);
    const value = try primitives.AccountState.AccountState.from(.{}).rlpEncode(allocator);
    defer allocator.free(value);
    const leaf = try primitives.Rlp.encode(allocator, [_][]const u8{ &path, value });
    defer allocator.free(leaf);
    const root = primitives.Hash.keccak256(leaf);
    var nodes = [_][]const u8{leaf};
    const proof = AccountProof{
        .nonce = 0,
        .balance = 0,
        .storage_root = primitives.AccountState.EMPTY_TRIE_ROOT,
        .code_hash = primitives.AccountState.EMPTY_CODE_HASH,
        .account_proof = &nodes,
        .storage_proofs = &.{},
    };

    const account = try verifyAccountProof(allocator, root, present, &proof);
    try std.testing.expect(account.isTotallyEmpty());
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, verifyAccountProof(failing.allocator(), root, present, &proof));
}

test "a divergent storage leaf proves a zero slot" {
    const allocator = std.testing.allocator;
    const present = [_]u8{0} ** 32;
    const absent = [_]u8{1} ** 32;
    // RLP list containing the even-length leaf path and a storage value of 1.
    var leaf = [_]u8{ 0xe3, 0xa1, 0x20 } ++ primitives.Hash.keccak256(&present) ++ [_]u8{1};
    const root = primitives.Hash.keccak256(&leaf);
    const proof = [_][]const u8{&leaf};
    try std.testing.expect(try primitives.Proof.verifyStorageSlotProof(allocator, &root, &absent, "", &proof));
    try std.testing.expect(!try primitives.Proof.verifyStorageSlotProof(allocator, &root, &present, "", &proof));
    leaf[leaf.len - 1] ^= 1;
    try std.testing.expect(!try primitives.Proof.verifyStorageSlotProof(allocator, &root, &absent, "", &proof));
}

fn emptyAccountResolver(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: RpcRequest,
) ![]u8 {
    _ = context;
    _ = request.params_json;
    if (std.mem.eql(u8, request.method, "eth_getCode")) {
        return allocator.dupe(u8, "\"0x\"");
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"nonce\":\"0x0\",\"balance\":\"0x0\",\"codeHash\":\"0x{s}\",\"storageHash\":\"0x{s}\",\"accountProof\":[],\"storageProof\":[]}}",
        .{
            "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
            "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        },
    );
}

test "extractJsonRpcResult accepts error:null and rejects error objects" {
    const allocator = std.testing.allocator;

    const result = try extractJsonRpcResult(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":null,\"result\":\"0x01\"}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"0x01\"", result);

    try std.testing.expectError(
        error.UpstreamRpcFailed,
        extractJsonRpcResult(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"x\"}}"),
    );
    try std.testing.expectError(error.InvalidUpstreamRpcResponse, extractJsonRpcResult(allocator, "not json"));
    try std.testing.expectError(error.InvalidUpstreamRpcResponse, extractJsonRpcResult(allocator, "{\"id\":1}"));
}

test "resolver failures keep UpstreamRpcFailed and OutOfMemory distinct from MalformedProof" {
    const allocator = std.testing.allocator;
    const address = primitives.Address{ .bytes = [_]u8{0x42} ** 20 };
    try std.testing.expectEqual(error.UpstreamTimeout, classifyResolveError(error.UpstreamTimeout));

    const upstream_source = ProofSource{
        .url = "fixture://upstream-failure",
        .resolver = .{ .context = null, .resolve = &upstreamFailureResolver },
    };
    try std.testing.expectError(
        error.UpstreamRpcFailed,
        readBalance(allocator, upstream_source, primitives.AccountState.EMPTY_TRIE_ROOT, address, "0x1"),
    );

    const oom_source = ProofSource{
        .url = "fixture://oom",
        .resolver = .{ .context = null, .resolve = &outOfMemoryResolver },
    };
    try std.testing.expectError(
        error.OutOfMemory,
        readBalance(allocator, oom_source, primitives.AccountState.EMPTY_TRIE_ROOT, address, "0x1"),
    );

    const malformed_source = ProofSource{
        .url = "fixture://malformed",
        .resolver = .{ .context = null, .resolve = &malformedProofResolver },
    };
    try std.testing.expectError(
        error.MalformedProof,
        readBalance(allocator, malformed_source, primitives.AccountState.EMPTY_TRIE_ROOT, address, "0x1"),
    );
}

fn upstreamFailureResolver(context: ?*anyopaque, allocator: std.mem.Allocator, request: RpcRequest) ![]u8 {
    _ = context;
    _ = allocator;
    _ = request;
    return error.ConnectionRefused;
}

fn outOfMemoryResolver(context: ?*anyopaque, allocator: std.mem.Allocator, request: RpcRequest) ![]u8 {
    _ = context;
    _ = allocator;
    _ = request;
    return error.OutOfMemory;
}

fn malformedProofResolver(context: ?*anyopaque, allocator: std.mem.Allocator, request: RpcRequest) ![]u8 {
    _ = context;
    _ = request;
    return allocator.dupe(u8, "{\"nonce\":\"zz\"}");
}

test "readLimitedProofBody accepts exactly the cap and rejects one byte over" {
    const allocator = std.testing.allocator;

    var exact: std.Io.Reader = .fixed("abcd");
    const body = try readLimitedProofBody(allocator, &exact, 4);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("abcd", body);

    var over: std.Io.Reader = .fixed("abcde");
    try std.testing.expectError(error.ProofResponseTooLarge, readLimitedProofBody(allocator, &over, 4));
}

test "readLimitedProofBody maps ReadFailed without a body error to InvalidCompressedResponse" {
    const allocator = std.testing.allocator;

    var failing_reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.ReadFailed, readLimitedProofBody(allocator, &failing_reader, 4));
    try std.testing.expectEqual(error.InvalidCompressedResponse, resolveProofBodyReadError(null));
    try std.testing.expectEqual(error.HttpChunkTruncated, resolveProofBodyReadError(error.HttpChunkTruncated));
}
