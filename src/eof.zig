//! EOF1 static validation for the ethereum-tests Osaka fixture format
//! (0x04 data header, u16 child sizes, absolute maximum stack heights).
const std = @import("std");

pub const ContainerKind = enum { runtime, initcode };
pub const ValidationError = error{
    OutOfMemory,
    ContainerTooLarge,
    InvalidHeader,
    InvalidSectionCount,
    EmptySection,
    InvalidBodySize,
    InvalidType,
    InvalidMaxStackHeight,
    UndefinedOpcode,
    LegacyJumpdest,
    TruncatedImmediate,
    InvalidJumpTarget,
    InvalidSectionIndex,
    InvalidContainerIndex,
    InvalidContainerKind,
    UnreferencedContainer,
    InvalidDataOffset,
    MissingTerminator,
    UnreachableInstruction,
    UnreachableSection,
    StackUnderflow,
    StackOverflow,
    ConflictingStackHeight,
    InvalidReturn,
};

const max_container_size = 49152; // EIP-3860 MAX_INITCODE_SIZE
const max_section_height = 1023;
const non_returning = 0x80;

const rjump = 0xe0;
const rjumpi = 0xe1;
const rjumpv = 0xe2;
const callf = 0xe3;
const retf = 0xe4;
const jumpf = 0xe5;
const dupn = 0xe6;
const swapn = 0xe7;
const exchange = 0xe8;
const eofcreate = 0xec;
const returncontract = 0xee;
const dataloadn = 0xd1;

const Cursor = struct {
    rest: []const u8,

    fn take(c: *Cursor, size: usize) ValidationError![]const u8 {
        if (size > c.rest.len) return error.InvalidBodySize;
        const bytes = c.rest[0..size];
        c.rest = c.rest[size..];
        return bytes;
    }

    fn marker(c: *Cursor, expected: u8) ValidationError!void {
        if (c.rest.len == 0 or c.rest[0] != expected) return error.InvalidHeader;
        c.rest = c.rest[1..];
    }

    fn word(c: *Cursor) ValidationError!u16 {
        return readU16(try c.take(2));
    }

    fn sizes(c: *Cursor, limit: usize) ValidationError![]const u8 {
        const count: usize = try c.word();
        if (count == 0 or count > limit) return error.InvalidSectionCount;
        return c.take(count * 2);
    }

    fn section(c: *Cursor, sizes_bytes: []const u8, index: usize) ValidationError![]const u8 {
        const size = readU16(sizes_bytes[2 * index ..]);
        if (size == 0) return error.EmptySection;
        return c.take(size);
    }
};

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

const Section = struct {
    code: []const u8,
    inputs: u16,
    outputs: u16,
    max_height: u16,
    reachable: bool = false,
};

const Child = struct {
    bytes: []const u8,
    kind: ?ContainerKind = null,
};

const Container = struct {
    sections: []Section,
    children: []Child,
    data_size: u16,
};

const Pending = struct {
    bytes: []const u8,
    kind: ContainerKind,
    // Only a runtime template selected by RETURNCONTRACT may have a data suffix
    // supplied later during deployment. Both kinds of top-level input are complete.
    allow_short_data: bool = false,
};

fn parse(arena: std.mem.Allocator, item: Pending) ValidationError!Container {
    var cursor = Cursor{ .rest = item.bytes };
    for ([_]u8{ 0xef, 0x00, 0x01, 0x01 }) |byte| try cursor.marker(byte);
    const type_size = try cursor.word();
    try cursor.marker(0x02);
    const code_sizes = try cursor.sizes(1024);
    const section_count = code_sizes.len / 2;
    if (type_size != 4 * section_count) return error.InvalidType;
    var child_sizes: []const u8 = "";
    if (std.mem.startsWith(u8, cursor.rest, "\x03")) {
        try cursor.marker(0x03);
        child_sizes = try cursor.sizes(256);
    }
    try cursor.marker(0x04);
    const data_size = try cursor.word();
    try cursor.marker(0);

    var types = Cursor{ .rest = try cursor.take(type_size) };
    const sections = try arena.alloc(Section, section_count);
    for (sections, 0..) |*s, i| {
        const t = try types.take(4);
        s.* = .{
            .code = try cursor.section(code_sizes, i),
            .inputs = t[0],
            .outputs = t[1],
            .max_height = readU16(t[2..]),
        };
        if (s.inputs > 0x7f or s.outputs > non_returning) return error.InvalidType;
        if (s.max_height > max_section_height or s.max_height < s.inputs) return error.InvalidMaxStackHeight;
    }
    if (sections[0].inputs != 0 or sections[0].outputs != non_returning) return error.InvalidType;
    const children = try arena.alloc(Child, child_sizes.len / 2);
    for (children, 0..) |*child, i| child.* = .{ .bytes = try cursor.section(child_sizes, i) };
    if (cursor.rest.len > data_size or (!item.allow_short_data and cursor.rest.len != data_size))
        return error.InvalidBodySize;
    return .{ .sections = sections, .children = children, .data_size = data_size };
}

/// Validate one complete EOF1 container, including every nested initcode and
/// runtime template. Code and data are borrowed only for the duration of the call.
pub fn validateContainer(allocator: std.mem.Allocator, code: []const u8, kind: ContainerKind) ValidationError!void {
    return validate(allocator, code, kind, .reject_jumpdest);
}

/// The Osaka fixtures use the EIP-4750 assignment of 0x5b to NOP. The fixture
/// runner uses this entry point to verify divergences from the strict opcode ban.
pub fn validateWithEip4750Nop(
    allocator: std.mem.Allocator,
    code: []const u8,
    kind: ContainerKind,
) ValidationError!void {
    return validate(allocator, code, kind, .eof_nop);
}

const Opcode5b = enum { reject_jumpdest, eof_nop };

fn validate(
    allocator: std.mem.Allocator,
    code: []const u8,
    kind: ContainerKind,
    opcode_5b: Opcode5b,
) ValidationError!void {
    if (code.len > max_container_size) return error.ContainerTooLarge;
    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, .{ .bytes = code, .kind = kind });
    // Nesting is bounded by the byte length, not by the host call stack.
    while (pending.pop()) |item| {
        var storage = std.heap.ArenaAllocator.init(allocator);
        defer storage.deinit();
        const arena = storage.allocator();
        const container = try parse(arena, item);
        var work: std.ArrayList(usize) = .empty;
        try work.ensureTotalCapacity(arena, container.sections.len);
        container.sections[0].reachable = true;
        work.appendAssumeCapacity(0);
        var visited: usize = 0;
        while (work.pop()) |index| {
            try validateSection(allocator, container, index, item.kind, opcode_5b, &work);
            visited += 1;
        }
        if (visited != container.sections.len) return error.UnreachableSection;
        for (container.children) |child| {
            const child_kind = child.kind orelse return error.UnreferencedContainer;
            try pending.append(allocator, .{
                .bytes = child.bytes,
                .kind = child_kind,
                .allow_short_data = child_kind == .runtime,
            });
        }
    }
}

fn instructionSize(code: []const u8) ValidationError!u16 {
    const size: u16 = switch (code[0]) {
        0x60...0x7f => @as(u16, code[0]) - 0x5f + 1,
        rjump, rjumpi, callf, jumpf, dataloadn => 3,
        rjumpv => if (code.len < 2) return error.TruncatedImmediate else 2 + 2 * (@as(u16, code[1]) + 1),
        dupn, swapn, exchange, eofcreate, returncontract => 2,
        else => 1,
    };
    if (size > code.len) return error.TruncatedImmediate;
    return size;
}

const Effect = struct { inputs: u16, outputs: u16 };

fn effect(inputs: u16, outputs: u16) Effect {
    return .{ .inputs = inputs, .outputs = outputs };
}

// For DUP/SWAP/EXCHANGE the counts include the entire required stack prefix,
// so the same underflow check covers indexed access and ordinary pops.
fn stackEffect(op: u8, imm: []const u8, opcode_5b: Opcode5b) ValidationError!Effect {
    return switch (op) {
        0x00, rjump, 0xfe => effect(0, 0),
        0x01...0x07, 0x0a...0x0b, 0x10...0x14, 0x16...0x18, 0x1a...0x1d, 0x20 => effect(2, 1),
        0x08...0x09 => effect(3, 1),
        0x15, 0x19, 0x31, 0x35, 0x40, 0x49, 0x51, 0x54, 0x5c, 0xd0, 0xf7 => effect(1, 1),
        0x30, 0x32...0x34, 0x36, 0x3a, 0x3d, 0x41...0x48, 0x4a, 0x59, 0x5f...0x7f, dataloadn, 0xd2 => effect(0, 1),
        0x37, 0x3e, 0x5e, 0xd3 => effect(3, 0),
        0x50, rjumpi, rjumpv => effect(1, 0),
        0x52, 0x53, 0x55, 0x5d, 0xf3, 0xfd, returncontract => effect(2, 0),
        0x80...0x8f => effect(op - 0x7f, op - 0x7f + 1),
        0x90...0x9f => effect(op - 0x90 + 2, op - 0x90 + 2),
        0xa0...0xa4 => effect(op - 0xa0 + 2, 0),
        dupn => effect(@as(u16, imm[0]) + 1, @as(u16, imm[0]) + 2),
        swapn => effect(@as(u16, imm[0]) + 2, @as(u16, imm[0]) + 2),
        exchange => ex: {
            const required = (imm[0] >> 4) + (imm[0] & 15) + 3;
            break :ex effect(required, required);
        },
        eofcreate, 0xf8 => effect(4, 1),
        0xf9, 0xfb => effect(3, 1),
        0x5b => if (opcode_5b == .eof_nop) effect(0, 0) else error.LegacyJumpdest,
        else => error.UndefinedOpcode,
    };
}

const Heights = struct {
    low: u16,
    high: u16,

    fn after(h: Heights, e: Effect) ValidationError!Heights {
        if (h.low < e.inputs) return error.StackUnderflow;
        const high = h.high - e.inputs + e.outputs;
        if (high > max_section_height) return error.StackOverflow;
        return .{ .low = h.low - e.inputs + e.outputs, .high = high };
    }

    fn exactly(h: Heights, height: u16) bool {
        return h.low == height and h.high == height;
    }
};

const Instruction = struct {
    size: u16 = 0, // Zero marks an immediate byte.
    entry: ?Heights = null,
};

fn successor(layout: []Instruction, pc: usize, target: usize, heights: Heights) ValidationError!void {
    if (target >= layout.len or layout[target].size == 0) return error.InvalidJumpTarget;
    const entry = &layout[target].entry;
    if (entry.*) |prior| {
        if (target <= pc) {
            if (prior.low != heights.low or prior.high != heights.high) return error.ConflictingStackHeight;
        } else {
            entry.* = .{ .low = @min(prior.low, heights.low), .high = @max(prior.high, heights.high) };
        }
    } else {
        entry.* = heights;
    }
}

fn branch(layout: []Instruction, pc: usize, next: usize, offset: []const u8, heights: Heights) ValidationError!void {
    const destination = @as(i32, @intCast(next)) + std.mem.readInt(i16, offset[0..2], .big);
    if (destination < 0) return error.InvalidJumpTarget;
    try successor(layout, pc, @intCast(destination), heights);
}

fn validateSection(
    allocator: std.mem.Allocator,
    container: Container,
    index: usize,
    kind: ContainerKind,
    opcode_5b: Opcode5b,
    work: *std.ArrayList(usize),
) ValidationError!void {
    const section = container.sections[index];
    const code = section.code;
    const layout = try allocator.alloc(Instruction, code.len);
    defer allocator.free(layout);
    @memset(layout, .{});
    var pc: usize = 0;
    while (pc < code.len) {
        layout[pc].size = try instructionSize(code[pc..]);
        pc += layout[pc].size;
    }

    // The forward pass merges incoming ranges before the instruction is visited.
    // A back edge must reproduce the already-checked range exactly (EIP-5450).
    layout[0].entry = .{ .low = section.inputs, .high = section.inputs };
    var peak: u16 = section.inputs;
    var can_return = false;
    pc = 0;
    while (pc < code.len) {
        const op = code[pc];
        const next = pc + layout[pc].size;
        const imm = code[pc + 1 .. next];
        const h = layout[pc].entry orelse return error.UnreachableInstruction;
        peak = @max(peak, h.high);
        var after = h;
        switch (op) {
            callf, jumpf => {
                const target_idx = readU16(imm);
                if (target_idx >= container.sections.len) return error.InvalidSectionIndex;
                const target = &container.sections[target_idx];
                if (!target.reachable) {
                    target.reachable = true;
                    work.appendAssumeCapacity(target_idx);
                }
                if (h.low < target.inputs) return error.StackUnderflow;
                if (h.high - target.inputs + target.max_height > 1024) return error.StackOverflow;
                if (op == callf) {
                    if (target.outputs == non_returning) return error.InvalidReturn;
                    after = try h.after(effect(target.inputs, target.outputs));
                } else if (target.outputs != non_returning) {
                    if (section.outputs == non_returning or section.outputs < target.outputs) {
                        return error.InvalidReturn;
                    }
                    if (!h.exactly(section.outputs - target.outputs + target.inputs)) return error.InvalidReturn;
                    can_return = true;
                }
            },
            retf => {
                if (section.outputs == non_returning or !h.exactly(section.outputs)) return error.InvalidReturn;
                can_return = true;
            },
            else => {
                if ((op == 0x00 or op == 0xf3) and kind == .initcode) return error.InvalidContainerKind;
                if (op == returncontract and kind == .runtime) return error.InvalidContainerKind;
                if (op == eofcreate or op == returncontract) {
                    if (imm[0] >= container.children.len) return error.InvalidContainerIndex;
                    const child = &container.children[imm[0]];
                    const expected: ContainerKind = if (op == eofcreate) .initcode else .runtime;
                    if (child.kind) |known| {
                        if (known != expected) return error.InvalidContainerKind;
                    }
                    child.kind = expected;
                }
                if (op == dataloadn and @as(u32, readU16(imm)) + 32 > container.data_size)
                    return error.InvalidDataOffset;
                after = try h.after(try stackEffect(op, imm, opcode_5b));
            },
        }

        switch (op) {
            rjump, rjumpi => try branch(layout, pc, next, imm, after),
            rjumpv => {
                var i: usize = 1;
                while (i < imm.len) : (i += 2) try branch(layout, pc, next, imm[i..], after);
            },
            else => {},
        }
        switch (op) {
            0x00, 0xf3, 0xfd, 0xfe, retf, jumpf, returncontract, rjump => {},
            else => {
                if (next == code.len) return error.MissingTerminator;
                try successor(layout, pc, next, after);
            },
        }
        pc = next;
    }
    if (can_return != (section.outputs != non_returning)) return error.InvalidReturn;
    if (peak != section.max_height) return error.InvalidMaxStackHeight;
}

const TestSection = struct {
    code: []const u8,
    inputs: u8 = 0,
    outputs: u8 = non_returning,
    max_height: u16 = 0,
};

const Example = struct {
    sections: []const TestSection,
    children: []const []const u8 = &.{},
    data_size: u16 = 0,
    data: []const u8 = "",

    fn word(bytes: *std.ArrayList(u8), n: usize) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, @intCast(n), .big);
        try bytes.appendSlice(std.testing.allocator, &buf);
    }

    fn encode(example: Example) ![]u8 {
        const a = std.testing.allocator;
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(a);
        try bytes.appendSlice(a, "\xef\x00\x01\x01");
        try word(&bytes, example.sections.len * 4);
        try bytes.append(a, 2);
        try word(&bytes, example.sections.len);
        for (example.sections) |s| try word(&bytes, s.code.len);
        if (example.children.len != 0) {
            try bytes.append(a, 3);
            try word(&bytes, example.children.len);
            for (example.children) |child| try word(&bytes, child.len);
        }
        try bytes.append(a, 4);
        try word(&bytes, example.data_size);
        try bytes.append(a, 0);
        for (example.sections) |s| {
            try bytes.appendSlice(a, &.{ s.inputs, s.outputs });
            try word(&bytes, s.max_height);
        }
        for (example.sections) |s| try bytes.appendSlice(a, s.code);
        for (example.children) |child| try bytes.appendSlice(a, child);
        try bytes.appendSlice(a, example.data);
        return bytes.toOwnedSlice(a);
    }

    fn check(example: Example, kind: ContainerKind, expected: ?ValidationError) !void {
        const bytes = try example.encode();
        defer std.testing.allocator.free(bytes);
        const result = validateContainer(std.testing.allocator, bytes, kind);
        if (expected) |err| try std.testing.expectError(err, result) else try result;
    }
};

fn checkCode(code: []const u8, max_height: u16, expected: ?ValidationError) !void {
    const example = Example{ .sections = &.{.{ .code = code, .max_height = max_height }} };
    try example.check(.runtime, expected);
}

test "EOF1 header, counts, section zero type, exact body length" {
    const a = std.testing.allocator;
    const minimal = "\xef\x00\x01\x01\x00\x04\x02\x00\x01\x00\x01\x04\x00\x00\x00\x00\x80\x00\x00\x00";
    try validateContainer(a, minimal, .runtime);
    for (0..minimal.len) |n| {
        if (validateContainer(a, minimal[0..n], .runtime)) return error.AcceptedTruncation else |err| try std.testing.expect(err != error.OutOfMemory);
    }
    try std.testing.expectError(error.InvalidBodySize, validateContainer(a, minimal ++ "\x00", .runtime));
    const Mutation = struct { offset: usize, byte: u8, err: ValidationError };
    for ([_]Mutation{
        .{ .offset = 0, .byte = 0, .err = error.InvalidHeader },
        .{ .offset = 2, .byte = 2, .err = error.InvalidHeader },
        .{ .offset = 5, .byte = 5, .err = error.InvalidType },
        .{ .offset = 6, .byte = 1, .err = error.InvalidHeader },
        .{ .offset = 7, .byte = 4, .err = error.InvalidSectionCount },
        .{ .offset = 8, .byte = 0, .err = error.InvalidSectionCount },
        .{ .offset = 10, .byte = 0, .err = error.EmptySection },
        .{ .offset = 11, .byte = 0xff, .err = error.InvalidHeader },
        .{ .offset = 13, .byte = 1, .err = error.InvalidBodySize },
        .{ .offset = 14, .byte = 1, .err = error.InvalidHeader },
        .{ .offset = 15, .byte = 0x80, .err = error.InvalidType },
        .{ .offset = 16, .byte = 0x81, .err = error.InvalidType },
        .{ .offset = 16, .byte = 0x7f, .err = error.InvalidType },
        .{ .offset = 17, .byte = 4, .err = error.InvalidMaxStackHeight },
    }) |m| {
        var bytes = minimal.*;
        bytes[m.offset] = m.byte;
        try std.testing.expectError(m.err, validateContainer(a, &bytes, .runtime));
    }
    for ([_][]const u8{ "\x00\x00", "\x01\x01" }) |count| {
        const bytes = try std.mem.concat(a, u8, &.{ minimal[0..11], "\x03", count });
        defer a.free(bytes);
        try std.testing.expectError(error.InvalidSectionCount, validateContainer(a, bytes, .runtime));
    }
    try std.testing.expectError(error.ContainerTooLarge, validateContainer(a, "\x00" ** (max_container_size + 1), .runtime));
}

test "legacy and undefined instructions, immediate widths and fallthrough" {
    for ([_]u8{ 0x0c, 0x38, 0x39, 0x3b, 0x3c, 0x3f, 0x56, 0x57, 0x58, 0x5a, 0xef, 0xf0, 0xf1, 0xf2, 0xf4, 0xf5, 0xfa, 0xff }) |op|
        try checkCode(&.{ op, 0 }, 0, error.UndefinedOpcode);
    try checkCode("\x5b\x00", 0, error.LegacyJumpdest);
    for ([_]u8{ 0x60, 0x7f, rjump, rjumpi, rjumpv, callf, jumpf, dataloadn, dupn, swapn, exchange, eofcreate, returncontract }) |op|
        try checkCode(&.{op}, 0, error.TruncatedImmediate);
    try checkCode("\x7f" ++ "\xff" ** 32 ++ "\x00", 1, null);
    try checkCode("\x5f\xe2\x01\x00\x00\x00", 1, error.TruncatedImmediate);
    try checkCode("\x5f\xe2\xff" ++ "\x00" ** 512 ++ "\xfe", 1, null);
    try checkCode("\x5f\xe1\xff\xfc", 1, error.MissingTerminator);
    try checkCode("\x5f", 1, error.MissingTerminator);
    try checkCode("\xfe", 0, null);
}

test "EIP-4750 fixture profile validates instructions after NOP" {
    var section = [_]TestSection{.{ .code = "\x5b\x00" }};
    const example = Example{ .sections = &section };
    const valid = try example.encode();
    defer std.testing.allocator.free(valid);
    try std.testing.expectError(error.LegacyJumpdest, validateContainer(std.testing.allocator, valid, .runtime));
    try validateWithEip4750Nop(std.testing.allocator, valid, .runtime);
    section[0].code = "\x5b\xff";
    const invalid = try example.encode();
    defer std.testing.allocator.free(invalid);
    try std.testing.expectError(error.UndefinedOpcode, validateWithEip4750Nop(std.testing.allocator, invalid, .runtime));
}

test "forward joins use both bounds and backward edges must preserve the entire range" {
    // Conditional branch skips PUSH0. STOP accepts either entry height.
    try checkCode("\x5f\xe1\x00\x01\x5f\x00", 1, null);
    try checkCode("\x5f\xe1\x00\x01\x5f\x50\x00", 1, error.StackUnderflow);
    try checkCode("\x5f\xe1\x00\x01\x5f\xe0\xff\xfd", 1, null);
    try checkCode("\x5f\xe1\x00\x01\x5f\x5f\xe0\xff\xfc", 2, error.ConflictingStackHeight);
    try checkCode("\xe0\xff\xfd", 0, null);
    try checkCode("\xe0\x00\x01\x00\xe0\xff\xfc", 0, error.UnreachableInstruction);
    try checkCode("\x00\xfe", 0, error.UnreachableInstruction);
    for ([_][]const u8{
        "\xe0\xff\xfe", // own immediate
        "\xe0\xff\xfc", // before section
        "\xe0\x00\x00", // past section
        "\x5f\xe1\x00\x01\x60\x00\x00", // PUSH immediate
        "\x5f\xe2\x01\x00\x00\xff\xff\x00", // RJUMPV table
    }) |code| try checkCode(code, 1, error.InvalidJumpTarget);
}

test "stack heights and indexed stack instructions" {
    try checkCode("\x5f\x00", 0, error.InvalidMaxStackHeight);
    try checkCode("\x5f\x00", 2, error.InvalidMaxStackHeight);
    try checkCode("\x5f" ** 1023 ++ "\x00", 1023, null);
    try checkCode("\x5f" ** 1024 ++ "\x00", 1023, error.StackOverflow);
    try checkCode("\x5f" ** 256 ++ "\xe6\xff\x00", 257, null);
    try checkCode("\x5f" ** 255 ++ "\xe6\xff\x00", 256, error.StackUnderflow);
    try checkCode("\x5f" ** 257 ++ "\xe7\xff\x00", 257, null);
    try checkCode("\x5f" ** 256 ++ "\xe7\xff\x00", 256, error.StackUnderflow);
    try checkCode("\x5f" ** 33 ++ "\xe8\xff\x00", 33, null);
    try checkCode("\x5f" ** 32 ++ "\xe8\xff\x00", 32, error.StackUnderflow);
    try checkCode("\x5f\xf7\x00", 1, null);
    try checkCode("\x5f\x5f\x5f\xf8\x00", 3, error.StackUnderflow);
    try checkCode("\x5f\x5f\x5f\xf9\x00", 3, null);
    try checkCode("\x5f\x5f\x5f\xfb\x00", 3, null);
}

test "CALLF, RETF, tail calls and section graph reachability" {
    var s = [_]TestSection{
        .{ .code = "\x5f\xe3\x00\x01\x00", .max_height = 2 },
        .{ .code = "\xe5\x00\x02", .inputs = 1, .outputs = 2, .max_height = 1 },
        .{ .code = "\x5f\xe4", .outputs = 1, .max_height = 1 },
    };
    const example = Example{ .sections = &s };
    try example.check(.runtime, null); // One retained item plus one output from section 2.
    s[2].code = "\x00";
    try example.check(.runtime, error.InvalidReturn); // Declared returning with no return path.
    s[2].code = "\xe4";
    try example.check(.runtime, error.InvalidReturn); // RETF at the wrong height.
    s[1].code = "\x5f\xe5\x00\x02";
    try example.check(.runtime, error.InvalidReturn); // Extra item at tail call.
    s[1].outputs = 0;
    s[0].max_height = 1;
    try example.check(.runtime, error.InvalidReturn); // Target returns more than caller.
    s[1].outputs = non_returning;
    try example.check(.runtime, error.InvalidReturn); // CALLF to a non-returning section.
    s[0].code = "\xe5\x00\x01";
    try example.check(.runtime, error.StackUnderflow);
    s[1].inputs = 0;
    s[0].max_height = 0;
    s[1].code = "\xe5\x00\x01";
    s[1].max_height = 0;
    try example.check(.runtime, error.UnreachableSection);
    s[0].code = "\xe5\x00\x03";
    try example.check(.runtime, error.InvalidSectionIndex);
    try checkCode("\xe4", 0, error.InvalidReturn);
}

test "CALLF and JUMPF account for peak stack usage in the callee" {
    var sections = [_]TestSection{
        .{ .code = "\x5f\xe3\x00\x01\x00", .max_height = 1 },
        .{ .code = "\x5f" ** 1023 ++ "\x50" ** 1023 ++ "\xe4", .outputs = 0, .max_height = 1023 },
    };
    const example = Example{ .sections = &sections };
    try example.check(.runtime, null); // Global stack may reach 1024 across frames.
    sections[0] = .{ .code = "\x5f\x5f\xe3\x00\x01\x00", .max_height = 2 };
    try example.check(.runtime, error.StackOverflow);
    sections[0].code = "\x5f\x5f\xe5\x00\x01";
    sections[1].outputs = non_returning;
    sections[1].code = "\x5f" ** 1023 ++ "\x00";
    try example.check(.runtime, error.StackOverflow);
}

test "DATALOADN checks a full word against the declared data size" {
    var s = [_]TestSection{.{ .code = "\xd1\x00\x01\x00", .max_height = 1 }};
    var example = Example{ .sections = &s, .data_size = 33, .data = "\x00" ** 33 };
    try example.check(.runtime, null);
    s[0].code = "\xd1\x00\x02\x00";
    try example.check(.runtime, error.InvalidDataOffset);
    s[0].code = "\xd1\xff\xff\x00";
    try example.check(.runtime, error.InvalidDataOffset);
    s[0].code = "\xd1\x00\x00\x00";
    example.data_size = 34;
    try example.check(.runtime, error.InvalidBodySize);
    try example.check(.initcode, error.InvalidBodySize);
}

test "nested templates, complete initcode, kind inference and references" {
    const a = std.testing.allocator;
    const runtime = try (Example{
        .sections = &.{.{ .code = "\xd1\x00\x00\x00", .max_height = 1 }},
        .data_size = 32,
    }).encode();
    defer a.free(runtime);
    var init = Example{
        .sections = &.{.{ .code = "\x5f\x5f\xee\x00", .max_height = 2 }},
        .children = &.{runtime},
    };
    try init.check(.initcode, null);
    try init.check(.runtime, error.InvalidContainerKind);
    const complete = try init.encode();
    defer a.free(complete);
    var factory = Example{
        .sections = &.{.{ .code = "\x5f\x5f\x5f\x5f\xec\x00\x00", .max_height = 4 }},
        .children = &.{complete},
    };
    try factory.check(.runtime, null);
    try factory.check(.initcode, error.InvalidContainerKind);
    init.data_size = 1;
    const short = try init.encode();
    defer a.free(short);
    factory.children = &.{short};
    try factory.check(.runtime, error.InvalidBodySize);
    factory.children = &.{};
    try factory.check(.runtime, error.InvalidContainerIndex);
    factory.children = &.{ complete, complete };
    try factory.check(.runtime, error.UnreferencedContainer);
    factory.sections = &.{.{ .code = "\x5f\x5f\x5f\x5f\xec\x00\x5f\xee\x00", .max_height = 4 }};
    try factory.check(.initcode, error.InvalidContainerKind);
    factory.children = &.{""};
    try factory.check(.initcode, error.EmptySection);
    init.children = &.{"\xef\x00"};
    init.data_size = 0;
    try init.check(.initcode, error.InvalidHeader);
    const reverting = Example{ .sections = &.{.{ .code = "\x5f\x5f\xfd", .max_height = 2 }} };
    try reverting.check(.runtime, null);
    try reverting.check(.initcode, null);
}

test "resolve the last of 1024 code sections and the last of 256 subcontainers" {
    const a = std.testing.allocator;
    var sections: [1024]TestSection = undefined;
    var jumps: [1023][3]u8 = undefined;
    for (&jumps, 0..) |*jmp, i| {
        jmp[0] = jumpf;
        std.mem.writeInt(u16, jmp[1..3], @intCast(i + 1), .big);
        sections[i] = .{ .code = jmp };
    }
    sections[1023] = .{ .code = "\x00" };
    try (Example{ .sections = &sections }).check(.runtime, null);

    const child = try (Example{ .sections = &.{.{ .code = "\xfe" }} }).encode();
    defer a.free(child);
    var children: [256][]const u8 = undefined;
    @memset(&children, child);
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(a);
    for (0..children.len) |i| {
        try code.appendSlice(a, "\x5f\x5f\x5f\x5f");
        try code.appendSlice(a, &.{ eofcreate, @intCast(i), 0x50 });
    }
    try code.append(a, 0);
    try (Example{ .sections = &.{.{ .code = code.items, .max_height = 4 }}, .children = &children }).check(.runtime, null);
}

test "allocator failures propagate through nested validation" {
    const a = std.testing.allocator;
    const leaf = try (Example{ .sections = &.{.{ .code = "\xfe" }} }).encode();
    defer a.free(leaf);
    const bytes = try (Example{
        .sections = &.{.{ .code = "\x5f\x5f\xee\x00", .max_height = 2 }},
        .children = &.{leaf},
    }).encode();
    defer a.free(bytes);
    try std.testing.checkAllAllocationFailures(a, validateContainer, .{ @as([]const u8, bytes), ContainerKind.initcode });
}
