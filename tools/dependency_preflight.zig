const std = @import("std");
const builtin = @import("builtin");

const Dependency = struct {
    name: []const u8,
    repo: []const u8,
    local_path: []const u8,
    expected_revision: ?[]const u8 = null,
};

const Options = struct {
    manifest_path: []const u8 = "build.zig.zon",
    voltaire_revision: ?[]const u8 = null,
    guillotine_mini_revision: ?[]const u8 = null,
    zig_version: ?[]const u8 = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = try parseArgs(args[1..]);
    try run(allocator, options);
}

fn run(allocator: std.mem.Allocator, options: Options) !void {
    if (options.zig_version) |expected| {
        if (!std.mem.eql(u8, expected, builtin.zig_version_string)) {
            std.debug.print(
                "dependency-preflight: zig version mismatch expected={s} actual={s}\n",
                .{ expected, builtin.zig_version_string },
            );
            return error.ZigVersionMismatch;
        }
    }

    const manifest = try std.fs.cwd().readFileAlloc(allocator, options.manifest_path, 1024 * 1024);
    defer allocator.free(manifest);

    const dependencies = [_]Dependency{
        .{
            .name = "voltaire",
            .repo = "voltaire",
            .local_path = "../voltaire",
            .expected_revision = options.voltaire_revision,
        },
        .{
            .name = "guillotine-mini",
            .repo = "guillotine-mini",
            .local_path = "../guillotine-mini",
            .expected_revision = options.guillotine_mini_revision,
        },
    };

    for (dependencies) |dependency| {
        try checkDependency(allocator, manifest, dependency);
    }

    std.debug.print("dependency-preflight: ok zig={s} manifest={s}\n", .{
        builtin.zig_version_string,
        options.manifest_path,
    });
}

fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) return error.MissingArgumentValue;
            options.manifest_path = args[index];
        } else if (std.mem.eql(u8, arg, "--voltaire-revision")) {
            index += 1;
            if (index >= args.len) return error.MissingArgumentValue;
            options.voltaire_revision = args[index];
        } else if (std.mem.eql(u8, arg, "--guillotine-mini-revision")) {
            index += 1;
            if (index >= args.len) return error.MissingArgumentValue;
            options.guillotine_mini_revision = args[index];
        } else if (std.mem.eql(u8, arg, "--zig-version")) {
            index += 1;
            if (index >= args.len) return error.MissingArgumentValue;
            options.zig_version = args[index];
        } else if (std.mem.eql(u8, arg, "--voltaire-path") or
            std.mem.eql(u8, arg, "--guillotine-mini-path"))
        {
            index += 1;
            if (index >= args.len) return error.MissingArgumentValue;
        } else if (std.mem.eql(u8, arg, "--allow-dirty")) {
            // Accepted for compatibility with older release scripts. Sibling
            // source edits are intentional in the local development flow.
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}

fn checkDependency(
    allocator: std.mem.Allocator,
    manifest: []const u8,
    dependency: Dependency,
) !void {
    if (containsLocalPathDependency(manifest, dependency.local_path)) {
        const build_path = try std.fs.path.join(allocator, &.{ dependency.local_path, "build.zig" });
        defer allocator.free(build_path);
        try std.fs.cwd().access(build_path, .{});
        if (dependency.expected_revision) |expected| {
            const child = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "-C", dependency.local_path, "rev-parse", "HEAD" } });
            defer allocator.free(child.stdout);
            defer allocator.free(child.stderr);
            if (child.term != .Exited or child.term.Exited != 0 or !std.mem.eql(u8, std.mem.trim(u8, child.stdout, "\r\n"), expected)) return error.DependencyRevisionMismatch;
        }
        std.debug.print("dependency-preflight: {s} local={s}\n", .{ dependency.name, dependency.local_path });
        return;
    }

    const revision = try archiveRevision(allocator, manifest, dependency.repo);
    defer allocator.free(revision);
    if (dependency.expected_revision) |expected| {
        if (!std.mem.eql(u8, expected, revision)) {
            std.debug.print(
                "dependency-preflight: {s} revision mismatch expected={s} actual={s}\n",
                .{ dependency.name, expected, revision },
            );
            return error.DependencyRevisionMismatch;
        }
    }

    const hash = try dependencyHash(allocator, manifest, dependency.repo);
    defer allocator.free(hash);

    std.debug.print(
        "dependency-preflight: {s} repo=evmts/{s} revision={s} hash={s}\n",
        .{ dependency.name, dependency.repo, revision, hash },
    );
}

fn containsLocalPathDependency(manifest: []const u8, local_path: []const u8) bool {
    return std.mem.indexOf(u8, manifest, local_path) != null;
}

fn archiveRevision(
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

fn dependencyHash(
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

    const url_start = std.mem.indexOf(u8, manifest, prefix) orelse return error.MissingDependency;
    const after_url = manifest[url_start..];
    const hash_key = ".hash = \"";
    const hash_start_rel = std.mem.indexOf(u8, after_url, hash_key) orelse return error.MissingDependencyHash;
    const hash_start = url_start + hash_start_rel + hash_key.len;
    const after_hash = manifest[hash_start..];
    const hash_end_rel = std.mem.indexOfScalar(u8, after_hash, '"') orelse return error.MalformedDependencyHash;
    const hash = after_hash[0..hash_end_rel];
    if (hash.len == 0 or std.mem.indexOfAny(u8, hash, " \t\r\n") != null) {
        return error.MalformedDependencyHash;
    }
    return try allocator.dupe(u8, hash);
}

fn isGitRevision(text: []const u8) bool {
    if (text.len != 40) return false;
    for (text) |byte| {
        const hex =
            (byte >= '0' and byte <= '9') or
            (byte >= 'a' and byte <= 'f');
        if (!hex) return false;
    }
    return true;
}

test "parseArgs captures expected revisions and zig version" {
    const options = try parseArgs(&.{
        "--manifest",
        "example.zon",
        "--voltaire-revision",
        "1111111111111111111111111111111111111111",
        "--guillotine-mini-revision",
        "2222222222222222222222222222222222222222",
        "--zig-version",
        "0.15.2",
        "--allow-dirty",
    });

    try std.testing.expectEqualStrings("example.zon", options.manifest_path);
    try std.testing.expectEqualStrings("1111111111111111111111111111111111111111", options.voltaire_revision.?);
    try std.testing.expectEqualStrings("2222222222222222222222222222222222222222", options.guillotine_mini_revision.?);
    try std.testing.expectEqualStrings("0.15.2", options.zig_version.?);
}

test "manifest scanners distinguish local paths and archive pins" {
    const manifest =
        \\.{
        \\  .dependencies = .{
        \\    .voltaire = .{
        \\      .url = "https://github.com/evmts/voltaire/archive/1111111111111111111111111111111111111111.tar.gz",
        \\      .hash = "primitives-0.1.0-example",
        \\    },
        \\  },
        \\}
    ;

    try std.testing.expect(!containsLocalPathDependency(manifest, "../voltaire"));

    const revision = try archiveRevision(std.testing.allocator, manifest, "voltaire");
    defer std.testing.allocator.free(revision);
    try std.testing.expectEqualStrings("1111111111111111111111111111111111111111", revision);

    const hash = try dependencyHash(std.testing.allocator, manifest, "voltaire");
    defer std.testing.allocator.free(hash);
    try std.testing.expectEqualStrings("primitives-0.1.0-example", hash);
}

test "isGitRevision validates lowercase full object ids" {
    try std.testing.expect(isGitRevision("1111111111111111111111111111111111111111"));
    try std.testing.expect(!isGitRevision("111111111111111111111111111111111111111"));
    try std.testing.expect(!isGitRevision("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
    try std.testing.expect(!isGitRevision("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
}

test "local dependencies use the maintained sibling checkouts" {
    try std.testing.expect(containsLocalPathDependency(".path = \"../voltaire\"", "../voltaire"));
    try checkDependency(std.testing.allocator, ".path = \"../voltaire\"", .{ .name = "voltaire", .repo = "voltaire", .local_path = "../voltaire" });
}
