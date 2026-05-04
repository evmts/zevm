const primitives = @import("primitives");

pub const MAINNET_CHAIN_CONFIG = ChainConfig{};

pub const ChainConfig = struct {
    homestead_block: u64 = 1_150_000,
    dao_block: u64 = 1_920_000,
    tangerine_whistle_block: u64 = 2_463_000,
    spurious_dragon_block: u64 = 2_675_000,
    byzantium_block: u64 = 4_370_000,
    constantinople_block: u64 = 7_280_000,
    petersburg_block: u64 = 7_280_000,
    istanbul_block: u64 = 9_069_000,
    muir_glacier_block: u64 = 9_200_000,
    berlin_block: u64 = 12_244_000,
    london_block: u64 = 12_965_000,
    arrow_glacier_block: u64 = 13_773_000,
    gray_glacier_block: u64 = 15_050_000,
    merge_block: u64 = 15_537_394,
    shanghai_timestamp: u64 = 1_681_338_455,
    cancun_timestamp: u64 = 1_710_338_135,
    prague_timestamp: u64 = 1_746_612_311,
    osaka_timestamp: u64 = 1_764_798_551,
    seconds_per_slot: u64 = 12,
};

pub fn resolveHardfork(block_number: u64, timestamp: u64) primitives.Hardfork {
    return resolveHardforkWithConfig(MAINNET_CHAIN_CONFIG, block_number, timestamp);
}

pub fn resolveHardforkWithConfig(config: ChainConfig, block_number: u64, timestamp: u64) primitives.Hardfork {
    if (timestamp >= config.osaka_timestamp) return .OSAKA;
    if (timestamp >= config.prague_timestamp) return .PRAGUE;
    if (timestamp >= config.cancun_timestamp) return .CANCUN;
    if (timestamp >= config.shanghai_timestamp) return .SHANGHAI;
    if (block_number >= config.merge_block) return .MERGE;
    if (block_number >= config.gray_glacier_block) return .GRAY_GLACIER;
    if (block_number >= config.arrow_glacier_block) return .ARROW_GLACIER;
    if (block_number >= config.london_block) return .LONDON;
    if (block_number >= config.berlin_block) return .BERLIN;
    if (block_number >= config.muir_glacier_block) return .MUIR_GLACIER;
    if (block_number >= config.istanbul_block) return .ISTANBUL;
    if (block_number >= config.petersburg_block) return .PETERSBURG;
    if (block_number >= config.constantinople_block) return .CONSTANTINOPLE;
    if (block_number >= config.byzantium_block) return .BYZANTIUM;
    if (block_number >= config.spurious_dragon_block) return .SPURIOUS_DRAGON;
    if (block_number >= config.tangerine_whistle_block) return .TANGERINE_WHISTLE;
    if (block_number >= config.dao_block) return .DAO;
    if (block_number >= config.homestead_block) return .HOMESTEAD;
    return .FRONTIER;
}
