const std = @import("std");
const builtin = @import("builtin");
const light_default_checkpoints = @import("light_default_checkpoints.zig");

pub const release_tuple_schema_version = "zevm-release-tuple.v1";
pub const light_default_checkpoints_schema_version = "zevm-light-default-checkpoints.v1";

pub const release_tuple_filename = "release-tuple.json";
pub const light_default_checkpoints_filename = "light-default-checkpoints.json";

pub const default_checkpoints = CheckpointDefaults{
    .mainnet = light_default_checkpoints.mainnet_prefixed,
    .sepolia = light_default_checkpoints.sepolia_prefixed,
    .holesky = light_default_checkpoints.holesky_prefixed,
};

pub const ReleaseTuple = struct {
    releaseIdentifier: []const u8,
    zevmGitRevision: []const u8,
    voltaireGitRevision: []const u8,
    guillotineMiniGitRevision: []const u8,
    zigVersion: []const u8,
};

pub const CheckpointDefaults = struct {
    mainnet: []const u8,
    sepolia: []const u8,
    holesky: []const u8,
};

pub const LightDefaultCheckpoints = struct {
    releaseIdentifier: []const u8,
    defaults: CheckpointDefaults,
};

pub const CliOptions = struct {
    out_dir: []const u8 = "zig-out/release",
    release_identifier: ?[]const u8 = null,
};

pub const ReleaseMetadataError = error{
    CommandFailed,
    DuplicateAsset,
    DuplicateField,
    InvalidArgs,
    MalformedCheckpointHash,
    MalformedGitRevision,
    MalformedDependencyUrl,
    MalformedJson,
    MalformedReleaseIdentifier,
    MalformedUtf8,
    MalformedZigVersion,
    MissingAsset,
    MissingDependency,
    MissingField,
    ReleaseIdentifierMismatch,
    SchemaVersionMismatch,
    UnexpectedField,
    ValueMismatch,
};

pub fn main() !void {
    runMain() catch |err| {
        if (err == error.InvalidArgs) {
            std.debug.print(
                "usage: release-metadata [--out-dir PATH] [--release-identifier IDENTIFIER]\n",
                .{},
            );
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
    try generateReleaseMetadataFiles(allocator, options);
}

pub fn parseArgs(args: []const [:0]u8) ReleaseMetadataError!CliOptions {
    var options = CliOptions{};
    var index: usize = 1;
    while (index < args.len) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "--out-dir")) {
            index += 1;
            if (index >= args.len) return error.InvalidArgs;
            options.out_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--release-identifier")) {
            index += 1;
            if (index >= args.len) return error.InvalidArgs;
            options.release_identifier = args[index];
        } else {
            return error.InvalidArgs;
        }
        index += 1;
    }
    return options;
}

pub fn generateReleaseMetadataFiles(
    allocator: std.mem.Allocator,
    options: CliOptions,
) !void {
    const zevm_revision = try captureGitRevision(allocator, ".");
    defer allocator.free(zevm_revision);

    const manifest = try std.fs.cwd().readFileAlloc(allocator, "build.zig.zon", 1024 * 1024);
    defer allocator.free(manifest);

    const voltaire_revision = try captureDependencyRevisionFromManifest(allocator, manifest, "voltaire");
    defer allocator.free(voltaire_revision);
    const guillotine_mini_revision = try captureDependencyRevisionFromManifest(allocator, manifest, "guillotine-mini");
    defer allocator.free(guillotine_mini_revision);

    var generated_release_identifier: ?[]u8 = null;
    defer if (generated_release_identifier) |value| allocator.free(value);

    const release_identifier = options.release_identifier orelse blk: {
        generated_release_identifier = try releaseIdentifierFromRevision(allocator, zevm_revision);
        break :blk generated_release_identifier.?;
    };

    const tuple = ReleaseTuple{
        .releaseIdentifier = release_identifier,
        .zevmGitRevision = zevm_revision,
        .voltaireGitRevision = voltaire_revision,
        .guillotineMiniGitRevision = guillotine_mini_revision,
        .zigVersion = builtin.zig_version_string,
    };
    const checkpoints = LightDefaultCheckpoints{
        .releaseIdentifier = release_identifier,
        .defaults = default_checkpoints,
    };

    try validateReleaseTupleValue(tuple);
    try validateLightDefaultCheckpointsValue(checkpoints);

    const tuple_json = try generateReleaseTupleJson(allocator, tuple);
    defer allocator.free(tuple_json);
    const checkpoints_json = try generateLightDefaultCheckpointsJson(allocator, checkpoints);
    defer allocator.free(checkpoints_json);

    try validateReleaseTupleJson(allocator, tuple_json, tuple);
    try validateLightDefaultCheckpointsJson(allocator, checkpoints_json, checkpoints);

    try std.fs.cwd().makePath(options.out_dir);

    const tuple_path = try std.fs.path.join(allocator, &.{ options.out_dir, release_tuple_filename });
    defer allocator.free(tuple_path);
    const checkpoints_path = try std.fs.path.join(allocator, &.{ options.out_dir, light_default_checkpoints_filename });
    defer allocator.free(checkpoints_path);

    try writeFile(tuple_path, tuple_json);
    try writeFile(checkpoints_path, checkpoints_json);
}

fn captureGitRevision(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .cwd = cwd,
        .max_output_bytes = 4096,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }

    const revision = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!isGitRevision(revision)) return error.MalformedGitRevision;
    return try allocator.dupe(u8, revision);
}

fn captureDependencyRevisionFromManifest(
    allocator: std.mem.Allocator,
    manifest: []const u8,
    repo: []const u8,
) ![]u8 {
    const prefix = try std.fmt.allocPrint(
        allocator,
        "https://github.com/evmts/{s}/archive/",
        .{repo},
    );
    defer allocator.free(prefix);

    const start = std.mem.indexOf(u8, manifest, prefix) orelse return error.MissingDependency;
    const rest = manifest[start + prefix.len ..];
    const end = std.mem.indexOf(u8, rest, ".tar.gz") orelse return error.MalformedDependencyUrl;
    const revision = rest[0..end];
    if (!isGitRevision(revision)) return error.MalformedGitRevision;
    return try allocator.dupe(u8, revision);
}

pub fn releaseIdentifierFromRevision(
    allocator: std.mem.Allocator,
    zevm_revision: []const u8,
) ![]u8 {
    if (!isGitRevision(zevm_revision)) return error.MalformedGitRevision;
    return std.fmt.allocPrint(allocator, "commit-{s}", .{zevm_revision});
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

pub fn generateReleaseTupleJson(
    allocator: std.mem.Allocator,
    tuple: ReleaseTuple,
) ![]u8 {
    try validateReleaseTupleValue(tuple);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeReleaseTupleJson(&out.writer, tuple);
    return out.toOwnedSlice();
}

pub fn writeReleaseTupleJson(writer: *std.Io.Writer, tuple: ReleaseTuple) !void {
    try writer.writeAll("{\n");
    try writer.writeAll("  \"schemaVersion\": ");
    try writeJsonString(writer, release_tuple_schema_version);
    try writer.writeAll(",\n  \"releaseIdentifier\": ");
    try writeJsonString(writer, tuple.releaseIdentifier);
    try writer.writeAll(",\n  \"zevmGitRevision\": ");
    try writeJsonString(writer, tuple.zevmGitRevision);
    try writer.writeAll(",\n  \"voltaireGitRevision\": ");
    try writeJsonString(writer, tuple.voltaireGitRevision);
    try writer.writeAll(",\n  \"guillotineMiniGitRevision\": ");
    try writeJsonString(writer, tuple.guillotineMiniGitRevision);
    try writer.writeAll(",\n  \"zigVersion\": ");
    try writeJsonString(writer, tuple.zigVersion);
    try writer.writeAll("\n}\n");
}

pub fn generateLightDefaultCheckpointsJson(
    allocator: std.mem.Allocator,
    checkpoints: LightDefaultCheckpoints,
) ![]u8 {
    try validateLightDefaultCheckpointsValue(checkpoints);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeLightDefaultCheckpointsJson(&out.writer, checkpoints);
    return out.toOwnedSlice();
}

pub fn writeLightDefaultCheckpointsJson(
    writer: *std.Io.Writer,
    checkpoints: LightDefaultCheckpoints,
) !void {
    try writer.writeAll("{\n");
    try writer.writeAll("  \"schemaVersion\": ");
    try writeJsonString(writer, light_default_checkpoints_schema_version);
    try writer.writeAll(",\n  \"releaseIdentifier\": ");
    try writeJsonString(writer, checkpoints.releaseIdentifier);
    try writer.writeAll(",\n  \"defaults\": {\n");
    try writer.writeAll("    \"mainnet\": ");
    try writeJsonString(writer, checkpoints.defaults.mainnet);
    try writer.writeAll(",\n    \"sepolia\": ");
    try writeJsonString(writer, checkpoints.defaults.sepolia);
    try writer.writeAll(",\n    \"holesky\": ");
    try writeJsonString(writer, checkpoints.defaults.holesky);
    try writer.writeAll("\n  }\n}\n");
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(std.json.Value{ .string = value }, .{}, writer);
}

pub fn validateReleaseTupleJson(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
    expected: ReleaseTuple,
) !void {
    try validateReleaseTupleValue(expected);

    var parsed = try parseJsonValue(allocator, json_bytes);
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedJson,
    };

    const fields = [_][]const u8{
        "schemaVersion",
        "releaseIdentifier",
        "zevmGitRevision",
        "voltaireGitRevision",
        "guillotineMiniGitRevision",
        "zigVersion",
    };
    try requireExactFields(object, fields[0..]);

    const schema_version = try getStringField(object, "schemaVersion");
    if (!std.mem.eql(u8, schema_version, release_tuple_schema_version)) {
        return error.SchemaVersionMismatch;
    }

    const release_identifier = try getStringField(object, "releaseIdentifier");
    if (!std.mem.eql(u8, release_identifier, expected.releaseIdentifier)) {
        return error.ReleaseIdentifierMismatch;
    }

    const zevm_revision = try getStringField(object, "zevmGitRevision");
    const voltaire_revision = try getStringField(object, "voltaireGitRevision");
    const guillotine_mini_revision = try getStringField(object, "guillotineMiniGitRevision");
    const zig_version = try getStringField(object, "zigVersion");

    const actual = ReleaseTuple{
        .releaseIdentifier = release_identifier,
        .zevmGitRevision = zevm_revision,
        .voltaireGitRevision = voltaire_revision,
        .guillotineMiniGitRevision = guillotine_mini_revision,
        .zigVersion = zig_version,
    };
    try validateReleaseTupleValue(actual);

    if (!std.mem.eql(u8, zevm_revision, expected.zevmGitRevision) or
        !std.mem.eql(u8, voltaire_revision, expected.voltaireGitRevision) or
        !std.mem.eql(u8, guillotine_mini_revision, expected.guillotineMiniGitRevision) or
        !std.mem.eql(u8, zig_version, expected.zigVersion))
    {
        return error.ValueMismatch;
    }
}

pub fn validateLightDefaultCheckpointsJson(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
    expected: LightDefaultCheckpoints,
) !void {
    try validateLightDefaultCheckpointsValue(expected);

    var parsed = try parseJsonValue(allocator, json_bytes);
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedJson,
    };

    const fields = [_][]const u8{
        "schemaVersion",
        "releaseIdentifier",
        "defaults",
    };
    try requireExactFields(object, fields[0..]);

    const schema_version = try getStringField(object, "schemaVersion");
    if (!std.mem.eql(u8, schema_version, light_default_checkpoints_schema_version)) {
        return error.SchemaVersionMismatch;
    }

    const release_identifier = try getStringField(object, "releaseIdentifier");
    if (!std.mem.eql(u8, release_identifier, expected.releaseIdentifier)) {
        return error.ReleaseIdentifierMismatch;
    }

    const defaults_value = object.get("defaults") orelse return error.MissingField;
    const defaults_object = switch (defaults_value) {
        .object => |defaults_object| defaults_object,
        else => return error.ValueMismatch,
    };

    const default_fields = [_][]const u8{ "mainnet", "sepolia", "holesky" };
    try requireExactFields(defaults_object, default_fields[0..]);

    const defaults = CheckpointDefaults{
        .mainnet = try getStringField(defaults_object, "mainnet"),
        .sepolia = try getStringField(defaults_object, "sepolia"),
        .holesky = try getStringField(defaults_object, "holesky"),
    };
    const actual = LightDefaultCheckpoints{
        .releaseIdentifier = release_identifier,
        .defaults = defaults,
    };
    try validateLightDefaultCheckpointsValue(actual);

    if (!std.mem.eql(u8, defaults.mainnet, expected.defaults.mainnet) or
        !std.mem.eql(u8, defaults.sepolia, expected.defaults.sepolia) or
        !std.mem.eql(u8, defaults.holesky, expected.defaults.holesky))
    {
        return error.ValueMismatch;
    }
}

pub fn validateReleaseAssetNames(asset_names: []const []const u8) ReleaseMetadataError!void {
    var release_tuple_count: usize = 0;
    var light_defaults_count: usize = 0;

    for (asset_names) |asset_name| {
        if (std.mem.eql(u8, asset_name, release_tuple_filename)) {
            release_tuple_count += 1;
        } else if (std.mem.eql(u8, asset_name, light_default_checkpoints_filename)) {
            light_defaults_count += 1;
        }
    }

    if (release_tuple_count == 0 or light_defaults_count == 0) return error.MissingAsset;
    if (release_tuple_count > 1 or light_defaults_count > 1) return error.DuplicateAsset;
}

pub fn validateReleaseTupleValue(tuple: ReleaseTuple) ReleaseMetadataError!void {
    if (!isValidReleaseIdentifier(tuple.releaseIdentifier)) return error.MalformedReleaseIdentifier;
    if (!isGitRevision(tuple.zevmGitRevision)) return error.MalformedGitRevision;
    if (!isGitRevision(tuple.voltaireGitRevision)) return error.MalformedGitRevision;
    if (!isGitRevision(tuple.guillotineMiniGitRevision)) return error.MalformedGitRevision;
    if (tuple.zigVersion.len == 0) return error.MalformedZigVersion;
    if (isCommitReleaseIdentifier(tuple.releaseIdentifier) and
        !std.mem.eql(u8, tuple.releaseIdentifier["commit-".len..], tuple.zevmGitRevision))
    {
        return error.ReleaseIdentifierMismatch;
    }
}

pub fn validateLightDefaultCheckpointsValue(
    checkpoints: LightDefaultCheckpoints,
) ReleaseMetadataError!void {
    if (!isValidReleaseIdentifier(checkpoints.releaseIdentifier)) {
        return error.MalformedReleaseIdentifier;
    }
    if (!isCheckpointHash(checkpoints.defaults.mainnet)) return error.MalformedCheckpointHash;
    if (!isCheckpointHash(checkpoints.defaults.sepolia)) return error.MalformedCheckpointHash;
    if (!isCheckpointHash(checkpoints.defaults.holesky)) return error.MalformedCheckpointHash;
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

fn requireExactFields(
    object: std.json.ObjectMap,
    expected_fields: []const []const u8,
) ReleaseMetadataError!void {
    for (expected_fields) |field_name| {
        if (object.get(field_name) == null) return error.MissingField;
    }

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!containsField(expected_fields, entry.key_ptr.*)) {
            return error.UnexpectedField;
        }
    }
}

fn containsField(expected_fields: []const []const u8, field_name: []const u8) bool {
    for (expected_fields) |expected_field| {
        if (std.mem.eql(u8, expected_field, field_name)) return true;
    }
    return false;
}

fn getStringField(object: std.json.ObjectMap, field_name: []const u8) ReleaseMetadataError![]const u8 {
    const value = object.get(field_name) orelse return error.MissingField;
    return switch (value) {
        .string => |text| text,
        else => error.ValueMismatch,
    };
}

pub fn isValidReleaseIdentifier(value: []const u8) bool {
    return isCommitReleaseIdentifier(value) or isTagReleaseIdentifier(value);
}

pub fn isCommitReleaseIdentifier(value: []const u8) bool {
    if (value.len != "commit-".len + 40) return false;
    if (!std.mem.startsWith(u8, value, "commit-")) return false;
    for (value["commit-".len..]) |char| {
        if (!isLowerHex(char)) return false;
    }
    return true;
}

pub fn isTagReleaseIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    if (isCommitReleaseIdentifier(value)) return false;
    if (!std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '.' or char == '_' or char == '-')) {
            return false;
        }
    }
    return true;
}

pub fn isGitRevision(value: []const u8) bool {
    if (value.len != 40) return false;
    for (value) |char| {
        if (!isLowerHex(char)) return false;
    }
    return true;
}

pub fn isCheckpointHash(value: []const u8) bool {
    if (value.len != 66) return false;
    if (!std.mem.startsWith(u8, value, "0x")) return false;
    for (value[2..]) |char| {
        if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

fn isLowerHex(char: u8) bool {
    return (char >= '0' and char <= '9') or (char >= 'a' and char <= 'f');
}

const test_tuple = ReleaseTuple{
    .releaseIdentifier = "commit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    .zevmGitRevision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    .voltaireGitRevision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    .guillotineMiniGitRevision = "cccccccccccccccccccccccccccccccccccccccc",
    .zigVersion = "0.15.2",
};

const test_checkpoints = LightDefaultCheckpoints{
    .releaseIdentifier = test_tuple.releaseIdentifier,
    .defaults = default_checkpoints,
};

test "release tuple generator emits valid json" {
    const json = try generateReleaseTupleJson(std.testing.allocator, test_tuple);
    defer std.testing.allocator.free(json);

    try validateReleaseTupleJson(std.testing.allocator, json, test_tuple);
}

test "light default checkpoints generator emits valid json" {
    const json = try generateLightDefaultCheckpointsJson(std.testing.allocator, test_checkpoints);
    defer std.testing.allocator.free(json);

    try validateLightDefaultCheckpointsJson(std.testing.allocator, json, test_checkpoints);
}

test "light default checkpoints use shared runtime constants" {
    try std.testing.expectEqualStrings(light_default_checkpoints.mainnet_prefixed, default_checkpoints.mainnet);
    try std.testing.expectEqualStrings(light_default_checkpoints.sepolia_prefixed, default_checkpoints.sepolia);
    try std.testing.expectEqualStrings(light_default_checkpoints.holesky_prefixed, default_checkpoints.holesky);
}

test "release tuple validator catches malformed json utf8 duplicate missing and extra fields" {
    try std.testing.expectError(
        error.MalformedJson,
        validateReleaseTupleJson(std.testing.allocator, "{", test_tuple),
    );
    try std.testing.expectError(
        error.MalformedUtf8,
        validateReleaseTupleJson(std.testing.allocator, "\xff", test_tuple),
    );
    try std.testing.expectError(
        error.DuplicateField,
        validateReleaseTupleJson(
            std.testing.allocator,
            "{\"schemaVersion\":\"zevm-release-tuple.v1\",\"schemaVersion\":\"zevm-release-tuple.v1\"}",
            test_tuple,
        ),
    );
    try std.testing.expectError(
        error.MissingField,
        validateReleaseTupleJson(
            std.testing.allocator,
            "{\"schemaVersion\":\"zevm-release-tuple.v1\"}",
            test_tuple,
        ),
    );
    try std.testing.expectError(
        error.UnexpectedField,
        validateReleaseTupleJson(
            std.testing.allocator,
            "{" ++ "\"schemaVersion\":\"zevm-release-tuple.v1\"," ++ "\"releaseIdentifier\":\"commit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++ "\"zevmGitRevision\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++ "\"voltaireGitRevision\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++ "\"guillotineMiniGitRevision\":\"cccccccccccccccccccccccccccccccccccccccc\"," ++ "\"zigVersion\":\"0.15.2\"," ++ "\"extra\":\"nope\"" ++ "}",
            test_tuple,
        ),
    );
}

test "release tuple validator catches schema identifier and value mismatches" {
    try std.testing.expectError(
        error.SchemaVersionMismatch,
        validateReleaseTupleJson(
            std.testing.allocator,
            "{" ++ "\"schemaVersion\":\"wrong\"," ++ "\"releaseIdentifier\":\"commit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++ "\"zevmGitRevision\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++ "\"voltaireGitRevision\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++ "\"guillotineMiniGitRevision\":\"cccccccccccccccccccccccccccccccccccccccc\"," ++ "\"zigVersion\":\"0.15.2\"" ++ "}",
            test_tuple,
        ),
    );
    try std.testing.expectError(
        error.ReleaseIdentifierMismatch,
        validateReleaseTupleJson(
            std.testing.allocator,
            "{" ++ "\"schemaVersion\":\"zevm-release-tuple.v1\"," ++ "\"releaseIdentifier\":\"v1.0.0\"," ++ "\"zevmGitRevision\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++ "\"voltaireGitRevision\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++ "\"guillotineMiniGitRevision\":\"cccccccccccccccccccccccccccccccccccccccc\"," ++ "\"zigVersion\":\"0.15.2\"" ++ "}",
            test_tuple,
        ),
    );
    try std.testing.expectError(
        error.ValueMismatch,
        validateReleaseTupleJson(
            std.testing.allocator,
            "{" ++ "\"schemaVersion\":\"zevm-release-tuple.v1\"," ++ "\"releaseIdentifier\":\"commit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++ "\"zevmGitRevision\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++ "\"voltaireGitRevision\":\"dddddddddddddddddddddddddddddddddddddddd\"," ++ "\"guillotineMiniGitRevision\":\"cccccccccccccccccccccccccccccccccccccccc\"," ++ "\"zigVersion\":\"0.15.2\"" ++ "}",
            test_tuple,
        ),
    );
}

test "light default checkpoints validator catches malformed defaults" {
    try std.testing.expectError(
        error.MissingField,
        validateLightDefaultCheckpointsJson(
            std.testing.allocator,
            "{" ++ "\"schemaVersion\":\"zevm-light-default-checkpoints.v1\"," ++ "\"releaseIdentifier\":\"commit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++ "\"defaults\":{\"mainnet\":\"0x9b41a80f58c52068a00e8535b8d6704769c7577a5fd506af5e0c018687991d55\"}" ++ "}",
            test_checkpoints,
        ),
    );
    try std.testing.expectError(
        error.DuplicateField,
        validateLightDefaultCheckpointsJson(
            std.testing.allocator,
            "{" ++ "\"schemaVersion\":\"zevm-light-default-checkpoints.v1\"," ++ "\"releaseIdentifier\":\"commit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++ "\"defaults\":{" ++ "\"mainnet\":\"0x9b41a80f58c52068a00e8535b8d6704769c7577a5fd506af5e0c018687991d55\"," ++ "\"mainnet\":\"0x9b41a80f58c52068a00e8535b8d6704769c7577a5fd506af5e0c018687991d55\"," ++ "\"sepolia\":\"0x4065c2509eaa15dbe60e1f80cff5205a532aa95aaa1d73c1c286f7f8535555d4\"," ++ "\"holesky\":\"0xe1f575f0b691404fe82cce68a09c2c98af197816de14ce53c0fe9f9bd02d2399\"" ++ "}}",
            test_checkpoints,
        ),
    );
    try std.testing.expectError(
        error.MalformedCheckpointHash,
        validateLightDefaultCheckpointsJson(
            std.testing.allocator,
            "{" ++ "\"schemaVersion\":\"zevm-light-default-checkpoints.v1\"," ++ "\"releaseIdentifier\":\"commit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++ "\"defaults\":{" ++ "\"mainnet\":\"0x1\"," ++ "\"sepolia\":\"0x4065c2509eaa15dbe60e1f80cff5205a532aa95aaa1d73c1c286f7f8535555d4\"," ++ "\"holesky\":\"0xe1f575f0b691404fe82cce68a09c2c98af197816de14ce53c0fe9f9bd02d2399\"" ++ "}}",
            test_checkpoints,
        ),
    );
}

test "light default checkpoints validator catches schema identifier and value mismatches" {
    try std.testing.expectError(
        error.SchemaVersionMismatch,
        validateLightDefaultCheckpointsJson(
            std.testing.allocator,
            "{" ++ "\"schemaVersion\":\"wrong\"," ++ "\"releaseIdentifier\":\"commit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++ "\"defaults\":{" ++ "\"mainnet\":\"0x9b41a80f58c52068a00e8535b8d6704769c7577a5fd506af5e0c018687991d55\"," ++ "\"sepolia\":\"0x4065c2509eaa15dbe60e1f80cff5205a532aa95aaa1d73c1c286f7f8535555d4\"," ++ "\"holesky\":\"0xe1f575f0b691404fe82cce68a09c2c98af197816de14ce53c0fe9f9bd02d2399\"" ++ "}}",
            test_checkpoints,
        ),
    );
    try std.testing.expectError(
        error.ReleaseIdentifierMismatch,
        validateLightDefaultCheckpointsJson(
            std.testing.allocator,
            "{" ++ "\"schemaVersion\":\"zevm-light-default-checkpoints.v1\"," ++ "\"releaseIdentifier\":\"v1.0.0\"," ++ "\"defaults\":{" ++ "\"mainnet\":\"0x9b41a80f58c52068a00e8535b8d6704769c7577a5fd506af5e0c018687991d55\"," ++ "\"sepolia\":\"0x4065c2509eaa15dbe60e1f80cff5205a532aa95aaa1d73c1c286f7f8535555d4\"," ++ "\"holesky\":\"0xe1f575f0b691404fe82cce68a09c2c98af197816de14ce53c0fe9f9bd02d2399\"" ++ "}}",
            test_checkpoints,
        ),
    );
    try std.testing.expectError(
        error.ValueMismatch,
        validateLightDefaultCheckpointsJson(
            std.testing.allocator,
            "{" ++ "\"schemaVersion\":\"zevm-light-default-checkpoints.v1\"," ++ "\"releaseIdentifier\":\"commit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++ "\"defaults\":{" ++ "\"mainnet\":\"0x4444444444444444444444444444444444444444444444444444444444444444\"," ++ "\"sepolia\":\"0x4065c2509eaa15dbe60e1f80cff5205a532aa95aaa1d73c1c286f7f8535555d4\"," ++ "\"holesky\":\"0xe1f575f0b691404fe82cce68a09c2c98af197816de14ce53c0fe9f9bd02d2399\"" ++ "}}",
            test_checkpoints,
        ),
    );
}

test "asset name validator catches missing and duplicate required assets" {
    try validateReleaseAssetNames(&.{
        release_tuple_filename,
        light_default_checkpoints_filename,
    });
    try std.testing.expectError(
        error.MissingAsset,
        validateReleaseAssetNames(&.{release_tuple_filename}),
    );
    try std.testing.expectError(
        error.DuplicateAsset,
        validateReleaseAssetNames(&.{
            release_tuple_filename,
            release_tuple_filename,
            light_default_checkpoints_filename,
        }),
    );
}

test "release identifier and hash validators enforce formats" {
    try std.testing.expect(isValidReleaseIdentifier("v1.2.3"));
    try std.testing.expect(isValidReleaseIdentifier("commit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expect(!isValidReleaseIdentifier("-bad"));
    try std.testing.expect(!isCommitReleaseIdentifier("commit-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
    try std.testing.expect(isGitRevision("0123456789abcdef0123456789abcdef01234567"));
    try std.testing.expect(!isGitRevision("0123456789ABCDEF0123456789ABCDEF01234567"));
    try std.testing.expect(isCheckpointHash("0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
    try std.testing.expect(!isCheckpointHash("abcdefABCDEF0123456789abcdefABCDEF0123456789abcdefABCDEF0123456789"));
}
