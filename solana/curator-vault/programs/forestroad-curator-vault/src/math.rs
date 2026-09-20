//! Pure arithmetic for the curator subscription vault. No Solana dependencies, so it is tested
//! with plain `cargo test` and property tests, and the keeper reimplements it against this file.
//!
//! Conventions (spec section 5.2): rates in basis points, Actual/360, continuous accrual settled
//! at UTC calendar month ends, every division floored in favour of the pool, with the floored
//! remainder carried so that nothing is lost over long horizons.

/// Seconds in the Actual/360 year: 360 days.
pub const YEAR_SECONDS: u128 = 360 * 86_400;
/// Basis-point denominator.
pub const BPS: u128 = 10_000;
/// Denominator of one accrual slice: principal * bps * seconds / (BPS * YEAR_SECONDS).
pub const SLICE_DENOMINATOR: u128 = BPS * YEAR_SECONDS;
/// Bounded epoch history; the agreement does not change rate sixteen times.
pub const MAX_RATE_EPOCHS: usize = 16;

/// One rate epoch: `bps` applies from `start_ts` until the next epoch's start.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RateEpoch {
    pub start_ts: i64,
    pub bps: u16,
}

/// Coupon accrued over `[from, to)` on `principal` across `epochs`, plus the carried remainder.
///
/// Returns `(whole_units, remainder)` where `remainder < SLICE_DENOMINATOR`. The caller stores
/// the remainder and passes it back next time so floors telescope exactly. `epochs` must be
/// sorted by `start_ts`, non-empty, and the first epoch must start at or before `from`.
/// Any slice before the first epoch earns nothing (the vault did not exist).
pub fn accrue(
    principal: u64,
    epochs: &[RateEpoch],
    from: i64,
    to: i64,
    carried_remainder: u128,
) -> Option<(u64, u128)> {
    if to <= from || principal == 0 || epochs.is_empty() {
        return Some((0, carried_remainder));
    }
    let mut numerator: u128 = carried_remainder;
    for (i, epoch) in epochs.iter().enumerate() {
        let slice_start = epoch.start_ts.max(from);
        let slice_end = match epochs.get(i + 1) {
            Some(next) => next.start_ts.min(to),
            None => to,
        };
        if slice_end <= slice_start {
            continue;
        }
        let seconds = (slice_end - slice_start) as u128;
        let add = (principal as u128)
            .checked_mul(epoch.bps as u128)?
            .checked_mul(seconds)?;
        numerator = numerator.checked_add(add)?;
    }
    let whole = numerator / SLICE_DENOMINATOR;
    let remainder = numerator % SLICE_DENOMINATOR;
    if whole > u64::MAX as u128 {
        return None;
    }
    Some((whole as u64, remainder))
}

/// Days since 1970-01-01 for a proleptic Gregorian civil date (Howard Hinnant's algorithm).
pub fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = ((m + 9) % 12) as i64; // March = 0
    let doy = (153 * mp + 2) / 5 + d as i64 - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146_097 + doe - 719_468
}

/// Civil date (y, m, d) from days since 1970-01-01.
pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// 00:00:00 UTC on the first day of the month containing `ts`: the most recent month boundary at
/// or before `ts`. Coupons are paid through this instant.
pub fn month_start(ts: i64) -> i64 {
    let days = ts.div_euclid(86_400);
    let (y, m, _) = civil_from_days(days);
    days_from_civil(y, m, 1) * 86_400
}

/// The first month boundary strictly after `ts`.
pub fn next_month_start(ts: i64) -> i64 {
    let days = ts.div_euclid(86_400);
    let (y, m, _) = civil_from_days(days);
    let (ny, nm) = if m == 12 { (y + 1, 1) } else { (y, m + 1) };
    days_from_civil(ny, nm, 1) * 86_400
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    const USDC: u64 = 1_000_000;

    #[test]
    fn one_year_at_five_percent_is_five_percent_actual_360() {
        // 360 days at 500 bps on 1,000,000 USDC = 50,000 USDC exactly.
        let epochs = [RateEpoch {
            start_ts: 0,
            bps: 500,
        }];
        let (whole, rem) = accrue(1_000_000 * USDC, &epochs, 0, 360 * 86_400, 0).unwrap();
        assert_eq!(whole, 50_000 * USDC);
        assert_eq!(rem, 0);
    }

    #[test]
    fn nothing_before_the_first_epoch_and_nothing_on_empty_ranges() {
        let epochs = [RateEpoch {
            start_ts: 1_000,
            bps: 500,
        }];
        assert_eq!(accrue(USDC, &epochs, 0, 1_000, 0).unwrap(), (0, 0));
        assert_eq!(accrue(USDC, &epochs, 5, 5, 0).unwrap(), (0, 0));
        assert_eq!(accrue(USDC, &epochs, 9, 5, 7).unwrap(), (0, 7));
        assert_eq!(accrue(0, &epochs, 0, 10_000, 3).unwrap(), (0, 3));
    }

    #[test]
    fn a_rate_change_splits_the_slice_at_the_epoch_start() {
        let epochs = [
            RateEpoch {
                start_ts: 0,
                bps: 500,
            },
            RateEpoch {
                start_ts: 180 * 86_400,
                bps: 1_000,
            },
        ];
        let (whole, _) = accrue(1_000_000 * USDC, &epochs, 0, 360 * 86_400, 0).unwrap();
        // half a year at 5% plus half a year at 10% = 7.5% of 1,000,000
        assert_eq!(whole, 75_000 * USDC);
    }

    #[test]
    fn overflow_is_reported_not_wrapped() {
        let epochs = [RateEpoch {
            start_ts: 0,
            bps: 10_000,
        }];
        assert!(accrue(u64::MAX, &epochs, 0, i64::MAX, u128::MAX).is_none());
    }

    #[test]
    fn month_boundaries_match_known_dates() {
        // 2026-09-17T10:42:12Z is 1_789_641_732? Use a computed reference instead of a literal.
        let ts = days_from_civil(2026, 9, 17) * 86_400 + 10 * 3_600 + 42 * 60 + 12;
        assert_eq!(month_start(ts), days_from_civil(2026, 9, 1) * 86_400);
        assert_eq!(next_month_start(ts), days_from_civil(2026, 10, 1) * 86_400);
        let dec = days_from_civil(2026, 12, 31) * 86_400 + 86_399;
        assert_eq!(next_month_start(dec), days_from_civil(2027, 1, 1) * 86_400);
        assert_eq!(
            month_start(days_from_civil(2028, 2, 29) * 86_400),
            days_from_civil(2028, 2, 1) * 86_400
        );
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(civil_from_days(0), (1970, 1, 1));
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(4_000))]

        /// Splitting an interval at any point and carrying the remainder yields the same total as
        /// accruing it in one step: keeper cadence cannot change what is owed.
        #[test]
        fn accrual_is_path_independent(
            principal in 1u64..=1_000_000_000 * 1_000_000u64, // up to 10^9 USDC (10^15 base units)
            bps_a in 1u16..=10_000, bps_b in 1u16..=10_000,
            epoch_b_start in 0i64..=(20 * 365 * 86_400),
            from in 0i64..=(20 * 365 * 86_400), len in 1i64..=(20 * 365 * 86_400),
            cut in 0u32..=1_000_000,
        ) {
            let to = from + len;
            let epochs = [RateEpoch { start_ts: 0, bps: bps_a }, RateEpoch { start_ts: epoch_b_start, bps: bps_b }];
            let epochs: Vec<RateEpoch> = if epoch_b_start == 0 { vec![epochs[1]] } else { epochs.to_vec() };
            let mid = from + ((len as u128 * cut as u128) / 1_000_000u128) as i64;
            let (w1, r1) = accrue(principal, &epochs, from, to, 0).unwrap();
            let (wa, ra) = accrue(principal, &epochs, from, mid, 0).unwrap();
            let (wb, rb) = accrue(principal, &epochs, mid, to, ra).unwrap();
            prop_assert_eq!(w1, wa + wb);
            prop_assert_eq!(r1, rb);
            prop_assert!(r1 < SLICE_DENOMINATOR);
        }

        /// Accrual equals principal * rate * time / (BPS * YEAR), floored, and is monotone in time,
        /// with no overflow for principal up to 10^15 base units over 100 years at 100%.
        #[test]
        fn accrual_is_bounded_and_monotone(
            principal in 1u64..=1_000_000_000 * 1_000_000u64, // 10^15 base units
            bps in 1u16..=10_000,
            from in 0i64..=(100 * 365 * 86_400), len in 0i64..=(100 * 365 * 86_400), extra in 0i64..=86_400 * 400,
        ) {
            let epochs = [RateEpoch { start_ts: 0, bps }];
            let (w, _) = accrue(principal, &epochs, from, from + len, 0).unwrap();
            let bound = (principal as u128) * (bps as u128) * (len as u128) / SLICE_DENOMINATOR;
            prop_assert_eq!(w as u128, bound);
            let (w2, _) = accrue(principal, &epochs, from, from + len + extra, 0).unwrap();
            prop_assert!(w2 >= w);
        }

        /// Civil date round trip for every day from 1970 to 2100 (and beyond, into negatives).
        #[test]
        fn civil_date_round_trips(days in -1_000_000i64..=1_000_000) {
            let (y, m, d) = civil_from_days(days);
            prop_assert!((1..=12).contains(&m));
            prop_assert!((1..=31).contains(&d));
            prop_assert_eq!(days_from_civil(y, m, d), days);
        }

        /// A month start is at or before its input, the next start is strictly after, and the
        /// gap between them is a real month (28 to 31 days).
        #[test]
        fn month_boundaries_bracket_the_timestamp(ts in -2_000_000_000i64..=4_102_444_800) {
            let s = month_start(ts);
            let n = next_month_start(ts);
            prop_assert!(s <= ts);
            prop_assert!(n > ts);
            let days = (n - s) / 86_400;
            prop_assert!((28..=31).contains(&days));
            prop_assert_eq!((n - s) % 86_400, 0);
            prop_assert_eq!(month_start(s), s);
            prop_assert_eq!(month_start(n - 1), s);
        }
    }
}
