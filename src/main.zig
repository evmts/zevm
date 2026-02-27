const std = @import("std");
const zevm = @import("zevm");
const node = @import("node.zig");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    try runWithArgs(args);
}

pub fn runWithArgs(args: []const []const u8) !void {
    const rpc_config = try parseRpcConfigFromArgs(args);

    var state = try zevm.state_manager.StateManager.init(std.heap.page_allocator, null);
    defer state.deinit();

    var chain = try zevm.blockchain.Blockchain.init(std.heap.page_allocator, null);
    defer chain.deinit();

    const runtime_node = node.Node{
        .state_manager = &state,
        .blockchain = &chain,
        .rpc_config = rpc_config,
        .chain_id = 31337,
    };

    const context = zevm.rpc.handlers.HandlerContext{
        .state_manager = runtime_node.state_manager,
        .blockchain = runtime_node.blockchain,
        .chain_id = runtime_node.chain_id,
    };

    try zevm.rpc.server.serve(std.heap.page_allocator, .{
        .host = runtime_node.rpc_config.host,
        .port = runtime_node.rpc_config.port,
        .cors_enabled = runtime_node.rpc_config.cors_enabled,
    }, &context);
}

pub fn parseRpcConfigFromArgs(args: []const []const u8) !node.RpcConfig {
    var config = node.RpcConfig{};

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--host")) {
            index += 1;
            if (index >= args.len) {
                return error.MissingHostValue;
            }
            config.host = args[index];
            continue;
        }

        if (std.mem.eql(u8, args[index], "--port")) {
            index += 1;
            if (index >= args.len) {
                return error.MissingPortValue;
            }
            config.port = std.fmt.parseInt(u16, args[index], 10) catch {
                return error.InvalidPort;
            };
            continue;
        }

        if (std.mem.eql(u8, args[index], "--cors")) {
            index += 1;
            if (index >= args.len) {
                return error.MissingCorsValue;
            }

            if (std.mem.eql(u8, args[index], "true")) {
                config.cors_enabled = true;
                continue;
            }

            if (std.mem.eql(u8, args[index], "false")) {
                config.cors_enabled = false;
                continue;
            }

            return error.InvalidCorsValue;
        }

        return error.UnknownArgument;
    }

    return config;
}
