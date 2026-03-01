const std = @import("std");
const zevm = @import("zevm");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    const config = try zevm.rpc.server.parseConfig(std.heap.page_allocator, args[1..]);
    var node_config = zevm.node_runtime.NodeConfig{};
    node_config.fork_url = config.fork_url;
    var node_handler = try zevm.rpc.node_handler.NodeHandler.init(std.heap.page_allocator, node_config);
    defer node_handler.deinit(std.heap.page_allocator);

    const handlers = zevm.rpc.dispatcher.HandlerRegistry{
        .context = &node_handler,
        .on_method_with_context = &zevm.rpc.node_handler.NodeHandler.onMethod,
    };
    try zevm.rpc.server.run(std.heap.page_allocator, config, &handlers);
}
