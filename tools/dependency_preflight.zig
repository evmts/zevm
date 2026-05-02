const std = @import("std");
const builtin = @import("builtin");

const Dependency = struct {
    name: []const u8,
    path: []const u8,
    expected_revision: ?[]const u8 = null,
};

const Options = struct {
    voltaire_path: []const u8 = "../voltaire",
    guillotine_mini_path: []const u8 = "../guillotine-mini",
    voltaire_revision: ?[]const u8 = null,
    guillotine_mini_revision: ?[]const u8 = null,
    zig_version: ?[]const u8 = null,
    allow_dirty: bool = false,
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

    const dependencies = [_]Dependency{
        .{
            .name = "voltaire",
            .path = options.voltaire_path,
            .expected_revision = options.voltaire_revision,
        },
        .{
            .name = "guillotine-mini",
            .path = options.guillotine_mini_path,
            .expected_revision = options.guillotine_mini_revision,
        },
    };

    for (dependencies) |dependency| {
        try checkDependency(allocator, dependency, options.allow_dirty);
    }

    std.debug.print("dependency-preflight: ok zig={s}\n", .{builtin.zig_version_string});
}

fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--voltaire-path")) {
            index += 1;
            if (index >= args.len) return error.MissingArgumentValue;
            options.voltaire_path = args[index];
        } else if (std.mem.eql(u8, arg, "--guillotine-mini-path")) {
            index += 1;
            if (index >= args.len) return error.MissingArgumentValue;
            options.guillotine_mini_path = args[index];
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
        } else if (std.mem.eql(u8, arg, "--allow-dirty")) {
            options.allow_dirty = true;
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}

fn checkDependency(allocator: std.mem.Allocator, dependency: Dependency, allow_dirty: bool) !void {
    const inside = try gitOutput(allocator, dependency.path, &.{ "rev-parse", "--is-inside-work-tree" });
    defer allocator.free(inside);
    if (!std.mem.eql(u8, inside, "true")) {
        std.debug.print(
            "dependency-preflight: {s} path is not a git worktree path={s}\n",
            .{ dependency.name, dependency.path },
        );
        return error.NotGitWorktree;
    }

    const revision = try gitOutput(allocator, dependency.path, &.{ "rev-parse", "HEAD" });
    defer allocator.free(revision);
    if (!isGitRevision(revision)) {
        std.debug.print(
            "dependency-preflight: {s} returned malformed revision revision={s}\n",
            .{ dependency.name, revision },
        );
        return error.MalformedGitRevision;
    }

    if (dependency.expected_revision) |expected| {
        if (!std.mem.eql(u8, expected, revision)) {
            std.debug.print(
                "dependency-preflight: {s} revision mismatch expected={s} actual={s}\n",
                .{ dependency.name, expected, revision },
            );
            return error.DependencyRevisionMismatch;
        }
    }

    if (!allow_dirty) {
        const status = try gitOutput(allocator, dependency.path, &.{ "status", "--porcelain", "--untracked-files=all" });
        defer allocator.free(status);
        if (status.len != 0) {
            std.debug.print(
                "dependency-preflight: {s} worktree is dirty path={s}\n{s}\n",
                .{ dependency.name, dependency.path, status },
            );
            return error.DependencyDirty;
        }
    }

    std.debug.print(
        "dependency-preflight: {s} path={s} revision={s}\n",
        .{ dependency.name, dependency.path, revision },
    );
}

fn gitOutput(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    args: []const []const u8,
) ![]u8 {
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, args.len + 1);
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd = cwd,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("dependency-preflight: git command failed cwd={s} code={}\n", .{ cwd, code });
                return error.GitCommandFailed;
            }
        },
        else => {
            return error.GitCommandFailed;
        },
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

fn isGitRevision(text: []const u8) bool {
    if (text.len != 40) return false;
    for (text) |byte| {
        const hex =
            (byte >= '0' and byte <= '9') or
            (byte >= 'a' and byte <= 'f') or
            (byte >= 'A' and byte <= 'F');
        if (!hex) return false;
    }
    return true;
}

test "parseArgs captures expected revisions and zig version" {
    const options = try parseArgs(&.{
        "--voltaire-path",
        "deps/voltaire",
        "--guillotine-mini-path",
        "deps/guillotine-mini",
        "--voltaire-revision",
        "1111111111111111111111111111111111111111",
        "--guillotine-mini-revision",
        "2222222222222222222222222222222222222222",
        "--zig-version",
        "0.15.2",
        "--allow-dirty",
    });

    try std.testing.expectEqualStrings("deps/voltaire", options.voltaire_path);
    try std.testing.expectEqualStrings("deps/guillotine-mini", options.guillotine_mini_path);
    try std.testing.expectEqualStrings("1111111111111111111111111111111111111111", options.voltaire_revision.?);
    try std.testing.expectEqualStrings("2222222222222222222222222222222222222222", options.guillotine_mini_revision.?);
    try std.testing.expectEqualStrings("0.15.2", options.zig_version.?);
    try std.testing.expect(options.allow_dirty);
}

test "isGitRevision validates full hex object ids" {
    try std.testing.expect(isGitRevision("1111111111111111111111111111111111111111"));
    try std.testing.expect(!isGitRevision("111111111111111111111111111111111111111"));
    try std.testing.expect(!isGitRevision("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
}
