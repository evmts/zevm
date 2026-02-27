const std = @import("std");

pub const MiningConfigType = enum {
    auto,
    manual,
    interval,
};

pub const MiningConfig = union(MiningConfigType) {
    auto: void,
    manual: void,
    interval: struct {
        block_time: u64,
    },

    pub fn default() MiningConfig {
        return .auto;
    }
};
