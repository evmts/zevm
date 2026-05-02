const std = @import("std");

pub const schema_version = "zevm-release-qualification-map.v1";
pub const default_map_path = "docs/specs/qualification/assertion-map.json";

const required_top_level_fields = [_][]const u8{
    "schemaVersion",
    "updated",
    "prdSource",
    "records",
};

const required_record_fields = [_][]const u8{
    "surfaceId",
    "surfaceSection",
    "surfaceCategory",
    "assertionType",
    "assertionIdentifier",
    "expectedContractOutcome",
    "coverageStatus",
};

const allowed_record_fields = [_][]const u8{
    "surfaceId",
    "surfaceSection",
    "surfaceCategory",
    "assertionType",
    "assertionIdentifier",
    "expectedContractOutcome",
    "coverageStatus",
    "gapReason",
    "ownerTicket",
    "notes",
};

const categories = [_][]const u8{
    "startup",
    "configuration",
    "runtime",
    "transport",
    "method",
    "release-asset",
};

const assertion_types = [_][]const u8{
    "default-graph-test",
    "release-asset-validation",
};

const coverage_statuses = [_][]const u8{
    "covered",
    "gap",
    "blocked",
};

const allowed_gate_commands = [_][]const u8{
    "zig build",
    "zig build test",
    "zig build verify-fast",
    "zig build verify",
    "zig build qualification-check",
    "zig build qualification-check -- --require-covered",
};

const release_asset_surface_ids = [_][]const u8{
    "RELEASE_METADATA_RELEASE_TUPLE_JSON",
    "RELEASE_METADATA_LIGHT_DEFAULT_CHECKPOINTS_JSON",
};

const legacy_gap_prefix = "TO" ++ "DO:";

pub const Options = struct {
    map_path: []const u8 = default_map_path,
    require_covered: bool = false,
};

pub const Report = struct {
    total_records: usize = 0,
    covered_records: usize = 0,
    gap_records: usize = 0,
    blocked_records: usize = 0,
};

pub const QualificationError = error{
    DuplicateField,
    DuplicateSurface,
    EmptyString,
    ExplicitGapRemaining,
    InvalidArgs,
    InvalidAssertionType,
    InvalidAssertionEvidence,
    InvalidCategory,
    InvalidCoverageStatus,
    InvalidDate,
    InvalidSchemaVersion,
    InvalidSurfaceId,
    MalformedJson,
    MalformedUtf8,
    MissingAssertionFile,
    MissingAssertionTest,
    MissingField,
    MissingGapReason,
    MissingOwnerTicket,
    MissingRequiredCategory,
    MissingRequiredReleaseAssetMapping,
    UnexpectedField,
    UnsupportedAssertionCommand,
    ValueMismatch,
};

pub fn main() !void {
    runMain() catch |err| {
        if (err == error.InvalidArgs) {
            std.debug.print(
                "usage: qualification-check [--map PATH] [--require-covered]\n",
                .{},
            );
        } else {
            std.debug.print("qualification-check failed: {s}\n", .{@errorName(err)});
        }
        return err;
    };
}

fn runMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = try parseArgs(args);
    const report = try checkFile(allocator, options);

    std.debug.print(
        "qualification map: {d} records, {d} covered, {d} explicit gaps, {d} blocked\n",
        .{ report.total_records, report.covered_records, report.gap_records, report.blocked_records },
    );
    if (report.gap_records == 0 and report.blocked_records == 0) {
        std.debug.print("release-ready coverage: yes\n", .{});
    } else {
        std.debug.print("release-ready coverage: no\n", .{});
    }
}

pub fn parseArgs(args: []const [:0]u8) QualificationError!Options {
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "--map")) {
            index += 1;
            if (index >= args.len) return error.InvalidArgs;
            options.map_path = args[index];
        } else if (std.mem.eql(u8, arg, "--require-covered")) {
            options.require_covered = true;
        } else {
            return error.InvalidArgs;
        }
        index += 1;
    }
    return options;
}

pub fn checkFile(allocator: std.mem.Allocator, options: Options) !Report {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, options.map_path, 1024 * 1024);
    defer allocator.free(bytes);
    return validateMapJson(allocator, bytes, options);
}

pub fn validateMapJson(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
    options: Options,
) !Report {
    var parsed = try parseJsonValue(allocator, json_bytes);
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedJson,
    };

    try requireFields(object, required_top_level_fields[0..]);
    try rejectUnexpectedFields(object, required_top_level_fields[0..]);

    const actual_schema_version = try getStringField(object, "schemaVersion");
    if (!std.mem.eql(u8, actual_schema_version, schema_version)) {
        return error.InvalidSchemaVersion;
    }

    const updated = try getStringField(object, "updated");
    if (!isIsoDate(updated)) return error.InvalidDate;
    _ = try requireNonEmptyStringField(object, "prdSource");

    const records_value = object.get("records") orelse return error.MissingField;
    const records = switch (records_value) {
        .array => |records| records,
        else => return error.ValueMismatch,
    };
    if (records.items.len == 0) return error.MissingField;

    var report = Report{ .total_records = records.items.len };
    var category_seen = [_]bool{false} ** categories.len;
    var release_asset_seen = [_]bool{false} ** release_asset_surface_ids.len;

    for (records.items, 0..) |record_value, index| {
        const record = switch (record_value) {
            .object => |record| record,
            else => return error.ValueMismatch,
        };

        try validateRecord(allocator, record, &report, &category_seen, &release_asset_seen);

        const surface_id = try getStringField(record, "surfaceId");
        var prior_index: usize = 0;
        while (prior_index < index) : (prior_index += 1) {
            const prior_record = records.items[prior_index].object;
            const prior_surface_id = try getStringField(prior_record, "surfaceId");
            if (std.mem.eql(u8, surface_id, prior_surface_id)) {
                return error.DuplicateSurface;
            }
        }
    }

    for (category_seen) |seen| {
        if (!seen) return error.MissingRequiredCategory;
    }
    for (release_asset_seen) |seen| {
        if (!seen) return error.MissingRequiredReleaseAssetMapping;
    }

    if (options.require_covered and (report.gap_records != 0 or report.blocked_records != 0)) {
        return error.ExplicitGapRemaining;
    }

    return report;
}

fn validateRecord(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    report: *Report,
    category_seen: *[categories.len]bool,
    release_asset_seen: *[release_asset_surface_ids.len]bool,
) !void {
    try requireFields(object, required_record_fields[0..]);
    try rejectUnexpectedFields(object, allowed_record_fields[0..]);

    const surface_id = try requireNonEmptyStringField(object, "surfaceId");
    if (!isSurfaceId(surface_id)) return error.InvalidSurfaceId;
    _ = try requireNonEmptyStringField(object, "surfaceSection");

    const surface_category = try requireNonEmptyStringField(object, "surfaceCategory");
    const category_index = indexOf(categories[0..], surface_category) orelse return error.InvalidCategory;
    category_seen[category_index] = true;

    const assertion_type = try requireNonEmptyStringField(object, "assertionType");
    if (indexOf(assertion_types[0..], assertion_type) == null) return error.InvalidAssertionType;

    const assertion_identifier = try requireNonEmptyStringField(object, "assertionIdentifier");
    _ = try requireNonEmptyStringField(object, "expectedContractOutcome");

    const coverage_status = try requireNonEmptyStringField(object, "coverageStatus");
    if (indexOf(coverage_statuses[0..], coverage_status) == null) return error.InvalidCoverageStatus;

    if (std.mem.eql(u8, coverage_status, "covered")) {
        if (std.mem.startsWith(u8, assertion_identifier, legacy_gap_prefix)) return error.InvalidCoverageStatus;
        try validateCoveredAssertionEvidence(allocator, assertion_identifier);
        report.covered_records += 1;
    } else {
        _ = requireNonEmptyStringField(object, "gapReason") catch return error.MissingGapReason;
        _ = requireNonEmptyStringField(object, "ownerTicket") catch return error.MissingOwnerTicket;
        if (std.mem.eql(u8, coverage_status, "gap")) {
            report.gap_records += 1;
        } else {
            report.blocked_records += 1;
        }
    }

    if (std.mem.eql(u8, surface_category, "release-asset")) {
        for (release_asset_surface_ids, 0..) |required_surface_id, index| {
            if (std.mem.eql(u8, surface_id, required_surface_id)) {
                release_asset_seen[index] = true;
            }
        }
    }
}

fn validateCoveredAssertionEvidence(
    allocator: std.mem.Allocator,
    assertion_identifier: []const u8,
) !void {
    var current_file: ?[]const u8 = null;
    var saw_evidence = false;
    var parts = std.mem.splitScalar(u8, assertion_identifier, ';');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len == 0) return error.InvalidAssertionEvidence;

        if (isAllowedGateCommand(part)) {
            current_file = null;
            saw_evidence = true;
            continue;
        }
        if (std.mem.startsWith(u8, part, "zig build")) return error.UnsupportedAssertionCommand;

        if (std.mem.indexOfScalar(u8, part, ':')) |colon_index| {
            const file_path = std.mem.trim(u8, part[0..colon_index], " \t\r\n");
            const test_name = std.mem.trim(u8, part[colon_index + 1 ..], " \t\r\n");
            if (file_path.len == 0 or test_name.len == 0) return error.InvalidAssertionEvidence;
            try validateFileReference(file_path);
            try validateZigTestName(allocator, file_path, test_name);
            current_file = file_path;
            saw_evidence = true;
            continue;
        }

        if (isRepoRelativePath(part)) {
            try validateFileReference(part);
            current_file = part;
            saw_evidence = true;
            continue;
        }

        const file_path = current_file orelse return error.InvalidAssertionEvidence;
        try validateZigTestName(allocator, file_path, part);
        saw_evidence = true;
    }

    if (!saw_evidence) return error.InvalidAssertionEvidence;
}

fn isAllowedGateCommand(command: []const u8) bool {
    for (allowed_gate_commands) |allowed| {
        if (std.mem.eql(u8, command, allowed)) return true;
    }
    return false;
}

fn validateFileReference(file_path: []const u8) QualificationError!void {
    if (!isRepoRelativePath(file_path)) return error.InvalidAssertionEvidence;
    std.fs.cwd().access(file_path, .{}) catch return error.MissingAssertionFile;
}

fn validateZigTestName(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    test_name: []const u8,
) !void {
    if (!std.mem.endsWith(u8, file_path, ".zig")) return error.InvalidAssertionEvidence;

    const bytes = std.fs.cwd().readFileAlloc(allocator, file_path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MissingAssertionFile,
    };
    defer allocator.free(bytes);

    const test_pattern = try std.fmt.allocPrint(allocator, "test \"{s}\"", .{test_name});
    defer allocator.free(test_pattern);

    if (std.mem.indexOf(u8, bytes, test_pattern) == null) return error.MissingAssertionTest;
}

fn isRepoRelativePath(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.fs.path.isAbsolute(value)) return false;
    if (std.mem.indexOf(u8, value, "\\") != null) return false;
    if (std.mem.indexOf(u8, value, "..") != null) return false;
    if (std.mem.startsWith(u8, value, "zig build")) return false;
    return std.mem.indexOfScalar(u8, value, '/') != null or
        std.mem.endsWith(u8, value, ".zig") or
        std.mem.endsWith(u8, value, ".json") or
        std.mem.endsWith(u8, value, ".md") or
        std.mem.endsWith(u8, value, ".mdx");
}

fn parseJsonValue(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) !std.json.Parsed(std.json.Value) {
    if (!std.unicode.utf8ValidateSlice(json_bytes)) return error.MalformedUtf8;
    return std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedJson,
    };
}

fn requireFields(object: std.json.ObjectMap, fields: []const []const u8) QualificationError!void {
    for (fields) |field_name| {
        if (object.get(field_name) == null) return error.MissingField;
    }
}

fn rejectUnexpectedFields(object: std.json.ObjectMap, allowed_fields: []const []const u8) QualificationError!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (indexOf(allowed_fields, entry.key_ptr.*) == null) {
            return error.UnexpectedField;
        }
    }
}

fn requireNonEmptyStringField(object: std.json.ObjectMap, field_name: []const u8) QualificationError![]const u8 {
    const value = try getStringField(object, field_name);
    if (value.len == 0) return error.EmptyString;
    return value;
}

fn getStringField(object: std.json.ObjectMap, field_name: []const u8) QualificationError![]const u8 {
    const value = object.get(field_name) orelse return error.MissingField;
    return switch (value) {
        .string => |text| text,
        else => error.ValueMismatch,
    };
}

fn indexOf(haystack: []const []const u8, needle: []const u8) ?usize {
    for (haystack, 0..) |item, index| {
        if (std.mem.eql(u8, item, needle)) return index;
    }
    return null;
}

fn isIsoDate(value: []const u8) bool {
    if (value.len != "0000-00-00".len) return false;
    for (value, 0..) |char, index| {
        if (index == 4 or index == 7) {
            if (char != '-') return false;
        } else if (!std.ascii.isDigit(char)) {
            return false;
        }
    }
    return true;
}

fn isSurfaceId(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |char| {
        if (!(char >= 'A' and char <= 'Z') and !(char >= '0' and char <= '9') and char != '_') {
            return false;
        }
    }
    return true;
}

const valid_map_json =
    "{" ++ "\"schemaVersion\":\"zevm-release-qualification-map.v1\"," ++ "\"updated\":\"2026-04-30\"," ++ "\"prdSource\":\"docs/specs/prd.md#35-release-qualification-and-verification-acceptance-criteria\"," ++ "\"records\":[" ++ "{\"surfaceId\":\"STARTUP_SURFACE\",\"surfaceSection\":\"PRD 5\",\"surfaceCategory\":\"startup\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"src/config_test.zig\",\"expectedContractOutcome\":\"startup behavior is asserted\",\"coverageStatus\":\"covered\"}," ++ "{\"surfaceId\":\"CONFIGURATION_SURFACE\",\"surfaceSection\":\"PRD 5\",\"surfaceCategory\":\"configuration\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"src/config_test.zig\",\"expectedContractOutcome\":\"configuration behavior is asserted\",\"coverageStatus\":\"covered\"}," ++ "{\"surfaceId\":\"RUNTIME_SURFACE\",\"surfaceSection\":\"PRD 4\",\"surfaceCategory\":\"runtime\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"src/node/runtime_test.zig\",\"expectedContractOutcome\":\"runtime behavior is asserted\",\"coverageStatus\":\"covered\"}," ++ "{\"surfaceId\":\"TRANSPORT_SURFACE\",\"surfaceSection\":\"PRD 6\",\"surfaceCategory\":\"transport\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"src/rpc/server_test.zig\",\"expectedContractOutcome\":\"transport behavior is asserted\",\"coverageStatus\":\"covered\"}," ++ "{\"surfaceId\":\"METHOD_SURFACE\",\"surfaceSection\":\"PRD 7\",\"surfaceCategory\":\"method\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"src/rpc/dispatcher_test.zig\",\"expectedContractOutcome\":\"method behavior is asserted\",\"coverageStatus\":\"covered\"}," ++ "{\"surfaceId\":\"RELEASE_METADATA_RELEASE_TUPLE_JSON\",\"surfaceSection\":\"PRD 3.4\",\"surfaceCategory\":\"release-asset\",\"assertionType\":\"release-asset-validation\",\"assertionIdentifier\":\"src/release_metadata.zig\",\"expectedContractOutcome\":\"release tuple is validated\",\"coverageStatus\":\"covered\"}," ++ "{\"surfaceId\":\"RELEASE_METADATA_LIGHT_DEFAULT_CHECKPOINTS_JSON\",\"surfaceSection\":\"PRD 3.4\",\"surfaceCategory\":\"release-asset\",\"assertionType\":\"release-asset-validation\",\"assertionIdentifier\":\"src/release_metadata.zig\",\"expectedContractOutcome\":\"light defaults are validated\",\"coverageStatus\":\"covered\"}" ++ "]" ++ "}";

test "qualification map validator accepts complete structural map" {
    const report = try validateMapJson(std.testing.allocator, valid_map_json, .{});
    try std.testing.expectEqual(@as(usize, 7), report.total_records);
    try std.testing.expectEqual(@as(usize, 7), report.covered_records);
    try std.testing.expectEqual(@as(usize, 0), report.gap_records);
}

test "qualification map validator rejects missing required record field" {
    const json =
        "{" ++ "\"schemaVersion\":\"zevm-release-qualification-map.v1\"," ++ "\"updated\":\"2026-04-30\"," ++ "\"prdSource\":\"docs/specs/prd.md#35-release-qualification-and-verification-acceptance-criteria\"," ++ "\"records\":[{\"surfaceId\":\"BROKEN\"}]" ++ "}";

    try std.testing.expectError(
        error.MissingField,
        validateMapJson(std.testing.allocator, json, .{}),
    );
}

test "qualification map validator rejects malformed category" {
    const json =
        "{" ++ "\"schemaVersion\":\"zevm-release-qualification-map.v1\"," ++ "\"updated\":\"2026-04-30\"," ++ "\"prdSource\":\"docs/specs/prd.md#35-release-qualification-and-verification-acceptance-criteria\"," ++ "\"records\":[" ++ "{\"surfaceId\":\"BAD_CATEGORY\",\"surfaceSection\":\"PRD 5\",\"surfaceCategory\":\"build\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"src/config_test.zig\",\"expectedContractOutcome\":\"bad category\",\"coverageStatus\":\"covered\"}" ++ "]" ++ "}";

    try std.testing.expectError(
        error.InvalidCategory,
        validateMapJson(std.testing.allocator, json, .{}),
    );
}

test "qualification map validator requires gap metadata" {
    const json =
        "{" ++ "\"schemaVersion\":\"zevm-release-qualification-map.v1\"," ++ "\"updated\":\"2026-04-30\"," ++ "\"prdSource\":\"docs/specs/prd.md#35-release-qualification-and-verification-acceptance-criteria\"," ++ "\"records\":[" ++ "{\"surfaceId\":\"GAP_SURFACE\",\"surfaceSection\":\"PRD 6\",\"surfaceCategory\":\"transport\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"" ++ legacy_gap_prefix ++ "listener smoke\",\"expectedContractOutcome\":\"socket smoke exists\",\"coverageStatus\":\"gap\"}" ++ "]" ++ "}";

    try std.testing.expectError(
        error.MissingGapReason,
        validateMapJson(std.testing.allocator, json, .{}),
    );
}

test "qualification map validator can fail on explicit gaps" {
    const json =
        "{" ++ "\"schemaVersion\":\"zevm-release-qualification-map.v1\"," ++ "\"updated\":\"2026-04-30\"," ++ "\"prdSource\":\"docs/specs/prd.md#35-release-qualification-and-verification-acceptance-criteria\"," ++ "\"records\":[" ++ "{\"surfaceId\":\"STARTUP_SURFACE\",\"surfaceSection\":\"PRD 5\",\"surfaceCategory\":\"startup\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"src/config_test.zig\",\"expectedContractOutcome\":\"startup behavior is asserted\",\"coverageStatus\":\"covered\"}," ++ "{\"surfaceId\":\"CONFIGURATION_SURFACE\",\"surfaceSection\":\"PRD 5\",\"surfaceCategory\":\"configuration\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"src/config_test.zig\",\"expectedContractOutcome\":\"configuration behavior is asserted\",\"coverageStatus\":\"covered\"}," ++ "{\"surfaceId\":\"RUNTIME_SURFACE\",\"surfaceSection\":\"PRD 4\",\"surfaceCategory\":\"runtime\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"src/node/runtime_test.zig\",\"expectedContractOutcome\":\"runtime behavior is asserted\",\"coverageStatus\":\"covered\"}," ++ "{\"surfaceId\":\"TRANSPORT_SURFACE\",\"surfaceSection\":\"PRD 6\",\"surfaceCategory\":\"transport\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"" ++ legacy_gap_prefix ++ "listener smoke\",\"expectedContractOutcome\":\"transport behavior is asserted\",\"coverageStatus\":\"gap\",\"gapReason\":\"listener smoke missing\",\"ownerTicket\":\"ticket.md\"}," ++ "{\"surfaceId\":\"METHOD_SURFACE\",\"surfaceSection\":\"PRD 7\",\"surfaceCategory\":\"method\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"src/rpc/dispatcher_test.zig\",\"expectedContractOutcome\":\"method behavior is asserted\",\"coverageStatus\":\"covered\"}," ++ "{\"surfaceId\":\"RELEASE_METADATA_RELEASE_TUPLE_JSON\",\"surfaceSection\":\"PRD 3.4\",\"surfaceCategory\":\"release-asset\",\"assertionType\":\"release-asset-validation\",\"assertionIdentifier\":\"src/release_metadata.zig\",\"expectedContractOutcome\":\"release tuple is validated\",\"coverageStatus\":\"covered\"}," ++ "{\"surfaceId\":\"RELEASE_METADATA_LIGHT_DEFAULT_CHECKPOINTS_JSON\",\"surfaceSection\":\"PRD 3.4\",\"surfaceCategory\":\"release-asset\",\"assertionType\":\"release-asset-validation\",\"assertionIdentifier\":\"src/release_metadata.zig\",\"expectedContractOutcome\":\"light defaults are validated\",\"coverageStatus\":\"covered\"}" ++ "]" ++ "}";

    try std.testing.expectError(
        error.ExplicitGapRemaining,
        validateMapJson(std.testing.allocator, json, .{ .require_covered = true }),
    );
}

test "qualification map validator rejects covered row with missing evidence file" {
    const json =
        "{" ++ "\"schemaVersion\":\"zevm-release-qualification-map.v1\"," ++ "\"updated\":\"2026-04-30\"," ++ "\"prdSource\":\"docs/specs/prd.md#35-release-qualification-and-verification-acceptance-criteria\"," ++ "\"records\":[" ++ "{\"surfaceId\":\"MISSING_EVIDENCE\",\"surfaceSection\":\"PRD 5\",\"surfaceCategory\":\"startup\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"src/not_a_real_test_file.zig\",\"expectedContractOutcome\":\"missing evidence fails\",\"coverageStatus\":\"covered\"}" ++ "]" ++ "}";

    try std.testing.expectError(
        error.MissingAssertionFile,
        validateMapJson(std.testing.allocator, json, .{}),
    );
}

test "qualification map validator rejects covered row with missing named test" {
    const json =
        "{" ++ "\"schemaVersion\":\"zevm-release-qualification-map.v1\"," ++ "\"updated\":\"2026-04-30\"," ++ "\"prdSource\":\"docs/specs/prd.md#35-release-qualification-and-verification-acceptance-criteria\"," ++ "\"records\":[" ++ "{\"surfaceId\":\"MISSING_NAMED_TEST\",\"surfaceSection\":\"PRD 5\",\"surfaceCategory\":\"startup\",\"assertionType\":\"default-graph-test\",\"assertionIdentifier\":\"src/config_test.zig:this test is intentionally absent\",\"expectedContractOutcome\":\"missing named tests fail\",\"coverageStatus\":\"covered\"}" ++ "]" ++ "}";

    try std.testing.expectError(
        error.MissingAssertionTest,
        validateMapJson(std.testing.allocator, json, .{}),
    );
}

test "qualification map validator rejects covered row with unsupported gate command" {
    const json =
        "{" ++ "\"schemaVersion\":\"zevm-release-qualification-map.v1\"," ++ "\"updated\":\"2026-04-30\"," ++ "\"prdSource\":\"docs/specs/prd.md#35-release-qualification-and-verification-acceptance-criteria\"," ++ "\"records\":[" ++ "{\"surfaceId\":\"BAD_COMMAND\",\"surfaceSection\":\"PRD 3.5\",\"surfaceCategory\":\"release-asset\",\"assertionType\":\"release-asset-validation\",\"assertionIdentifier\":\"zig build pretend\",\"expectedContractOutcome\":\"unsupported commands fail\",\"coverageStatus\":\"covered\"}" ++ "]" ++ "}";

    try std.testing.expectError(
        error.UnsupportedAssertionCommand,
        validateMapJson(std.testing.allocator, json, .{}),
    );
}
