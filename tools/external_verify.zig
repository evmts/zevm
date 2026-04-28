const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const zevm = @import("zevm");

const VerifyError = error{
    MissingArgument,
    MissingField,
    InvalidFixture,
    InvalidAddress,
    InvalidQuantity,
    InvalidHexData,
    UnexpectedState,
    UnexpectedGasUsed,
    UnexpectedTransactionResult,
    RpcSmokeFailed,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3) return VerifyError.MissingArgument;

    const repo_root = args[1];
    const zevm_bin = args[2];

    try runExecutionSpecStateFixture(allocator, repo_root);
    try runLegacyInvalidIntrinsicGasFixture(allocator, repo_root);
    try runBlockchainFixtureSmoke(allocator, repo_root);
    try runHiveRpcSmoke(allocator, repo_root, zevm_bin);
}

fn runExecutionSpecStateFixture(allocator: std.mem.Allocator, repo_root: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{
        repo_root,
        "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_paris_state_test_tx_type_0.json",
    });
    defer allocator.free(path);

    var parsed = try readJson(allocator, path);
    defer parsed.deinit();

    const fixture = firstObjectValue(parsed.value);
    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    try seedPreState(allocator, &sm, try field(fixture, "pre"));

    const tx = try legacyTxFromFixture(allocator, fixture);
    defer allocator.free(tx.tx.data);

    var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };
    var receipt = try zevm.tx_processor.processTransaction(
        allocator,
        &sm,
        adapter.hostInterface(),
        tx.sender,
        tx.tx,
        try blockContextFromFixture(fixture),
    );
    defer receipt.deinit(allocator);

    if (!receipt.status.?.success) return VerifyError.UnexpectedTransactionResult;

    const post_by_fork = try field(try field(fixture, "post"), "Paris");
    const post = try field(post_by_fork.array.items[0], "state");
    try assertState(allocator, &sm, post);

    const expected_coinbase_balance = try accountBalanceFromPost(post, "0x2adc25665018aa1fe0e6bc666dac8fc2697ff9ba");
    const priority_fee = tx.tx.gas_price - (try parseQuantity(try field(try field(fixture, "env"), "currentBaseFee")));
    const expected_gas_used = expected_coinbase_balance / priority_fee;
    if (receipt.gas_used != expected_gas_used) return VerifyError.UnexpectedGasUsed;
}

fn runLegacyInvalidIntrinsicGasFixture(allocator: std.mem.Allocator, repo_root: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{
        repo_root,
        "execution-spec-tests/tests/static/state_tests/stExample/invalidTrFiller.json",
    });
    defer allocator.free(path);

    var parsed = try readJson(allocator, path);
    defer parsed.deinit();

    const fixture = firstObjectValue(parsed.value);
    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    try seedPreState(allocator, &sm, try field(fixture, "pre"));

    const tx = try legacyTxFromFixture(allocator, fixture);
    defer allocator.free(tx.tx.data);

    var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };
    const result = zevm.tx_processor.processTransaction(
        allocator,
        &sm,
        adapter.hostInterface(),
        tx.sender,
        tx.tx,
        try blockContextFromFixture(fixture),
    );
    try expectTxError(zevm.tx_processor.TxError.IntrinsicGasExceedsLimit, result);

    const expect_items = try field(fixture, "expect");
    const expected = try field(expect_items.array.items[0], "result");
    try assertState(allocator, &sm, expected);
}

fn runBlockchainFixtureSmoke(allocator: std.mem.Allocator, repo_root: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{
        repo_root,
        "ethereum-tests/BlockchainTests/ValidBlocks/bcExample/optionsTest.json",
    });
    defer allocator.free(path);

    var parsed = try readJson(allocator, path);
    defer parsed.deinit();

    var case_count: usize = 0;
    var saw_empty_block = false;
    var saw_transaction_block = false;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        case_count += 1;
        const fixture = entry.value_ptr.*;
        const genesis_hash = try stringField(try field(fixture, "genesisBlockHeader"), "hash");
        const blocks = try field(fixture, "blocks");
        if (blocks.array.items.len == 0) return VerifyError.InvalidFixture;

        var expected_parent = genesis_hash;
        for (blocks.array.items, 1..) |block, expected_number| {
            const header = try field(block, "blockHeader");
            const parent_hash = try stringField(header, "parentHash");
            if (!std.mem.eql(u8, expected_parent, parent_hash)) return VerifyError.InvalidFixture;
            const block_number = try parseQuantity(try field(header, "number"));
            if (block_number != expected_number) return VerifyError.InvalidFixture;
            expected_parent = try stringField(header, "hash");

            const txs = try field(block, "transactions");
            if (txs.array.items.len == 0) saw_empty_block = true else saw_transaction_block = true;
        }
    }

    if (case_count == 0 or !saw_empty_block or !saw_transaction_block) return VerifyError.InvalidFixture;
}

fn runHiveRpcSmoke(allocator: std.mem.Allocator, repo_root: []const u8, zevm_bin: []const u8) !void {
    const simulator_path = try std.fs.path.join(allocator, &.{
        repo_root,
        "hive/simulators/ethereum/rpc-compat/testload.go",
    });
    defer allocator.free(simulator_path);
    std.fs.accessAbsolute(simulator_path, .{}) catch return VerifyError.InvalidFixture;

    const port: u16 = 18545;
    var port_buf: [16]u8 = undefined;
    const port_arg = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    var child = std.process.Child.init(&.{
        zevm_bin,
        "--host",
        "127.0.0.1",
        "--port",
        port_arg,
    }, allocator);
    child.cwd = repo_root;
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Close;
    child.stderr_behavior = .Close;
    try child.spawn();
    defer _ = child.kill() catch {};

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}";
    const response = try waitForRpc(allocator, port, body);
    defer allocator.free(response);

    if (std.mem.indexOf(u8, response, "\"result\":\"0x7a69\"") == null) {
        return VerifyError.RpcSmokeFailed;
    }
}

fn readJson(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024);
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
}

fn firstObjectValue(value: std.json.Value) std.json.Value {
    var it = value.object.iterator();
    return it.next().?.value_ptr.*;
}

fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return VerifyError.InvalidFixture;
    return value.object.get(name) orelse VerifyError.MissingField;
}

fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    const item = try field(value, name);
    if (item != .string) return VerifyError.InvalidFixture;
    return item.string;
}

fn seedPreState(allocator: std.mem.Allocator, sm: *state_manager.StateManager, pre: std.json.Value) !void {
    var it = pre.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "//")) continue;
        const address = try parseAddressText(entry.key_ptr.*);
        const account = entry.value_ptr.*;
        const balance = try parseQuantity(try field(account, "balance"));
        const nonce = try parseQuantity(try field(account, "nonce"));

        try sm.initAccount(address, balance);
        try sm.setNonce(address, std.math.cast(u64, nonce) orelse return VerifyError.InvalidQuantity);

        const code_text = try stringField(account, "code");
        if (try maybeHexBytes(allocator, code_text)) |code| {
            defer allocator.free(code);
            try sm.setCode(address, code);
        }

        const storage = try field(account, "storage");
        var storage_it = storage.object.iterator();
        while (storage_it.next()) |storage_entry| {
            const slot = try parseQuantityString(storage_entry.key_ptr.*);
            const value = try parseQuantity(storage_entry.value_ptr.*);
            try sm.setStorage(address, slot, value);
        }
    }
}

const FixtureTx = struct {
    sender: primitives.Address,
    tx: primitives.Transaction.LegacyTransaction,
};

fn legacyTxFromFixture(allocator: std.mem.Allocator, fixture: std.json.Value) !FixtureTx {
    const transaction = try field(fixture, "transaction");
    const sender = if (transaction.object.get("sender")) |sender_value|
        try parseAddressValue(sender_value)
    else
        try senderFromPre(try field(fixture, "pre"));

    const gas_limit = try parseFirstQuantity(try field(transaction, "gasLimit"));
    const value = try parseFirstQuantity(try field(transaction, "value"));
    const data = try dataFromTransaction(allocator, transaction);
    errdefer allocator.free(data);

    const to_text = try stringField(transaction, "to");
    const to = if (to_text.len == 0) null else try parseAddressText(to_text);

    return .{
        .sender = sender,
        .tx = .{
            .nonce = std.math.cast(u64, try parseQuantity(try field(transaction, "nonce"))) orelse return VerifyError.InvalidQuantity,
            .gas_price = try parseQuantity(try field(transaction, "gasPrice")),
            .gas_limit = std.math.cast(u64, gas_limit) orelse return VerifyError.InvalidQuantity,
            .to = to,
            .value = value,
            .data = data,
            .v = 0,
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
        },
    };
}

fn dataFromTransaction(allocator: std.mem.Allocator, transaction: std.json.Value) ![]u8 {
    const data_value = try field(transaction, "data");
    const data_text = switch (data_value) {
        .array => |array| blk: {
            if (array.items.len == 0 or array.items[0] != .string) return VerifyError.InvalidFixture;
            break :blk array.items[0].string;
        },
        .string => |text| text,
        else => return VerifyError.InvalidFixture,
    };
    return try hexBytes(allocator, data_text);
}

fn senderFromPre(pre: std.json.Value) !primitives.Address {
    var it = pre.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.indexOf(u8, entry.key_ptr.*, "sender")) |_| {
            return parseAddressText(entry.key_ptr.*);
        }
    }
    return VerifyError.InvalidFixture;
}

fn blockContextFromFixture(fixture: std.json.Value) !guillotine_mini.BlockContext {
    const env = try field(fixture, "env");
    const base_fee = if (env.object.get("currentBaseFee")) |value| try parseQuantity(value) else 0;
    const difficulty = if (env.object.get("currentRandom")) |_| 0 else try parseQuantity(try field(env, "currentDifficulty"));
    const chain_id = if (fixture.object.get("config")) |config_value|
        std.math.cast(u64, try parseQuantity(try field(config_value, "chainid"))) orelse return VerifyError.InvalidQuantity
    else
        1;
    return .{
        .chain_id = chain_id,
        .block_number = std.math.cast(u64, try parseQuantity(try field(env, "currentNumber"))) orelse return VerifyError.InvalidQuantity,
        .block_timestamp = std.math.cast(u64, try parseQuantity(try field(env, "currentTimestamp"))) orelse return VerifyError.InvalidQuantity,
        .block_difficulty = difficulty,
        .block_prevrandao = 0,
        .block_coinbase = try parseAddressValue(try field(env, "currentCoinbase")),
        .block_gas_limit = std.math.cast(u64, try parseQuantity(try field(env, "currentGasLimit"))) orelse return VerifyError.InvalidQuantity,
        .block_base_fee = base_fee,
        .blob_base_fee = 0,
    };
}

fn assertState(allocator: std.mem.Allocator, sm: *state_manager.StateManager, expected_state: std.json.Value) !void {
    var it = expected_state.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "//")) continue;
        const address = try parseAddressText(entry.key_ptr.*);
        const account = entry.value_ptr.*;
        if (account.object.get("shouldnotexist")) |_| continue;

        if (account.object.get("balance")) |balance_value| {
            const actual = try sm.getBalance(address);
            const expected = try parseQuantity(balance_value);
            if (actual != expected) return VerifyError.UnexpectedState;
        }
        if (account.object.get("nonce")) |nonce_value| {
            const actual = try sm.getNonce(address);
            const expected = try parseQuantity(nonce_value);
            if (actual != expected) return VerifyError.UnexpectedState;
        }
        if (account.object.get("code")) |code_value| {
            if (code_value != .string) return VerifyError.InvalidFixture;
            if (try maybeHexBytes(allocator, code_value.string)) |expected_code| {
                defer allocator.free(expected_code);
                const actual = try sm.getCode(address);
                if (!std.mem.eql(u8, actual, expected_code)) return VerifyError.UnexpectedState;
            }
        }
        if (account.object.get("storage")) |storage| {
            var storage_it = storage.object.iterator();
            while (storage_it.next()) |storage_entry| {
                const slot = try parseQuantityString(storage_entry.key_ptr.*);
                const expected = try parseQuantity(storage_entry.value_ptr.*);
                const actual = try sm.getStorage(address, slot);
                if (actual != expected) return VerifyError.UnexpectedState;
            }
        }
    }
}

fn accountBalanceFromPost(post: std.json.Value, address_text: []const u8) !u256 {
    const account = post.object.get(address_text) orelse return VerifyError.MissingField;
    return parseQuantity(try field(account, "balance"));
}

fn expectTxError(expected: zevm.tx_processor.TxError, actual: zevm.tx_processor.TxError!primitives.Receipt.Receipt) !void {
    if (actual) |receipt| {
        var owned_receipt = receipt;
        owned_receipt.deinit(std.heap.page_allocator);
        return VerifyError.UnexpectedTransactionResult;
    } else |err| {
        if (err != expected) return VerifyError.UnexpectedTransactionResult;
    }
}

fn parseAddressValue(value: std.json.Value) !primitives.Address {
    if (value != .string) return VerifyError.InvalidAddress;
    return parseAddressText(value.string);
}

fn parseAddressText(text: []const u8) !primitives.Address {
    const start = if (std.mem.lastIndexOf(u8, text, "0x")) |index| index + 2 else 0;
    if (text.len < start + 40) return VerifyError.InvalidAddress;
    const hex = text[start .. start + 40];
    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch return VerifyError.InvalidAddress;
    return .{ .bytes = bytes };
}

fn parseFirstQuantity(value: std.json.Value) !u256 {
    return switch (value) {
        .array => |array| blk: {
            if (array.items.len == 0) return VerifyError.InvalidFixture;
            break :blk try parseQuantity(array.items[0]);
        },
        else => parseQuantity(value),
    };
}

fn parseQuantity(value: std.json.Value) !u256 {
    return switch (value) {
        .string => |text| parseQuantityString(text),
        .integer => |number| if (number < 0) VerifyError.InvalidQuantity else @intCast(number),
        else => VerifyError.InvalidQuantity,
    };
}

fn parseQuantityString(text: []const u8) !u256 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        if (text.len == 2) return 0;
        return std.fmt.parseInt(u256, text[2..], 16) catch VerifyError.InvalidQuantity;
    }
    if (text.len == 0) return 0;
    return std.fmt.parseInt(u256, text, 10) catch VerifyError.InvalidQuantity;
}

fn maybeHexBytes(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    if (text.len == 0) return try allocator.alloc(u8, 0);
    if (!std.mem.startsWith(u8, text, "0x") and !std.mem.startsWith(u8, text, "0X")) return null;
    return try hexBytes(allocator, text);
}

fn hexBytes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var hex = text;
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) {
        hex = hex[2..];
    }
    if (hex.len == 0) return try allocator.alloc(u8, 0);
    if (hex.len % 2 != 0) return VerifyError.InvalidHexData;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = std.fmt.hexToBytes(out, hex) catch return VerifyError.InvalidHexData;
    return out;
}

fn waitForRpc(allocator: std.mem.Allocator, port: u16, body: []const u8) ![]u8 {
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        if (sendRpcRequest(allocator, port, body)) |response| {
            return response;
        } else |_| {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
    return VerifyError.RpcSmokeFailed;
}

fn sendRpcRequest(allocator: std.mem.Allocator, port: u16, body: []const u8) ![]u8 {
    var stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
    defer stream.close();

    const request = try std.fmt.allocPrint(
        allocator,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ port, body.len, body },
    );
    defer allocator.free(request);
    try stream.writeAll(request);

    var response = std.ArrayList(u8){};
    errdefer response.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const amount = try stream.read(&buffer);
        if (amount == 0) break;
        try response.appendSlice(allocator, buffer[0..amount]);
        if (std.mem.indexOf(u8, response.items, "\r\n\r\n") != null and
            std.mem.indexOf(u8, response.items, "\"jsonrpc\"") != null)
        {
            break;
        }
    }
    return response.toOwnedSlice(allocator);
}
