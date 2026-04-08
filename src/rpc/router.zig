const std = @import("std");
const jsonrpc = @import("jsonrpc");
const envelope = @import("envelope.zig");
const handlers = @import("handlers.zig");

pub fn route(
    allocator: std.mem.Allocator,
    context: *const handlers.HandlerContext,
    request: envelope.Request,
) ![]u8 {
    if (request.invalid_request or request.method.len == 0) {
        return envelope.writeError(allocator, request.id, -32600, "Invalid request");
    }

    if (!isKnownMethod(request.method)) {
        return envelope.writeError(allocator, request.id, -32601, "Method not found");
    }

    const dispatch_result = try handlers.dispatch(
        allocator,
        context,
        request.method,
        request.params,
        request.id,
    );

    return switch (dispatch_result) {
        .success => |result| envelope.writeSuccess(allocator, request.id, result),
        .rpc_error => |rpc_error| envelope.writeError(allocator, request.id, rpc_error.code, rpc_error.message),
    };
}

pub fn routeBatch(
    allocator: std.mem.Allocator,
    context: *const handlers.HandlerContext,
    requests: []const envelope.Request,
) ![]u8 {
    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    try response_writer.writer.writeByte('[');

    for (requests, 0..) |request, index| {
        if (index > 0) {
            try response_writer.writer.writeByte(',');
        }

        const response_item = try route(allocator, context, request);
        defer allocator.free(response_item);

        try response_writer.writer.writeAll(response_item);
    }

    try response_writer.writer.writeByte(']');

    return response_writer.toOwnedSlice();
}

fn isKnownMethod(method_name: []const u8) bool {
    _ = jsonrpc.eth.EthMethod.fromMethodName(method_name) catch {
        _ = jsonrpc.debug.DebugMethod.fromMethodName(method_name) catch {
            _ = jsonrpc.engine.EngineMethod.fromMethodName(method_name) catch {
                _ = jsonrpc.evm.EvmMethod.fromMethodName(method_name) catch {
                    _ = jsonrpc.hardhat.HardhatMethod.fromMethodName(method_name) catch {
                        _ = jsonrpc.anvil.AnvilMethod.fromMethodName(method_name) catch {
                            if (std.mem.eql(u8, method_name, "zevm_mine") or
                                std.mem.eql(u8, method_name, "anvil_mine") or
                                std.mem.eql(u8, method_name, "evm_mine") or
                                std.mem.eql(u8, method_name, "hardhat_mine") or
                                std.mem.eql(u8, method_name, "evm_increaseTime") or
                                std.mem.eql(u8, method_name, "evm_setNextBlockTimestamp") or
                                std.mem.eql(u8, method_name, "hardhat_setAutomine") or
                                std.mem.eql(u8, method_name, "evm_setAutomine") or
                                std.mem.eql(u8, method_name, "anvil_setAutomine") or
                                std.mem.eql(u8, method_name, "hardhat_setIntervalMining") or
                                std.mem.eql(u8, method_name, "evm_setIntervalMining") or
                                std.mem.eql(u8, method_name, "anvil_setIntervalMining") or
                                std.mem.eql(u8, method_name, "hardhat_setPrevRandao") or
                                std.mem.eql(u8, method_name, "hardhat_impersonateAccount") or
                                std.mem.eql(u8, method_name, "hardhat_stopImpersonatingAccount") or
                                std.mem.eql(u8, method_name, "debug_traceCall") or
                                std.mem.eql(u8, method_name, "debug_traceTransaction") or
                                std.mem.eql(u8, method_name, "eth_subscribe") or
                                std.mem.eql(u8, method_name, "eth_unsubscribe"))
                            {
                                return true;
                            }
                            return false;
                        };
                        return true;
                    };
                    return true;
                };
                return true;
            };
            return true;
        };
        return true;
    };
    return true;
}
