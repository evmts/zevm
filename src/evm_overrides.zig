const guillotine_mini = @import("guillotine_mini");
const primitives = @import("primitives");

const HandlerFrameType = guillotine_mini.Frame(.{});

pub const config = guillotine_mini.EvmConfig{
    .opcode_overrides = &.{
        .{
            .opcode = 0x34,
            .handler = @ptrCast(&callvalue),
        },
    },
};

pub const EvmType = guillotine_mini.Evm(config);

fn callvalue(frame: *HandlerFrameType) HandlerFrameType.EvmError!void {
    try frame.consumeGas(primitives.GasConstants.GasQuickStep);
    try frame.pushStack(delegatePreservedValue(frame) orelse frame.value);
    frame.pc += 1;
}

fn delegatePreservedValue(frame: *HandlerFrameType) ?u256 {
    if (frame.value != 0) return null;
    const evm = frame.getEvm();
    if (evm.frames.items.len < 2) return null;

    const parent = evm.frames.items[evm.frames.items.len - 2];
    if (parent.value == 0) return null;
    if (!parent.address.equals(frame.address)) return null;
    if (!parent.caller.equals(frame.caller)) return null;
    return parent.value;
}
