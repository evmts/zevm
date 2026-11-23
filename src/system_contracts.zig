//! Canonical Cancun and Prague system contracts.
//!
//! Each fork's block processing calls these contracts as `SYSTEM_ADDRESS`.
//! EIP-7002 and EIP-7251 make a block invalid when the contract has no code,
//! so a chain that activates Prague must carry the code in its state. Mainnet
//! got it from keyless deployment transactions before each fork. A local dev
//! chain has no such transactions, so its genesis allocation installs the
//! same runtime bytecode at the same addresses (as geth `--dev` and the
//! ethereum-genesis-generator do).
//!
//! The runtime bytecode is copied from the "Bytecode"/deployment sections of
//! the EIPs (pinned to ethereum/EIPs commit 9207c6011f526bd40abd79649484a1a342585bd4)
//! and is byte-identical to the mainnet deployments:
//!   EIP-4788: https://eips.ethereum.org/EIPS/eip-4788
//!   EIP-2935: https://eips.ethereum.org/EIPS/eip-2935
//!   EIP-7002: https://eips.ethereum.org/EIPS/eip-7002
//!   EIP-7251: https://eips.ethereum.org/EIPS/eip-7251

const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const hardfork_schedule = @import("hardfork_schedule.zig");

/// Caller of every system call (EIP-4788).
pub const SYSTEM_ADDRESS = primitives.Address{ .bytes = .{
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
} };

/// EIP-4788 beacon block roots contract (Cancun).
pub const BEACON_ROOTS_ADDRESS = primitives.Address{ .bytes = .{
    0x00, 0x0f, 0x3d, 0xf6, 0xd7, 0x32, 0x80, 0x7e, 0xf1, 0x31,
    0x9f, 0xb7, 0xb8, 0xbb, 0x85, 0x22, 0xd0, 0xbe, 0xac, 0x02,
} };

/// EIP-2935 block hash history contract (Prague).
pub const HISTORY_STORAGE_ADDRESS = primitives.Address{ .bytes = .{
    0x00, 0x00, 0xf9, 0x08, 0x27, 0xf1, 0xc5, 0x3a, 0x10, 0xcb,
    0x7a, 0x02, 0x33, 0x5b, 0x17, 0x53, 0x20, 0x00, 0x29, 0x35,
} };

/// EIP-7002 withdrawal requests contract (Prague).
pub const WITHDRAWAL_REQUESTS_ADDRESS = primitives.Address{ .bytes = .{
    0x00, 0x00, 0x09, 0x61, 0xef, 0x48, 0x0e, 0xb5, 0x5e, 0x80,
    0xd1, 0x9a, 0xd8, 0x35, 0x79, 0xa6, 0x4c, 0x00, 0x70, 0x02,
} };

/// EIP-7251 consolidation requests contract (Prague).
pub const CONSOLIDATION_REQUESTS_ADDRESS = primitives.Address{ .bytes = .{
    0x00, 0x00, 0xbb, 0xdd, 0xc7, 0xce, 0x48, 0x86, 0x42, 0xfb,
    0x57, 0x9f, 0x8b, 0x00, 0xf3, 0xa5, 0x90, 0x00, 0x72, 0x51,
} };

/// EIP-4788 runtime bytecode (97 bytes).
pub const BEACON_ROOTS_CODE = hex(
    "3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff" ++
        "810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff0155" ++
        "00",
);

/// EIP-2935 runtime bytecode (83 bytes).
pub const HISTORY_STORAGE_CODE = hex(
    "3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81" ++
        "430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500",
);

/// EIP-7002 runtime bytecode (504 bytes).
pub const WITHDRAWAL_REQUESTS_CODE = hex(
    "3373fffffffffffffffffffffffffffffffffffffffe1460cb5760115f54807fffffffffffffffffffffffffffffffff" ++
        "ffffffffffffffffffffffffffffffff146101f457600182026001905f5b5f8211156068578101908302848302900491" ++
        "6001019190604d565b909390049250505036603814608857366101f457346101f4575f5260205ff35b34106101f45760" ++
        "0154600101600155600354806003026004013381556001015f35815560010160203590553360601b5f5260385f601437" ++
        "604c5fa0600101600355005b6003546002548082038060101160df575060105b5f5b8181146101835782810160030260" ++
        "040181604c02815460601b8152601401816001015481526020019060020154807fffffffffffffffffffffffffffffff" ++
        "ff00000000000000000000000000000000168252906010019060401c908160381c81600701538160301c816006015381" ++
        "60281c81600501538160201c81600401538160181c81600301538160101c81600201538160081c816001015353600101" ++
        "60e1565b910180921461019557906002556101a0565b90505f6002555f6003555b5f54807fffffffffffffffffffffff" ++
        "ffffffffffffffffffffffffffffffffffffffffff14156101cd57505f5b6001546002828201116101e25750505f6101" ++
        "e8565b01600290035b5f555f600155604c025ff35b5f5ffd",
);

/// EIP-7251 runtime bytecode (414 bytes).
pub const CONSOLIDATION_REQUESTS_CODE = hex(
    "3373fffffffffffffffffffffffffffffffffffffffe1460d35760115f54807fffffffffffffffffffffffffffffffff" ++
        "ffffffffffffffffffffffffffffffff1461019a57600182026001905f5b5f8211156068578101908302848302900491" ++
        "6001019190604d565b9093900492505050366060146088573661019a573461019a575f5260205ff35b341061019a5760" ++
        "0154600101600155600354806004026004013381556001015f358155600101602035815560010160403590553360601b" ++
        "5f5260605f60143760745fa0600101600355005b6003546002548082038060021160e7575060025b5f5b818114610129" ++
        "5782810160040260040181607402815460601b8152601401816001015481526020018160020154815260200190600301" ++
        "54905260010160e9565b910180921461013b5790600255610146565b90505f6002555f6003555b5f54807fffffffffff" ++
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffff141561017357505f5b600154600182820111610188" ++
        "5750505f61018e565b01600190035b5f555f6001556074025ff35b5f5ffd",
);

/// Nonce of every deployed system contract: a contract created after
/// EIP-161 starts at nonce 1.
pub const DEPLOYED_NONCE: u64 = 1;

pub const SystemContract = struct {
    name: []const u8,
    address: primitives.Address,
    code: []const u8,
    /// First fork whose block processing calls the contract.
    fork: primitives.Hardfork,
};

/// Every system contract a chain needs through Osaka. Osaka adds none.
pub const ALL = [_]SystemContract{
    .{ .name = "BEACON_ROOTS_ADDRESS", .address = BEACON_ROOTS_ADDRESS, .code = &BEACON_ROOTS_CODE, .fork = .CANCUN },
    .{ .name = "HISTORY_STORAGE_ADDRESS", .address = HISTORY_STORAGE_ADDRESS, .code = &HISTORY_STORAGE_CODE, .fork = .PRAGUE },
    .{ .name = "WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS", .address = WITHDRAWAL_REQUESTS_ADDRESS, .code = &WITHDRAWAL_REQUESTS_CODE, .fork = .PRAGUE },
    .{ .name = "CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS", .address = CONSOLIDATION_REQUESTS_ADDRESS, .code = &CONSOLIDATION_REQUESTS_CODE, .fork = .PRAGUE },
};

/// Installs every system contract into a genesis state: canonical runtime
/// bytecode, nonce 1, no balance, empty storage. Preserves any pre-existing code.
///
/// Call it only while building a genesis allocation the node owns. It must
/// not run against a user-supplied genesis file or forked remote state, where
/// the chain itself decides whether the contracts exist.
pub fn installGenesis(sm: *state_manager.StateManager) !void {
    for (ALL) |contract| {
        if ((try sm.getCode(contract.address)).len != 0) continue;
        try sm.initAccount(contract.address, 0);
        try sm.setNonce(contract.address, DEPLOYED_NONCE);
        try sm.setCode(contract.address, contract.code);
    }
}

/// Installs every system contract whose activation fork is scheduled by `config`,
/// preserving any pre-existing code.
pub fn installScheduled(sm: *state_manager.StateManager, config: hardfork_schedule.ChainConfig) !void {
    for (ALL) |contract| {
        const needed = switch (contract.fork) {
            .CANCUN => config.hasCancun(),
            .PRAGUE => config.hasPrague(),
            else => true,
        };
        if (!needed) continue;
        if ((try sm.getCode(contract.address)).len != 0) continue;
        try sm.initAccount(contract.address, 0);
        try sm.setNonce(contract.address, DEPLOYED_NONCE);
        try sm.setCode(contract.address, contract.code);
    }
}

/// Returns the system contract deployed at `address`, if any.
pub fn find(address: primitives.Address) ?SystemContract {
    for (ALL) |contract| {
        if (contract.address.equals(address)) return contract;
    }
    return null;
}

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}
