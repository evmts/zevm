const std = @import("std");
const primitives = @import("primitives");

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
    ) catch return error.ProofVerifyFailed;
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

    const result_json = resolveJsonRpc(allocator, source, "eth_getProof", params_json) catch return error.MalformedProof;
    defer allocator.free(result_json);

    return parseAccountProof(allocator, result_json) catch return error.MalformedProof;
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

    const result_json = resolveJsonRpc(allocator, source, "eth_getCode", params_json) catch return error.MalformedProof;
    defer allocator.free(result_json);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch return error.MalformedProof;
    defer parsed.deinit();

    const code_hex = switch (parsed.value) {
        .string => |value| value,
        else => return error.MalformedProof,
    };
    return parseHexBytes(allocator, code_hex) catch return error.MalformedProof;
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

    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = request.url },
        .method = .POST,
        .payload = request_body,
        .extra_headers = &[_]std.http.Header{
            .{
                .name = "content-type",
                .value = "application/json",
            },
        },
        .response_writer = &response_writer.writer,
    });
    if (response.status != .ok) return error.UpstreamRpcFailed;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_writer.written(), .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidUpstreamRpcResponse,
    };
    if (object.get("error") != null) return error.UpstreamRpcFailed;
    const result = object.get("result") orelse return error.InvalidUpstreamRpcResponse;
    return stringifyJsonValue(allocator, result);
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

    const account_rlp = if (account.isTotallyEmpty()) null else try account.rlpEncode(allocator);
    defer if (account_rlp) |bytes| allocator.free(bytes);

    const empty: []const u8 = &.{};
    const valid = primitives.Proof.verifyAccountProof(
        allocator,
        &state_root,
        &address.bytes,
        account_rlp orelse empty,
        proof.account_proof,
    ) catch return error.ProofVerifyFailed;
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
        const slot_hex = std.fmt.bufPrint(&slot_buf, "0x{x:0>64}", .{slot}) catch unreachable;
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
        .url = "mock://proof",
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
