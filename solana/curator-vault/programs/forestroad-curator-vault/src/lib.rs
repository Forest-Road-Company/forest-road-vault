//! Curator Subscription Vault (Forest Road Vault, ADR-0039 draft).
//!
//! A subscription ledger and settlement escrow for bilateral, off-chain curator agreements:
//! allowlisted deposits of USDC, a principal ledger with lock and notice timers, monthly coupons
//! paid from a separately funded pool by a permissionless crank, and explicit, capped treasury
//! draws. It promises no yield; it computes the amount the agreement specifies from a rate the
//! admin sets in forward-only epochs. Positions are program accounts with no transfer path and
//! no token. See docs/curator-vault in the ForestRoadVault repository for the specification.

pub mod constants;
pub mod error;
pub mod events;
pub mod instructions;
pub mod math;
pub mod state;

use anchor_lang::prelude::*;

pub use constants::*;
pub use instructions::*;
pub use state::*;

declare_id!("3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh");

#[program]
pub mod forestroad_curator_vault {
    use super::*;

    // admin
    pub fn initialize(ctx: Context<Initialize>, params: InitializeParams) -> Result<()> {
        instructions::admin::handle_initialize(ctx, params)
    }
    pub fn set_rate(ctx: Context<AdminOnly>, bps: u16, start_ts: i64) -> Result<()> {
        instructions::admin::handle_set_rate(ctx, bps, start_ts)
    }
    pub fn set_terms(
        ctx: Context<AdminOnly>,
        lock_seconds: u64,
        notice_seconds: u64,
    ) -> Result<()> {
        instructions::admin::handle_set_terms(ctx, lock_seconds, notice_seconds)
    }
    pub fn set_authorities(
        ctx: Context<SetAuthorities>,
        allowlist_authority: Pubkey,
        treasury_authority: Pubkey,
        emergency_authority: Pubkey,
    ) -> Result<()> {
        instructions::admin::handle_set_authorities(
            ctx,
            allowlist_authority,
            treasury_authority,
            emergency_authority,
        )
    }
    pub fn set_paused(ctx: Context<AdminOnly>, paused: bool) -> Result<()> {
        instructions::admin::handle_set_paused(ctx, paused)
    }
    pub fn propose_admin(ctx: Context<AdminOnly>, new_admin: Pubkey) -> Result<()> {
        instructions::admin::handle_propose_admin(ctx, new_admin)
    }
    pub fn accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
        instructions::admin::handle_accept_admin(ctx)
    }
    pub fn emergency_pause(ctx: Context<EmergencyOnly>) -> Result<()> {
        instructions::admin::handle_emergency_pause(ctx)
    }

    // allowlist authority
    pub fn allowlist(ctx: Context<Allowlist>, agreement_hash: [u8; 32]) -> Result<()> {
        instructions::curator::handle_allowlist(ctx, agreement_hash)
    }
    pub fn revoke_allowlist(ctx: Context<RevokeAllowlist>) -> Result<()> {
        instructions::curator::handle_revoke_allowlist(ctx)
    }
    pub fn set_payout_halt(ctx: Context<RevokeAllowlist>, halted: bool) -> Result<()> {
        instructions::curator::handle_set_payout_halt(ctx, halted)
    }
    pub fn emergency_halt(ctx: Context<EmergencyHalt>) -> Result<()> {
        instructions::curator::handle_emergency_halt(ctx)
    }

    // curator
    pub fn deposit(ctx: Context<CuratorTransfer>, amount: u64) -> Result<()> {
        instructions::curator::handle_deposit(ctx, amount)
    }
    pub fn request_withdrawal(ctx: Context<CuratorAction>) -> Result<()> {
        instructions::curator::handle_request_withdrawal(ctx)
    }
    pub fn cancel_withdrawal(ctx: Context<CuratorAction>) -> Result<()> {
        instructions::curator::handle_cancel_withdrawal(ctx)
    }
    pub fn withdraw(ctx: Context<CuratorTransfer>, amount: u64) -> Result<()> {
        instructions::curator::handle_withdraw(ctx, amount)
    }
    pub fn close_position(ctx: Context<ClosePosition>) -> Result<()> {
        instructions::curator::handle_close_position(ctx)
    }

    // treasury authority
    pub fn draw_to_treasury(ctx: Context<DrawToTreasury>, amount: u64) -> Result<()> {
        instructions::treasury::handle_draw_to_treasury(ctx, amount)
    }
    pub fn return_principal(ctx: Context<ReturnPrincipal>, amount: u64) -> Result<()> {
        instructions::treasury::handle_return_principal(ctx, amount)
    }
    pub fn fund_coupons(ctx: Context<TreasuryPay>, amount: u64) -> Result<()> {
        instructions::treasury::handle_fund_coupons(ctx, amount)
    }
    pub fn sweep_coupons(ctx: Context<SweepCoupons>, amount: u64) -> Result<()> {
        instructions::treasury::handle_sweep_coupons(ctx, amount)
    }
    pub fn withdraw_unused_coupon_funding(ctx: Context<SweepCoupons>, amount: u64) -> Result<()> {
        instructions::treasury::handle_withdraw_unused_coupon_funding(ctx, amount)
    }
    pub fn sweep_principal_surplus(ctx: Context<SweepPrincipalSurplus>, amount: u64) -> Result<()> {
        instructions::treasury::handle_sweep_principal_surplus(ctx, amount)
    }

    // anyone
    pub fn pay_coupon(ctx: Context<PayCoupon>) -> Result<()> {
        instructions::treasury::handle_pay_coupon(ctx)
    }

    // admin, only when principal is at risk
    pub fn record_loss(
        ctx: Context<RecordLoss>,
        amount: u64,
        evidence_hash: [u8; 32],
    ) -> Result<()> {
        instructions::treasury::handle_record_loss(ctx, amount, evidence_hash)
    }
}
