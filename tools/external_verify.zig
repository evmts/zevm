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
    UnexpectedRpcResponse,
    RpcSmokeFailed,
};

const execution_spec_state_fixture_paths = [_][]const u8{
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_paris_state_test_tx_type_0.json",
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_cancun_state_test_tx_type_0.json",
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_cancun_state_test_tx_type_1.json",
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_shanghai_state_test_tx_type_0.json",
};

const execution_spec_blockchain_fixture_paths = [_][]const u8{
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/blockchain_london_invalid_filled.json",
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/blockchain_london_valid_filled.json",
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/blockchain_shanghai_invalid_filled_engine.json",
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/blockchain_shanghai_valid_filled_engine.json",
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_cancun_blockchain_test_engine_tx_type_0.json",
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_cancun_blockchain_test_tx_type_0.json",
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_istanbul_blockchain_test_tx_type_0.json",
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_london_blockchain_test_tx_type_0.json",
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_paris_blockchain_test_engine_tx_type_0.json",
    "execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_shanghai_blockchain_test_engine_tx_type_0.json",
};

const legacy_state_fixture_dirs = [_][]const u8{
    "ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stArgsZeroOneBalance",
    "ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stAttackTest",
    "ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stCallCodes",
    "ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stChainId",
    "ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stRecursiveCreate",
    "ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stSLoadTest",
};

const hive_rpc_fixture_paths = [_][]const u8{
    "execution-apis/tests/eth_chainId/get-chain-id.io",
    "execution-apis/tests/eth_blobBaseFee/get-current-blobfee.io",
    "execution-apis/tests/eth_getBalance/get-balance-unknown-account.io",
    "execution-apis/tests/eth_getCode/get-code-unknown-account.io",
    "execution-apis/tests/eth_getStorageAt/get-storage-unknown-account.io",
    "execution-apis/tests/eth_getTransactionCount/get-nonce-unknown-account.io",
    "execution-apis/tests/eth_syncing/check-syncing.io",
    "execution-apis/tests/net_version/get-network-id.io",
};

// TODO(external-verify): execution-spec-tests/fixtures is absent in this checkout; when it is populated, walk fixtures/state_tests and fixtures/blockchain_tests directly.
// TODO(external-verify): continue legacy state expansion with another GeneralStateTests directory and keep state-root/logs assertions enabled.
// TODO(external-verify): activate the remaining rpc-compat .io files after importing execution-apis genesis.json, chain.rlp, and headfcu.json into the ZEVM runtime.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3) return VerifyError.MissingArgument;

    const repo_root = args[1];
    const zevm_bin = args[2];

    try runExecutionSpecStateFixtures(allocator, repo_root);
    try runLegacyInvalidIntrinsicGasFixture(allocator, repo_root);
    try runLegacyStateFixtures(allocator, repo_root);
    try runBlockchainFixtureSmoke(allocator, repo_root);
    try runExecutionSpecBlockchainStructuralFixtures(allocator, repo_root);
    try runHiveRpcCompatibilityFixtures(allocator, repo_root, zevm_bin);
}

fn runExecutionSpecStateFixtures(allocator: std.mem.Allocator, repo_root: []const u8) !void {
    for (execution_spec_state_fixture_paths) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ repo_root, relative_path });
        defer allocator.free(path);
        try runStateFixtureFile(allocator, path);
    }
}

fn runStateFixtureFile(allocator: std.mem.Allocator, path: []const u8) !void {
    var parsed = try readJson(allocator, path);
    defer parsed.deinit();

    var case_count: usize = 0;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        try runGeneratedStateFixture(allocator, entry.value_ptr.*);
        case_count += 1;
    }

    if (case_count == 0) return VerifyError.InvalidFixture;
}

fn runGeneratedStateFixture(allocator: std.mem.Allocator, fixture: std.json.Value) !void {
    const post_by_fork = try field(fixture, "post");
    var ran: usize = 0;
    var fork_it = post_by_fork.object.iterator();
    while (fork_it.next()) |fork_entry| {
        const post_cases = fork_entry.value_ptr.*;
        if (post_cases != .array) return VerifyError.InvalidFixture;

        for (post_cases.array.items) |post_case| {
            const hardfork = try hardforkFromFixtureName(fork_entry.key_ptr.*);
            try runGeneratedStatePostCase(allocator, fixture, post_case, hardfork);
            ran += 1;
        }
    }

    if (ran == 0) return VerifyError.InvalidFixture;
}

fn runGeneratedStatePostCase(allocator: std.mem.Allocator, fixture: std.json.Value, post_case: std.json.Value, hardfork: guillotine_mini.Hardfork) !void {
    if (post_case.object.get("expectException")) |_| return VerifyError.UnexpectedTransactionResult;

    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    try seedPreState(allocator, &sm, try field(fixture, "pre"));

    const indexes = try indexesFromPostCase(post_case);
    const tx = try legacyTxFromFixtureCase(allocator, fixture, indexes);
    defer tx.deinit(allocator);

    const block_ctx = try blockContextFromFixture(fixture, hardfork);
    var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };
    var receipt = try zevm.tx_processor.processTransactionWithOptions(
        allocator,
        &sm,
        adapter.hostInterface(),
        tx.sender,
        tx.tx,
        block_ctx,
        tx.options.withHardfork(hardfork),
    );
    defer receipt.deinit(allocator);

    const status = receipt.status orelse return VerifyError.UnexpectedTransactionResult;
    if (!status.success) return VerifyError.UnexpectedTransactionResult;

    try assertState(allocator, &sm, try field(post_case, "state"));
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
    defer tx.deinit(allocator);

    var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };
    const result = zevm.tx_processor.processTransaction(
        allocator,
        &sm,
        adapter.hostInterface(),
        tx.sender,
        tx.tx,
        try blockContextFromFixture(fixture, .CANCUN),
    );
    try expectTxError(zevm.tx_processor.TxError.IntrinsicGasExceedsLimit, result);

    const expect_items = try field(fixture, "expect");
    const expected = try field(expect_items.array.items[0], "result");
    try assertState(allocator, &sm, expected);
}

fn runLegacyStateFixtures(allocator: std.mem.Allocator, repo_root: []const u8) !void {
    for (legacy_state_fixture_dirs) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ repo_root, relative_path });
        defer allocator.free(path);
        try runLegacyStateFixtureDir(allocator, path);
    }
}

fn runLegacyStateFixtureDir(allocator: std.mem.Allocator, path: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var names = std.ArrayList([]const u8){};
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanBytes);

    if (names.items.len == 0) return VerifyError.InvalidFixture;
    for (names.items) |name| {
        const file_path = try std.fs.path.join(allocator, &.{ path, name });
        defer allocator.free(file_path);
        runLegacyStateFixtureFile(allocator, file_path) catch |err| {
            std.debug.print("legacy state fixture failed: {s}: {s}\n", .{ file_path, @errorName(err) });
            return err;
        };
    }
}

fn lessThanBytes(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn runLegacyStateFixtureFile(allocator: std.mem.Allocator, path: []const u8) !void {
    var parsed = try readJson(allocator, path);
    defer parsed.deinit();

    var case_count: usize = 0;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        try runLegacyCancunStateFixture(allocator, entry.value_ptr.*);
        case_count += 1;
    }

    if (case_count == 0) return VerifyError.InvalidFixture;
}

fn runLegacyCancunStateFixture(allocator: std.mem.Allocator, fixture: std.json.Value) !void {
    const post_by_fork = try field(fixture, "post");
    var ran: usize = 0;
    var fork_it = post_by_fork.object.iterator();
    while (fork_it.next()) |fork_entry| {
        const hardfork = try hardforkFromFixtureName(fork_entry.key_ptr.*);
        const post_cases = fork_entry.value_ptr.*;
        if (post_cases != .array) return VerifyError.InvalidFixture;

        for (post_cases.array.items) |post_case| {
            try runLegacyStatePostCase(allocator, fixture, post_case, hardfork);
            ran += 1;
        }
    }

    if (ran == 0) return VerifyError.InvalidFixture;
}

fn runLegacyStatePostCase(allocator: std.mem.Allocator, fixture: std.json.Value, post_case: std.json.Value, hardfork: guillotine_mini.Hardfork) !void {
    if (post_case.object.get("expectException")) |_| return VerifyError.UnexpectedTransactionResult;

    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    try seedPreState(allocator, &sm, try field(fixture, "pre"));

    const indexes = try indexesFromPostCase(post_case);
    const tx = try legacyTxFromFixtureCase(allocator, fixture, indexes);
    defer tx.deinit(allocator);

    const block_ctx = try blockContextFromFixture(fixture, hardfork);
    var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };
    var receipt = try zevm.tx_processor.processTransactionWithOptions(
        allocator,
        &sm,
        adapter.hostInterface(),
        tx.sender,
        tx.tx,
        block_ctx,
        tx.options.withHardfork(hardfork),
    );
    defer receipt.deinit(allocator);

    const actual_state_root = try computeStateRoot(allocator, &sm, hardfork);
    const expected_state_root = try parseHashValue(try field(post_case, "hash"));
    if (!std.mem.eql(u8, &actual_state_root, &expected_state_root)) {
        const actual_hex = std.fmt.bytesToHex(actual_state_root, .lower);
        const expected_hex = std.fmt.bytesToHex(expected_state_root, .lower);
        std.debug.print("legacy state root mismatch fork={s} indexes(data={}, gas={}, value={}) actual=0x{s} expected=0x{s}\n", .{ hardfork.toString(), indexes.data, indexes.gas, indexes.value, &actual_hex, &expected_hex });
        return VerifyError.UnexpectedState;
    }

    const actual_logs_hash = try computeLogsHash(allocator, receipt.logs);
    const expected_logs_hash = try parseHashValue(try field(post_case, "logs"));
    if (!std.mem.eql(u8, &actual_logs_hash, &expected_logs_hash)) return VerifyError.UnexpectedTransactionResult;
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

fn runExecutionSpecBlockchainStructuralFixtures(allocator: std.mem.Allocator, repo_root: []const u8) !void {
    for (execution_spec_blockchain_fixture_paths) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ repo_root, relative_path });
        defer allocator.free(path);
        try runBlockchainFixtureStructuralFile(allocator, path);
    }
}

fn runBlockchainFixtureStructuralFile(allocator: std.mem.Allocator, path: []const u8) !void {
    var parsed = try readJson(allocator, path);
    defer parsed.deinit();

    var case_count: usize = 0;
    var block_count: usize = 0;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        case_count += 1;
        const fixture = entry.value_ptr.*;
        const genesis_hash = try stringField(try field(fixture, "genesisBlockHeader"), "hash");
        const valid_chain = std.mem.indexOf(u8, path, "invalid") == null;
        if (fixture.object.get("blocks")) |blocks| {
            if (blocks.array.items.len == 0) return VerifyError.InvalidFixture;

            var expected_parent = genesis_hash;
            for (blocks.array.items, 1..) |block, expected_number| {
                const header = try blockHeaderFromFixtureBlock(block);
                const parent_hash = try stringField(header, "parentHash");
                if (valid_chain and !std.mem.eql(u8, expected_parent, parent_hash)) return VerifyError.InvalidFixture;
                const block_number = try parseQuantity(try field(header, "number"));
                if (valid_chain and block_number != expected_number) return VerifyError.InvalidFixture;
                expected_parent = try stringField(header, "hash");

                if (block.object.get("transactions")) |txs| {
                    if (txs != .array) return VerifyError.InvalidFixture;
                } else if (valid_chain) {
                    return VerifyError.MissingField;
                }
                block_count += 1;
            }

            if (valid_chain) {
                const last_hash = try stringField(fixture, "lastblockhash");
                if (!std.mem.eql(u8, expected_parent, last_hash)) return VerifyError.InvalidFixture;
            }
        } else if (fixture.object.get("engineNewPayloads")) |payloads| {
            if (payloads.array.items.len == 0) return VerifyError.InvalidFixture;

            var expected_parent = genesis_hash;
            for (payloads.array.items, 1..) |payload_item, expected_number| {
                const params = try field(payload_item, "params");
                if (params.array.items.len == 0) return VerifyError.InvalidFixture;
                const payload = params.array.items[0];
                const parent_hash = try stringField(payload, "parentHash");
                if (valid_chain and !std.mem.eql(u8, expected_parent, parent_hash)) return VerifyError.InvalidFixture;
                const block_number = try parseQuantity(try field(payload, "blockNumber"));
                if (valid_chain and block_number != expected_number) return VerifyError.InvalidFixture;
                expected_parent = try stringField(payload, "blockHash");

                const txs = try field(payload, "transactions");
                if (txs != .array) return VerifyError.InvalidFixture;
                block_count += 1;
            }

            if (valid_chain) {
                const last_hash = try stringField(fixture, "lastblockhash");
                if (!std.mem.eql(u8, expected_parent, last_hash)) return VerifyError.InvalidFixture;
            }
        } else {
            return VerifyError.MissingField;
        }
    }

    if (case_count == 0 or block_count == 0) return VerifyError.InvalidFixture;
}

fn blockHeaderFromFixtureBlock(block: std.json.Value) !std.json.Value {
    if (block.object.get("blockHeader")) |header| return header;
    if (block.object.get("rlp_decoded")) |decoded| return try field(decoded, "blockHeader");
    return VerifyError.MissingField;
}

fn runHiveRpcCompatibilityFixtures(allocator: std.mem.Allocator, repo_root: []const u8, zevm_bin: []const u8) !void {
    const simulator_path = try std.fs.path.join(allocator, &.{
        repo_root,
        "hive/simulators/ethereum/rpc-compat/testload.go",
    });
    defer allocator.free(simulator_path);
    std.fs.accessAbsolute(simulator_path, .{}) catch return VerifyError.InvalidFixture;

    const forkenv_path = try std.fs.path.join(allocator, &.{ repo_root, "execution-apis/tests/forkenv.json" });
    defer allocator.free(forkenv_path);
    var forkenv = try readJson(allocator, forkenv_path);
    defer forkenv.deinit();
    const chain_id_text = try stringField(forkenv.value, "HIVE_CHAIN_ID");

    const port: u16 = 18545;
    var port_buf: [16]u8 = undefined;
    const port_arg = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    var child = std.process.Child.init(&.{
        zevm_bin,
        "--host",
        "127.0.0.1",
        "--port",
        port_arg,
        "--chain-id",
        chain_id_text,
    }, allocator);
    child.cwd = repo_root;
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Close;
    child.stderr_behavior = .Close;
    try child.spawn();
    defer _ = child.kill() catch {};

    for (hive_rpc_fixture_paths) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ repo_root, relative_path });
        defer allocator.free(path);
        var test_case = try readRpcIoTest(allocator, path);
        defer test_case.deinit(allocator);
        try runRpcIoTest(allocator, port, test_case);
    }
}

const RpcIoMessage = struct {
    data: []const u8,
    send: bool,
};

const RpcIoTest = struct {
    messages: []RpcIoMessage,

    fn deinit(self: *RpcIoTest, allocator: std.mem.Allocator) void {
        for (self.messages) |message| {
            allocator.free(message.data);
        }
        allocator.free(self.messages);
    }
};

fn readRpcIoTest(allocator: std.mem.Allocator, path: []const u8) !RpcIoTest {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(bytes);

    var messages = std.ArrayList(RpcIoMessage){};
    errdefer {
        for (messages.items) |message| allocator.free(message.data);
        messages.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;

        if (std.mem.startsWith(u8, line, ">>") or std.mem.startsWith(u8, line, "<<")) {
            const data = std.mem.trim(u8, line[2..], " \t\r");
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{ .allocate = .alloc_always }) catch return VerifyError.InvalidFixture;
            parsed.deinit();
            try messages.append(allocator, .{
                .data = try allocator.dupe(u8, data),
                .send = std.mem.startsWith(u8, line, ">>"),
            });
        } else {
            return VerifyError.InvalidFixture;
        }
    }

    if (messages.items.len == 0) return VerifyError.InvalidFixture;
    return .{ .messages = try messages.toOwnedSlice(allocator) };
}

fn runRpcIoTest(allocator: std.mem.Allocator, port: u16, test_case: RpcIoTest) !void {
    var response: ?[]u8 = null;
    defer if (response) |body| allocator.free(body);

    for (test_case.messages) |message| {
        if (message.send) {
            if (response) |old_body| {
                allocator.free(old_body);
                response = null;
            }
            response = try waitForRpc(allocator, port, message.data);
        } else {
            const body = response orelse return VerifyError.InvalidFixture;
            try expectJsonEqual(allocator, message.data, body);
            allocator.free(body);
            response = null;
        }
    }

    if (response != null) return VerifyError.InvalidFixture;
}

fn expectJsonEqual(allocator: std.mem.Allocator, expected_text: []const u8, actual_text: []const u8) !void {
    var expected = std.json.parseFromSlice(std.json.Value, allocator, expected_text, .{ .allocate = .alloc_always }) catch return VerifyError.UnexpectedRpcResponse;
    defer expected.deinit();
    var actual = std.json.parseFromSlice(std.json.Value, allocator, actual_text, .{ .allocate = .alloc_always }) catch return VerifyError.UnexpectedRpcResponse;
    defer actual.deinit();

    if (!jsonValuesEqual(expected.value, actual.value)) return VerifyError.UnexpectedRpcResponse;
}

fn jsonValuesEqual(expected: std.json.Value, actual: std.json.Value) bool {
    if (@as(std.meta.Tag(std.json.Value), expected) != @as(std.meta.Tag(std.json.Value), actual)) return false;
    return switch (expected) {
        .null => true,
        .bool => |value| value == actual.bool,
        .integer => |value| value == actual.integer,
        .float => |value| value == actual.float,
        .number_string => |value| std.mem.eql(u8, value, actual.number_string),
        .string => |value| std.mem.eql(u8, value, actual.string),
        .array => |array| blk: {
            if (array.items.len != actual.array.items.len) break :blk false;
            for (array.items, actual.array.items) |expected_item, actual_item| {
                if (!jsonValuesEqual(expected_item, actual_item)) break :blk false;
            }
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != actual.object.count()) break :blk false;
            var it = object.iterator();
            while (it.next()) |entry| {
                const actual_value = actual.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValuesEqual(entry.value_ptr.*, actual_value)) break :blk false;
            }
            break :blk true;
        },
    };
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

    options: zevm.tx_processor.ProcessTransactionOptions = .{},

    fn deinit(self: FixtureTx, allocator: std.mem.Allocator) void {
        allocator.free(self.tx.data);
        if (self.options.access_list) |access_list| {
            freeAccessList(allocator, access_list);
        }
    }
};

const TransactionIndexes = struct {
    data: usize = 0,
    gas: usize = 0,
    value: usize = 0,
};

fn legacyTxFromFixture(allocator: std.mem.Allocator, fixture: std.json.Value) !FixtureTx {
    return legacyTxFromFixtureCase(allocator, fixture, .{});
}

fn legacyTxFromFixtureCase(allocator: std.mem.Allocator, fixture: std.json.Value, indexes: TransactionIndexes) !FixtureTx {
    const transaction = try field(fixture, "transaction");
    const sender = if (transaction.object.get("sender")) |sender_value|
        try parseAddressValue(sender_value)
    else
        try senderFromPre(try field(fixture, "pre"));

    const gas_limit = try parseQuantityAtIndex(try field(transaction, "gasLimit"), indexes.gas);
    const value = try parseQuantityAtIndex(try field(transaction, "value"), indexes.value);
    const data = try dataFromTransactionAtIndex(allocator, transaction, indexes.data);
    errdefer allocator.free(data);
    const access_list = try accessListFromTransactionAtIndex(allocator, transaction, indexes.data);
    errdefer if (access_list) |list| freeAccessList(allocator, list);

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
        .options = .{
            .access_list = access_list,
            .receipt_type = if (access_list == null) .legacy else .eip2930,
        },
    };
}

fn dataFromTransaction(allocator: std.mem.Allocator, transaction: std.json.Value) ![]u8 {
    return dataFromTransactionAtIndex(allocator, transaction, 0);
}

fn dataFromTransactionAtIndex(allocator: std.mem.Allocator, transaction: std.json.Value, index: usize) ![]u8 {
    const data_value = try field(transaction, "data");
    const data_text = switch (data_value) {
        .array => |array| blk: {
            if (index >= array.items.len or array.items[index] != .string) return VerifyError.InvalidFixture;
            break :blk array.items[index].string;
        },
        .string => |text| blk: {
            if (index != 0) return VerifyError.InvalidFixture;
            break :blk text;
        },
        else => return VerifyError.InvalidFixture,
    };
    return try hexBytes(allocator, data_text);
}

fn accessListFromTransactionAtIndex(allocator: std.mem.Allocator, transaction: std.json.Value, index: usize) !?primitives.AccessList.AccessList {
    const access_lists_value = transaction.object.get("accessLists") orelse return null;
    if (access_lists_value != .array) return VerifyError.InvalidFixture;
    if (index >= access_lists_value.array.items.len) return VerifyError.InvalidFixture;

    const selected = access_lists_value.array.items[index];
    if (selected != .array) return VerifyError.InvalidFixture;

    var entries = try allocator.alloc(primitives.AccessList.AccessListEntry, selected.array.items.len);
    var initialized_entries: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized_entries) : (i += 1) {
            allocator.free(entries[i].storage_keys);
        }
        allocator.free(entries);
    }

    for (selected.array.items, 0..) |item, i| {
        const storage_keys_value = try field(item, "storageKeys");
        if (storage_keys_value != .array) return VerifyError.InvalidFixture;

        const storage_keys = try allocator.alloc(primitives.Hash.Hash, storage_keys_value.array.items.len);
        errdefer allocator.free(storage_keys);
        for (storage_keys_value.array.items, 0..) |storage_key_value, j| {
            storage_keys[j] = try parseHashValue(storage_key_value);
        }

        entries[i] = .{
            .address = try parseAddressValue(try field(item, "address")),
            .storage_keys = storage_keys,
        };
        initialized_entries += 1;
    }

    return entries;
}

fn freeAccessList(allocator: std.mem.Allocator, access_list: primitives.AccessList.AccessList) void {
    for (access_list) |entry| {
        allocator.free(entry.storage_keys);
    }
    allocator.free(access_list);
}

fn indexesFromPostCase(post_case: std.json.Value) !TransactionIndexes {
    const indexes = try field(post_case, "indexes");
    return .{
        .data = try parseIndex(try field(indexes, "data")),
        .gas = try parseIndex(try field(indexes, "gas")),
        .value = try parseIndex(try field(indexes, "value")),
    };
}

fn parseIndex(value: std.json.Value) !usize {
    return switch (value) {
        .integer => |number| if (number < 0) 0 else std.math.cast(usize, number) orelse VerifyError.InvalidQuantity,
        .string => |text| blk: {
            const parsed = try parseQuantityString(text);
            break :blk std.math.cast(usize, parsed) orelse VerifyError.InvalidQuantity;
        },
        else => VerifyError.InvalidFixture,
    };
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

fn hardforkFromFixtureName(name: []const u8) !guillotine_mini.Hardfork {
    if (guillotine_mini.Hardfork.fromString(name)) |hardfork| return hardfork;
    if (std.ascii.eqlIgnoreCase(name, "EIP150")) return .TANGERINE_WHISTLE;
    if (std.ascii.eqlIgnoreCase(name, "EIP158")) return .SPURIOUS_DRAGON;
    return VerifyError.InvalidFixture;
}

fn blockContextFromFixture(fixture: std.json.Value, hardfork: guillotine_mini.Hardfork) !guillotine_mini.BlockContext {
    const env = try field(fixture, "env");
    const base_fee = if (env.object.get("currentBaseFee")) |value| try parseQuantity(value) else 0;
    const random = if (env.object.get("currentRandom")) |value| try parseQuantity(value) else 0;
    const difficulty = if (hardfork.isAtLeast(.MERGE))
        0
    else if (env.object.get("currentDifficulty")) |value|
        try parseQuantity(value)
    else
        0;
    const chain_id = if (fixture.object.get("config")) |config_value|
        std.math.cast(u64, try parseQuantity(try field(config_value, "chainid"))) orelse return VerifyError.InvalidQuantity
    else
        1;
    return .{
        .chain_id = chain_id,
        .block_number = std.math.cast(u64, try parseQuantity(try field(env, "currentNumber"))) orelse return VerifyError.InvalidQuantity,
        .block_timestamp = std.math.cast(u64, try parseQuantity(try field(env, "currentTimestamp"))) orelse return VerifyError.InvalidQuantity,
        .block_difficulty = difficulty,
        .block_prevrandao = if (hardfork.isAtLeast(.MERGE)) random else 0,
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
        if (account.object.get("shouldnotexist")) |_| {
            if (try sm.getBalance(address) != 0) return VerifyError.UnexpectedState;
            if (try sm.getNonce(address) != 0) return VerifyError.UnexpectedState;
            if ((try sm.getCode(address)).len != 0) return VerifyError.UnexpectedState;
            continue;
        }

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

fn computeStateRoot(allocator: std.mem.Allocator, sm: *state_manager.StateManager, hardfork: guillotine_mini.Hardfork) !primitives.Hash.Hash {
    var keys = std.ArrayList([]const u8){};
    defer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }
    var values = std.ArrayList([]const u8){};
    defer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    var it = sm.accountIterator();
    while (it.next()) |entry| {
        const address = entry.key_ptr.*;
        const nonce = try sm.getNonce(address);
        const balance = try sm.getBalance(address);
        const code = try sm.getCode(address);

        var code_hash = primitives.State.EMPTY_CODE_HASH;
        if (code.len > 0) {
            std.crypto.hash.sha3.Keccak256.hash(code, &code_hash, .{});
        }

        const storage_root = try computeStorageRoot(allocator, sm, address);
        const empty_account = nonce == 0 and
            balance == 0 and
            std.mem.eql(u8, &code_hash, &primitives.State.EMPTY_CODE_HASH);

        // EIP-161 (Spurious Dragon) defines emptiness by nonce, balance, and
        // code. Legacy state fixtures can seed storage-only empty accounts;
        // those must not be encoded in post-Spurious state roots. Before
        // Spurious Dragon, explicitly present empty accounts are root entries.
        if (empty_account and hardfork.isAtLeast(.SPURIOUS_DRAGON)) {
            continue;
        }

        const account = primitives.AccountState.AccountState.from(.{
            .nonce = nonce,
            .balance = balance,
            .storage_root = storage_root,
            .code_hash = code_hash,
        });

        const key = try allocator.dupe(u8, address.bytes[0..]);
        var key_owned = true;
        errdefer if (key_owned) allocator.free(key);
        const value = try account.rlpEncode(allocator);
        var value_owned = true;
        errdefer if (value_owned) allocator.free(value);

        try keys.append(allocator, key);
        key_owned = false;
        try values.append(allocator, value);
        value_owned = false;
    }

    return try primitives.TrieHash.secure_trie_root(allocator, keys.items, values.items);
}

fn computeStorageRoot(allocator: std.mem.Allocator, sm: *state_manager.StateManager, address: primitives.Address) !primitives.Hash.Hash {
    const slots = sm.journaled_state.storage_cache.cache.getPtr(address) orelse return primitives.State.EMPTY_TRIE_ROOT;

    var keys = std.ArrayList([]const u8){};
    defer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }
    var values = std.ArrayList([]const u8){};
    defer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    var it = slots.iterator();
    while (it.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value == 0) continue;

        var slot_bytes: primitives.Hash.Hash = undefined;
        std.mem.writeInt(u256, &slot_bytes, entry.key_ptr.*, .big);
        const key = try allocator.dupe(u8, slot_bytes[0..]);
        var key_owned = true;
        errdefer if (key_owned) allocator.free(key);
        const encoded_value = try primitives.Rlp.encode(allocator, value);
        var value_owned = true;
        errdefer if (value_owned) allocator.free(encoded_value);

        try keys.append(allocator, key);
        key_owned = false;
        try values.append(allocator, encoded_value);
        value_owned = false;
    }

    return try primitives.TrieHash.secure_trie_root(allocator, keys.items, values.items);
}

fn computeLogsHash(allocator: std.mem.Allocator, logs: []const primitives.EventLog.EventLog) !primitives.Hash.Hash {
    var encoded_logs = std.ArrayList([]const u8){};
    defer {
        for (encoded_logs.items) |encoded| allocator.free(encoded);
        encoded_logs.deinit(allocator);
    }

    for (logs) |log| {
        try encoded_logs.append(allocator, try encodeLogForHash(allocator, log));
    }

    const encoded = try encodeRlpListFromEncoded(allocator, encoded_logs.items);
    defer allocator.free(encoded);

    var out: primitives.Hash.Hash = undefined;
    std.crypto.hash.sha3.Keccak256.hash(encoded, &out, .{});
    return out;
}

fn encodeLogForHash(allocator: std.mem.Allocator, log: primitives.EventLog.EventLog) ![]const u8 {
    const address = try primitives.Rlp.encodeBytes(allocator, log.address.bytes[0..]);
    defer allocator.free(address);

    var encoded_topics = std.ArrayList([]const u8){};
    defer {
        for (encoded_topics.items) |topic| allocator.free(topic);
        encoded_topics.deinit(allocator);
    }
    for (log.topics) |topic| {
        try encoded_topics.append(allocator, try primitives.Rlp.encodeBytes(allocator, topic[0..]));
    }
    const topics = try encodeRlpListFromEncoded(allocator, encoded_topics.items);
    defer allocator.free(topics);

    const data = try primitives.Rlp.encodeBytes(allocator, log.data);
    defer allocator.free(data);

    const fields = [_][]const u8{ address, topics, data };
    return try encodeRlpListFromEncoded(allocator, &fields);
}

fn encodeRlpListFromEncoded(allocator: std.mem.Allocator, encoded_items: []const []const u8) ![]const u8 {
    var payload_len: usize = 0;
    for (encoded_items) |item| {
        payload_len = std.math.add(usize, payload_len, item.len) catch return VerifyError.InvalidFixture;
    }

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);
    if (payload_len < 56) {
        try result.append(allocator, 0xc0 + @as(u8, @intCast(payload_len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, payload_len);
        defer allocator.free(len_bytes);
        try result.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try result.appendSlice(allocator, len_bytes);
    }

    for (encoded_items) |item| {
        try result.appendSlice(allocator, item);
    }
    return try result.toOwnedSlice(allocator);
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

fn parseHashValue(value: std.json.Value) !primitives.Hash.Hash {
    if (value != .string) return VerifyError.InvalidHexData;
    return parseHashText(value.string);
}

fn parseHashText(text: []const u8) !primitives.Hash.Hash {
    var hex = text;
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) {
        hex = hex[2..];
    }
    if (hex.len != 64) return VerifyError.InvalidHexData;
    var out: primitives.Hash.Hash = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return VerifyError.InvalidHexData;
    return out;
}

fn parseFirstQuantity(value: std.json.Value) !u256 {
    return parseQuantityAtIndex(value, 0);
}

fn parseQuantityAtIndex(value: std.json.Value, index: usize) !u256 {
    return switch (value) {
        .array => |array| blk: {
            if (index >= array.items.len) return VerifyError.InvalidFixture;
            break :blk try parseQuantity(array.items[index]);
        },
        else => blk: {
            if (index != 0) return VerifyError.InvalidFixture;
            break :blk try parseQuantity(value);
        },
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
    var body_start: ?usize = null;
    var content_length: ?usize = null;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const amount = try stream.read(&buffer);
        if (amount == 0) {
            if (body_start == null or content_length == null) return VerifyError.RpcSmokeFailed;
            break;
        }
        try response.appendSlice(allocator, buffer[0..amount]);

        if (body_start == null) {
            if (std.mem.indexOf(u8, response.items, "\r\n\r\n")) |index| {
                body_start = index + 4;
                content_length = parseHttpContentLength(response.items[0..index]) orelse return VerifyError.RpcSmokeFailed;
            }
        }

        if (body_start) |start| {
            const len = content_length orelse return VerifyError.RpcSmokeFailed;
            if (response.items.len >= start + len) break;
        }
    }

    const raw = try response.toOwnedSlice(allocator);
    errdefer allocator.free(raw);
    const start = body_start orelse return VerifyError.RpcSmokeFailed;
    const len = content_length orelse return VerifyError.RpcSmokeFailed;
    if (raw.len < start + len) return VerifyError.RpcSmokeFailed;
    const out = try allocator.dupe(u8, std.mem.trim(u8, raw[start .. start + len], " \t\r\n"));
    allocator.free(raw);
    return out;
}

fn parseHttpContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t\r");
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
}
