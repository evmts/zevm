const std = @import("std");
const primitives = @import("primitives");
const guillotine_mini = @import("guillotine_mini");
const precompiles = @import("precompiles");
const crypto = @import("crypto");

const ECRECOVER_GAS: u64 = 3000;

pub fn execute(
    allocator: std.mem.Allocator,
    address: primitives.Address,
    input: []const u8,
    gas_limit: u64,
    fork: guillotine_mini.Hardfork,
) anyerror!guillotine_mini.PrecompileOutput {
    if (address.equals(primitives.Address.fromU256(1))) {
        return executeEcrecover(allocator, input, gas_limit);
    }

    const result = try precompiles.execute(allocator, address, input, gas_limit, fork);
    return .{
        .output = result.output,
        .gas_used = result.gas_used,
        .success = true,
    };
}

fn executeEcrecover(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) anyerror!guillotine_mini.PrecompileOutput {
    if (gas_limit < ECRECOVER_GAS) return error.OutOfGas;

    var input_buf: [128]u8 = [_]u8{0} ** 128;
    const copy_len = @min(input.len, input_buf.len);
    @memcpy(input_buf[0..copy_len], input[0..copy_len]);

    const hash = input_buf[0..32];
    const v_word = std.mem.readInt(u256, input_buf[32..64], .big);
    if (v_word != 27 and v_word != 28) return emptyEcrecoverOutput(allocator);

    const r = input_buf[64..96];
    const s = input_buf[96..128];
    const pubkey = crypto.secp256k1.recoverPubkey(hash, r, s, @intCast(v_word)) catch {
        return emptyEcrecoverOutput(allocator);
    };

    var hash_output: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(&pubkey, &hash_output);

    const output = try allocator.alloc(u8, 32);
    @memset(output[0..12], 0);
    @memcpy(output[12..32], hash_output[12..32]);
    return .{
        .output = output,
        .gas_used = ECRECOVER_GAS,
        .success = true,
    };
}

fn emptyEcrecoverOutput(allocator: std.mem.Allocator) !guillotine_mini.PrecompileOutput {
    return .{
        .output = try allocator.alloc(u8, 0),
        .gas_used = ECRECOVER_GAS,
        .success = true,
    };
}
