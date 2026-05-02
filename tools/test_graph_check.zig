const std = @import("std");

const root_test_entry = "src/root.zig";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    try check(arena.allocator());
}

pub fn check(allocator: std.mem.Allocator) !void {
    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();

    var queue = std.ArrayList([]const u8).empty;
    defer queue.deinit(allocator);

    const root_path = try allocator.dupe(u8, root_test_entry);
    try reachable.put(root_path, {});
    try queue.append(allocator, root_path);

    var index: usize = 0;
    while (index < queue.items.len) : (index += 1) {
        const file_path = queue.items[index];
        const bytes = try std.fs.cwd().readFileAlloc(allocator, file_path, 4 * 1024 * 1024);
        try collectImports(allocator, file_path, bytes, &reachable, &queue);
    }

    var missing = std.ArrayList([]const u8).empty;
    defer missing.deinit(allocator);

    var src_dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
    defer src_dir.close();

    var walker = try src_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, "_test.zig")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        if (!reachable.contains(full_path)) {
            try missing.append(allocator, full_path);
        }
    }

    if (missing.items.len != 0) {
        for (missing.items) |path| {
            std.debug.print("orphan test file is not reachable from {s}: {s}\n", .{ root_test_entry, path });
        }
        return error.OrphanTestFile;
    }

    std.debug.print("test graph: all src/**/*_test.zig files are reachable from {s}\n", .{root_test_entry});
}

fn collectImports(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    bytes: []const u8,
    reachable: *std.StringHashMap(void),
    queue: *std.ArrayList([]const u8),
) !void {
    const file_dir = std.fs.path.dirname(file_path) orelse "";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, cursor, "@import(\"")) |import_start| {
        const path_start = import_start + "@import(\"".len;
        const path_end = std.mem.indexOfScalarPos(u8, bytes, path_start, '"') orelse return error.MalformedImport;
        cursor = path_end + 1;

        const import_path = bytes[path_start..path_end];
        if (!std.mem.endsWith(u8, import_path, ".zig")) continue;

        const resolved = try normalizeImportPath(allocator, file_dir, import_path);
        try std.fs.cwd().access(resolved, .{});

        if (!reachable.contains(resolved)) {
            try reachable.put(resolved, {});
            try queue.append(allocator, resolved);
        }
    }
}

fn normalizeImportPath(
    allocator: std.mem.Allocator,
    file_dir: []const u8,
    import_path: []const u8,
) ![]const u8 {
    const joined = if (file_dir.len == 0)
        try allocator.dupe(u8, import_path)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ file_dir, import_path });

    var components = std.ArrayList([]const u8).empty;
    defer components.deinit(allocator);

    var parts = std.mem.splitScalar(u8, joined, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (components.items.len == 0) return error.InvalidImportPath;
            components.items.len -= 1;
            continue;
        }
        try components.append(allocator, part);
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (components.items, 0..) |component, index| {
        if (index != 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, component);
    }
    return out.toOwnedSlice(allocator);
}
