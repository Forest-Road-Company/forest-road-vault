use anchor_lang::prelude::*;

#[constant]
pub const CONFIG_SEED: &[u8] = b"config";
#[constant]
pub const VAULT_SEED: &[u8] = b"vault";
#[constant]
pub const COUPON_SEED: &[u8] = b"coupon";
#[constant]
pub const POSITION_SEED: &[u8] = b"position";

/// Account layout understood by this program. Reserved bytes let later versions add fields
/// without forcing every curator to exit into a replacement program first.
#[constant]
pub const ACCOUNT_VERSION: u8 = 1;
pub const CONFIG_RESERVED_BYTES: usize = 128;
pub const POSITION_RESERVED_BYTES: usize = 64;

/// Terms bounds: one day to two years, for both the lock and the notice.
#[constant]
pub const MIN_TERM_SECONDS: u64 = 86_400;
#[constant]
pub const MAX_TERM_SECONDS: u64 = 730 * 86_400;
/// Rates are basis points on Actual/360; 100% is the ceiling, not a target.
#[constant]
pub const MAX_RATE_BPS: u16 = 10_000;
/// Day-count code for Actual/360, the only convention this version implements.
#[constant]
pub const DAY_COUNT_ACTUAL_360: u8 = 0;
