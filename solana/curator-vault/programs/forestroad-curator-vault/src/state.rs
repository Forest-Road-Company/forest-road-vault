use anchor_lang::prelude::*;

use crate::error::VaultError;
use crate::math;
use crate::{ACCOUNT_VERSION, CONFIG_RESERVED_BYTES, POSITION_RESERVED_BYTES};

/// One rate epoch: `bps` applies from `start_ts` until the next epoch's start.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default, InitSpace, PartialEq, Eq)]
pub struct RateEpoch {
    pub start_ts: i64,
    pub bps: u16,
}

impl From<RateEpoch> for math::RateEpoch {
    fn from(e: RateEpoch) -> Self {
        math::RateEpoch {
            start_ts: e.start_ts,
            bps: e.bps,
        }
    }
}

/// Vault configuration and running totals. One per program deployment.
#[account]
#[derive(InitSpace)]
pub struct Config {
    pub version: u8,
    pub admin: Pubkey,
    pub pending_admin: Pubkey,
    pub allowlist_authority: Pubkey,
    pub treasury_authority: Pubkey,
    /// A hot key with one-way powers only: it may pause or halt, never clear either flag.
    pub emergency_authority: Pubkey,
    pub usdc_mint: Pubkey,
    /// Principal, a program-owned token account at seeds ["vault"].
    pub vault_ata: Pubkey,
    /// Coupon pool, a program-owned token account at seeds ["coupon"].
    pub coupon_ata: Pubkey,
    /// Destination of treasury draws; a Forest Road token account, rotated by the admin only.
    pub treasury_ata: Pubkey,
    pub lock_seconds: u64,
    pub notice_seconds: u64,
    pub day_count: u8,
    pub principal_at_risk: bool,
    pub paused: bool,
    pub rate_epochs: [RateEpoch; math::MAX_RATE_EPOCHS],
    pub rate_epoch_count: u8,
    pub total_principal: u64,
    pub drawn: u64,
    pub coupon_funded: u64,
    pub coupon_paid: u64,
    /// Sum of every position's accrued but unpaid whole coupon units.
    pub coupon_owed_total: u64,
    pub positions: u32,
    pub bump: u8,
    pub reserved: [u8; CONFIG_RESERVED_BYTES],
}

impl Config {
    pub fn epochs(&self) -> Vec<math::RateEpoch> {
        self.rate_epochs[..self.rate_epoch_count as usize]
            .iter()
            .map(|e| (*e).into())
            .collect()
    }

    /// Settles a position's coupon accrual through `to`, carrying the floored remainder and the
    /// O(1) aggregate liability. This does not make post-boundary accrual payable early.
    pub fn accrue(&mut self, position: &mut Position, to: i64) -> Result<()> {
        if to <= position.coupon_accrued_through {
            return Ok(());
        }
        let (whole, remainder) = math::accrue(
            position.principal,
            &self.epochs(),
            position.coupon_accrued_through,
            to,
            position.coupon_remainder,
        )
        .ok_or(VaultError::Overflow)?;
        position.coupon_owed = position
            .coupon_owed
            .checked_add(whole)
            .ok_or(VaultError::Overflow)?;
        self.coupon_owed_total = self
            .coupon_owed_total
            .checked_add(whole)
            .ok_or(VaultError::Overflow)?;
        position.coupon_remainder = remainder;
        position.coupon_accrued_through = to;
        Ok(())
    }

    /// Checkpoints a principal change at `to`. Coupon through the latest completed UTC month is
    /// made payable; coupon after that boundary remains earned and owed for the next month.
    pub fn checkpoint_coupon(&mut self, position: &mut Position, to: i64) -> Result<()> {
        if to <= position.coupon_accrued_through {
            return Ok(());
        }
        let boundary = math::month_start(to);
        if position.coupon_accrued_through < boundary {
            self.accrue(position, boundary)?;
            position.coupon_payable = position.coupon_owed;
        }
        self.accrue(position, to)
    }

    /// Advances a position to a completed month boundary and marks all coupon earned through it
    /// payable. Existing arrears remain payable as well.
    pub fn mature_coupon(&mut self, position: &mut Position, boundary: i64) -> Result<()> {
        if position.coupon_accrued_through <= boundary {
            self.accrue(position, boundary)?;
            position.coupon_payable = position.coupon_owed;
        }
        Ok(())
    }

    pub fn require_version(&self) -> Result<()> {
        require!(
            self.version == ACCOUNT_VERSION,
            VaultError::UnsupportedVersion
        );
        Ok(())
    }
}

/// One curator's subscription. Non-transferable by construction: there is no instruction that
/// changes `owner`, and no token represents it.
#[account]
#[derive(InitSpace)]
pub struct Position {
    pub version: u8,
    pub owner: Pubkey,
    /// Hash of the executed agreement, set when the wallet is allowlisted.
    pub agreement_hash: [u8; 32],
    pub allowlisted: bool,
    /// Terms snapshotted when a zero-principal position receives new principal.
    pub lock_seconds: u64,
    pub notice_seconds: u64,
    /// Live principal in USDC base units.
    pub principal: u64,
    /// Principal from this position currently deployed to the treasury.
    pub drawn: u64,
    pub deposited_at: i64,
    pub lock_end: i64,
    pub notice_requested_at: i64,
    pub withdrawal_eligible_at: i64,
    pub coupon_accrued_through: i64,
    pub coupon_paid_through: i64,
    pub coupon_owed: u64,
    /// Portion of `coupon_owed` earned through a completed month and payable now.
    pub coupon_payable: u64,
    pub coupon_remainder: u128,
    pub losses_recorded: u64,
    /// Set by the allowlist authority on a screening hit: the crank refuses this position while
    /// accrual continues and the amount stays owed. Withdrawals are not affected by this flag;
    /// whether they should be is counsel's question (spec section 3.4).
    pub payout_halted: bool,
    pub bump: u8,
    pub reserved: [u8; POSITION_RESERVED_BYTES],
}

impl Position {
    pub fn require_version(&self) -> Result<()> {
        require!(
            self.version == ACCOUNT_VERSION,
            VaultError::UnsupportedVersion
        );
        Ok(())
    }
}
