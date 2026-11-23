const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const zevm = @import("zevm");
const harness = @import("harness");

fn makeAddress(seed: u64) primitives.Address {
    var addr = primitives.Address.ZERO;
    std.mem.writeInt(u64, addr.bytes[12..20], seed, .big);
    return addr;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "host-adapter");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();

    const addr = makeAddress(1);
    const contract = makeAddress(2);
    const code = [_]u8{0x5b} ** 512;
    try sm.setBalance(addr, 10_000_000_000);
    try sm.setNonce(addr, 42);
    try sm.setCode(contract, &code);
    for (0..64) |s| {
        try sm.setStorage(contract, s, s * 31 + 7);
    }

    var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };
    const iface = adapter.hostInterface();

    const Ctx = struct {
        adapter: *zevm.host_adapter.HostAdapter,
        iface: @TypeOf(iface),
        addr: primitives.Address,
        contract: primitives.Address,
        slot: u256 = 0,
        acc: u256 = 0,
    };
    var ctx = Ctx{
        .adapter = &adapter,
        .iface = iface,
        .addr = addr,
        .contract = contract,
    };

    try runner.run("host_adapter/get_balance_direct", &ctx, struct {
        fn f(c: *Ctx) !void {
            c.acc +%= try c.adapter.getBalance(c.addr);
            std.mem.doNotOptimizeAway(&c.acc);
        }
    }.f, .{});

    try runner.run("host_adapter/get_balance_vtable", &ctx, struct {
        fn f(c: *Ctx) !void {
            c.acc +%= c.iface.getBalance(c.addr);
            std.mem.doNotOptimizeAway(&c.acc);
        }
    }.f, .{});

    try runner.run("host_adapter/get_code_vtable", &ctx, struct {
        fn f(c: *Ctx) !void {
            const bytes = c.iface.getCode(c.contract);
            c.acc +%= bytes.len;
            std.mem.doNotOptimizeAway(&c.acc);
        }
    }.f, .{});

    try runner.run("host_adapter/get_storage_vtable", &ctx, struct {
        fn f(c: *Ctx) !void {
            c.slot = (c.slot + 1) & 63;
            c.acc +%= c.iface.getStorage(c.contract, c.slot);
            std.mem.doNotOptimizeAway(&c.acc);
        }
    }.f, .{});

    try runner.run("host_adapter/set_storage_vtable", &ctx, struct {
        fn f(c: *Ctx) !void {
            c.slot = (c.slot + 1) & 63;
            c.acc +%= 1;
            c.iface.setStorage(c.contract, c.slot, c.acc);
        }
    }.f, .{});

    try runner.run("host_adapter/set_balance_vtable", &ctx, struct {
        fn f(c: *Ctx) !void {
            c.acc +%= 1;
            c.iface.setBalance(c.addr, c.acc);
        }
    }.f, .{});

    try runner.run("host_adapter/account_exists_vtable", &ctx, struct {
        fn f(c: *Ctx) !void {
            const ex = c.iface.accountExists(c.contract);
            std.mem.doNotOptimizeAway(&ex);
        }
    }.f, .{});

    try runner.finish();
}
