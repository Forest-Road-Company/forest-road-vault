use anchor_lang::prelude::*;
use anchor_spl::associated_token::get_associated_token_address;
use anchor_spl::token::{self, Token, TokenAccount, Transfer};

use crate::constants::*;
use crate::error::VaultError;
use crate::events::*;
use crate::math;
use crate::state::{Config, Position};

// ── treasury authority ──────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct DrawToTreasury<'info> {
    pub treasury_authority: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = treasury_authority)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [POSITION_SEED, position.owner.as_ref()], bump = position.bump)]
    pub position: Account<'info, Position>,
    #[account(mut, seeds = [VAULT_SEED], bump, address = config.vault_ata)]
    pub vault_ata: Account<'info, TokenAccount>,
    /// The pinned destination. Not caller-chosen: rotating it is an admin act with its own event.
    #[account(
        mut,
        address = config.treasury_ata @ VaultError::WrongTokenAccount,
        constraint = treasury_ata.mint == config.usdc_mint @ VaultError::WrongMint,
        constraint = treasury_ata.owner == config.treasury_authority @ VaultError::WrongTokenAccount
    )]
    pub treasury_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

pub fn handle_draw_to_treasury(ctx: Context<DrawToTreasury>, amount: u64) -> Result<()> {
    require!(amount > 0, VaultError::ZeroAmount);
    let now = Clock::get()?.unix_timestamp;
    let config = &mut ctx.accounts.config;
    let position = &mut ctx.accounts.position;
    config.require_version()?;
    position.require_version()?;
    require!(!config.paused, VaultError::Paused);
    // A curator's notice fixes the exposure available for their exit. The treasury may return an
    // existing draw during notice, but it may not create a new one that blocks or impairs the exit.
    require!(position.notice_requested_at == 0, VaultError::NoticePending);
    let drawn_after = config
        .drawn
        .checked_add(amount)
        .ok_or(VaultError::Overflow)?;
    require!(
        drawn_after <= config.total_principal,
        VaultError::DrawExceedsPrincipal
    );
    let position_drawn_after = position
        .drawn
        .checked_add(amount)
        .ok_or(VaultError::Overflow)?;
    require!(
        position_drawn_after <= position.principal,
        VaultError::DrawExceedsPrincipal
    );
    require!(
        ctx.accounts.vault_ata.amount >= amount,
        VaultError::InsufficientVaultLiquidity
    );
    let bump = config.bump;
    let seeds: &[&[u8]] = &[CONFIG_SEED, &[bump]];
    token::transfer(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.key(),
            Transfer {
                from: ctx.accounts.vault_ata.to_account_info(),
                to: ctx.accounts.treasury_ata.to_account_info(),
                authority: config.to_account_info(),
            },
            &[seeds],
        ),
        amount,
    )?;
    config.drawn = drawn_after;
    position.drawn = position_drawn_after;
    emit!(TreasuryDraw {
        owner: position.owner,
        amount,
        drawn_after,
        position_drawn_after,
        ts: now
    });
    Ok(())
}

#[derive(Accounts)]
pub struct TreasuryPay<'info> {
    pub treasury_authority: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = treasury_authority)]
    pub config: Account<'info, Config>,
    /// Any token account of the right mint that the treasury authority controls.
    #[account(
        mut,
        constraint = source.mint == config.usdc_mint @ VaultError::WrongMint,
        constraint = source.owner == treasury_authority.key() @ VaultError::WrongTokenAccount
    )]
    pub source: Account<'info, TokenAccount>,
    /// The vault (for a principal return) or the coupon pool (for funding), checked per handler.
    #[account(mut)]
    pub destination: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

fn pay_in(ctx: &Context<TreasuryPay>, amount: u64) -> Result<()> {
    token::transfer(
        CpiContext::new(
            ctx.accounts.token_program.key(),
            Transfer {
                from: ctx.accounts.source.to_account_info(),
                to: ctx.accounts.destination.to_account_info(),
                authority: ctx.accounts.treasury_authority.to_account_info(),
            },
        ),
        amount,
    )
}

#[derive(Accounts)]
pub struct ReturnPrincipal<'info> {
    pub treasury_authority: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = treasury_authority)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [POSITION_SEED, position.owner.as_ref()], bump = position.bump)]
    pub position: Account<'info, Position>,
    #[account(
        mut,
        constraint = source.mint == config.usdc_mint @ VaultError::WrongMint,
        constraint = source.owner == treasury_authority.key() @ VaultError::WrongTokenAccount
    )]
    pub source: Account<'info, TokenAccount>,
    #[account(mut, seeds = [VAULT_SEED], bump, address = config.vault_ata)]
    pub vault_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

pub fn handle_return_principal(ctx: Context<ReturnPrincipal>, amount: u64) -> Result<()> {
    require!(amount > 0, VaultError::ZeroAmount);
    let now = Clock::get()?.unix_timestamp;
    ctx.accounts.config.require_version()?;
    ctx.accounts.position.require_version()?;
    require!(
        amount <= ctx.accounts.position.drawn,
        VaultError::ReturnExceedsDrawn
    );
    token::transfer(
        CpiContext::new(
            ctx.accounts.token_program.key(),
            Transfer {
                from: ctx.accounts.source.to_account_info(),
                to: ctx.accounts.vault_ata.to_account_info(),
                authority: ctx.accounts.treasury_authority.to_account_info(),
            },
        ),
        amount,
    )?;
    let config = &mut ctx.accounts.config;
    let position = &mut ctx.accounts.position;
    config.drawn -= amount;
    position.drawn -= amount;
    emit!(PrincipalReturned {
        owner: position.owner,
        amount,
        drawn_after: config.drawn,
        position_drawn_after: position.drawn,
        ts: now
    });
    Ok(())
}

pub fn handle_fund_coupons(ctx: Context<TreasuryPay>, amount: u64) -> Result<()> {
    require!(amount > 0, VaultError::ZeroAmount);
    require!(
        ctx.accounts.destination.key() == ctx.accounts.config.coupon_ata,
        VaultError::WrongTokenAccount
    );
    let now = Clock::get()?.unix_timestamp;
    ctx.accounts.config.require_version()?;
    pay_in(&ctx, amount)?;
    let config = &mut ctx.accounts.config;
    config.coupon_funded = config
        .coupon_funded
        .checked_add(amount)
        .ok_or(VaultError::Overflow)?;
    emit!(CouponsFunded {
        amount,
        coupon_funded: config.coupon_funded,
        ts: now
    });
    Ok(())
}

#[derive(Accounts)]
pub struct SweepCoupons<'info> {
    pub treasury_authority: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = treasury_authority)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [COUPON_SEED], bump, address = config.coupon_ata)]
    pub coupon_ata: Account<'info, TokenAccount>,
    /// The pinned destination, as for draws.
    #[account(
        mut,
        address = config.treasury_ata @ VaultError::WrongTokenAccount,
        constraint = treasury_ata.mint == config.usdc_mint @ VaultError::WrongMint,
        constraint = treasury_ata.owner == config.treasury_authority @ VaultError::WrongTokenAccount
    )]
    pub treasury_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

/// Recovers only tokens transferred directly to the coupon PDA. Once coupon funding is credited,
/// it cannot be unfunded: this remains safe even before an untouched position checkpoints coupon
/// that it has already earned.
pub fn handle_sweep_coupons(ctx: Context<SweepCoupons>, amount: u64) -> Result<()> {
    require!(amount > 0, VaultError::ZeroAmount);
    let now = Clock::get()?.unix_timestamp;
    let config = &mut ctx.accounts.config;
    config.require_version()?;
    let accounted = config
        .coupon_funded
        .checked_sub(config.coupon_paid)
        .ok_or(VaultError::AccountingMismatch)?;
    let physical = ctx.accounts.coupon_ata.amount;
    require!(physical >= accounted, VaultError::AccountingMismatch);
    let unaccounted_surplus = physical - accounted;
    require!(
        amount <= unaccounted_surplus,
        VaultError::CouponLiabilityReserved
    );
    let bump = config.bump;
    let seeds: &[&[u8]] = &[CONFIG_SEED, &[bump]];
    token::transfer(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.key(),
            Transfer {
                from: ctx.accounts.coupon_ata.to_account_info(),
                to: ctx.accounts.treasury_ata.to_account_info(),
                authority: config.to_account_info(),
            },
            &[seeds],
        ),
        amount,
    )?;
    emit!(CouponsSwept {
        amount,
        coupon_funded: config.coupon_funded,
        ts: now
    });
    Ok(())
}

/// Returns accounted coupon funding to the pinned treasury only after the vault has completely
/// wound down. This is intentionally separate from the donation sweep: while any Position account
/// exists, credited funding remains unavailable even if no coupon has been checkpointed yet.
pub fn handle_withdraw_unused_coupon_funding(
    ctx: Context<SweepCoupons>,
    amount: u64,
) -> Result<()> {
    require!(amount > 0, VaultError::ZeroAmount);
    let now = Clock::get()?.unix_timestamp;
    let config = &mut ctx.accounts.config;
    config.require_version()?;
    require!(
        config.positions == 0 && config.coupon_owed_total == 0,
        VaultError::VaultNotEmpty
    );
    let accounted = config
        .coupon_funded
        .checked_sub(config.coupon_paid)
        .ok_or(VaultError::AccountingMismatch)?;
    let physical = ctx.accounts.coupon_ata.amount;
    require!(physical >= accounted, VaultError::AccountingMismatch);
    require!(amount <= accounted, VaultError::CouponLiabilityReserved);
    let funded_after = config
        .coupon_funded
        .checked_sub(amount)
        .ok_or(VaultError::AccountingMismatch)?;
    let seeds: &[&[u8]] = &[CONFIG_SEED, &[config.bump]];
    token::transfer(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.key(),
            Transfer {
                from: ctx.accounts.coupon_ata.to_account_info(),
                to: ctx.accounts.treasury_ata.to_account_info(),
                authority: config.to_account_info(),
            },
            &[seeds],
        ),
        amount,
    )?;
    config.coupon_funded = funded_after;
    emit!(CouponFundingWithdrawn {
        amount,
        coupon_funded: funded_after,
        ts: now
    });
    Ok(())
}

#[derive(Accounts)]
pub struct SweepPrincipalSurplus<'info> {
    pub treasury_authority: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = treasury_authority)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [VAULT_SEED], bump, address = config.vault_ata)]
    pub vault_ata: Account<'info, TokenAccount>,
    #[account(
        mut,
        address = config.treasury_ata @ VaultError::WrongTokenAccount,
        constraint = treasury_ata.mint == config.usdc_mint @ VaultError::WrongMint,
        constraint = treasury_ata.owner == config.treasury_authority @ VaultError::WrongTokenAccount
    )]
    pub treasury_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

/// Recovers tokens transferred directly to the principal PDA without touching curator principal.
pub fn handle_sweep_principal_surplus(
    ctx: Context<SweepPrincipalSurplus>,
    amount: u64,
) -> Result<()> {
    require!(amount > 0, VaultError::ZeroAmount);
    let now = Clock::get()?.unix_timestamp;
    let config = &ctx.accounts.config;
    config.require_version()?;
    let accounted = config
        .total_principal
        .checked_sub(config.drawn)
        .ok_or(VaultError::AccountingMismatch)?;
    require!(
        ctx.accounts.vault_ata.amount >= accounted,
        VaultError::AccountingMismatch
    );
    let surplus = ctx.accounts.vault_ata.amount - accounted;
    require!(amount <= surplus, VaultError::SweepExceedsPool);
    let seeds: &[&[u8]] = &[CONFIG_SEED, &[config.bump]];
    token::transfer(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.key(),
            Transfer {
                from: ctx.accounts.vault_ata.to_account_info(),
                to: ctx.accounts.treasury_ata.to_account_info(),
                authority: config.to_account_info(),
            },
            &[seeds],
        ),
        amount,
    )?;
    emit!(PrincipalSurplusSwept { amount, ts: now });
    Ok(())
}

// ── permissionless coupon crank ─────────────────────────────────────────────

#[derive(Accounts)]
pub struct PayCoupon<'info> {
    /// Anyone. The keeper in practice; the curator or a bystander can crank their own row.
    pub cranker: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [POSITION_SEED, position.owner.as_ref()], bump = position.bump)]
    pub position: Account<'info, Position>,
    #[account(mut, seeds = [COUPON_SEED], bump, address = config.coupon_ata)]
    pub coupon_ata: Account<'info, TokenAccount>,
    /// The owner's own token account for the mint; the payout goes nowhere else.
    #[account(
        mut,
        constraint = owner_ata.mint == config.usdc_mint @ VaultError::WrongMint,
        constraint = owner_ata.owner == position.owner @ VaultError::WrongTokenAccount
    )]
    pub owner_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

pub fn handle_pay_coupon(ctx: Context<PayCoupon>) -> Result<()> {
    require!(
        ctx.accounts.owner_ata.key()
            == get_associated_token_address(
                &ctx.accounts.position.owner,
                &ctx.accounts.config.usdc_mint
            ),
        VaultError::WrongAssociatedTokenAccount
    );
    let now = Clock::get()?.unix_timestamp;
    let boundary = math::month_start(now);
    let config = &mut ctx.accounts.config;
    let position = &mut ctx.accounts.position;
    config.require_version()?;
    position.require_version()?;
    // Once per calendar month, at or after its start, and only for coupon earned through that
    // completed boundary. Later earned coupon remains owed for the next boundary.
    require!(!position.payout_halted, VaultError::PayoutHalted);
    require!(
        boundary > position.coupon_paid_through,
        VaultError::NothingDue
    );
    if position.coupon_accrued_through != 0 {
        config.mature_coupon(position, boundary)?;
    }
    let amount = position.coupon_payable;
    require!(amount > 0, VaultError::NothingDue);
    let accounted = config
        .coupon_funded
        .checked_sub(config.coupon_paid)
        .ok_or(VaultError::AccountingMismatch)?;
    require!(
        ctx.accounts.coupon_ata.amount >= accounted,
        VaultError::AccountingMismatch
    );
    require!(
        ctx.accounts.coupon_ata.amount >= amount,
        VaultError::InsufficientCouponPool
    );
    // A direct transfer into the pool is harmless. Adopt only the portion needed for this payment
    // into the funding counter so `coupon_paid <= coupon_funded` remains true.
    let surplus_recognized = amount.saturating_sub(accounted);
    config.coupon_funded = config
        .coupon_funded
        .checked_add(surplus_recognized)
        .ok_or(VaultError::Overflow)?;
    let bump = config.bump;
    let seeds: &[&[u8]] = &[CONFIG_SEED, &[bump]];
    token::transfer(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.key(),
            Transfer {
                from: ctx.accounts.coupon_ata.to_account_info(),
                to: ctx.accounts.owner_ata.to_account_info(),
                authority: config.to_account_info(),
            },
            &[seeds],
        ),
        amount,
    )?;
    position.coupon_owed = position
        .coupon_owed
        .checked_sub(amount)
        .ok_or(VaultError::AccountingMismatch)?;
    position.coupon_payable = 0;
    position.coupon_paid_through = boundary;
    config.coupon_owed_total = config
        .coupon_owed_total
        .checked_sub(amount)
        .ok_or(VaultError::AccountingMismatch)?;
    config.coupon_paid = config
        .coupon_paid
        .checked_add(amount)
        .ok_or(VaultError::Overflow)?;
    emit!(CouponPaid {
        owner: position.owner,
        period_end: boundary,
        amount,
        coupon_paid: config.coupon_paid,
        coupon_owed_after: position.coupon_owed,
        coupon_payable_after: position.coupon_payable,
        coupon_accrued_through: position.coupon_accrued_through,
        surplus_recognized,
        ts: now
    });
    Ok(())
}

// ── loss recognition (admin, only when principal is at risk) ────────────────

#[derive(Accounts)]
pub struct RecordLoss<'info> {
    pub admin: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = admin)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [POSITION_SEED, position.owner.as_ref()], bump = position.bump)]
    pub position: Account<'info, Position>,
}

pub fn handle_record_loss(
    ctx: Context<RecordLoss>,
    amount: u64,
    evidence_hash: [u8; 32],
) -> Result<()> {
    require!(amount > 0, VaultError::ZeroAmount);
    require!(evidence_hash != [0u8; 32], VaultError::ZeroHash);
    let now = Clock::get()?.unix_timestamp;
    let config = &mut ctx.accounts.config;
    let position = &mut ctx.accounts.position;
    config.require_version()?;
    position.require_version()?;
    require!(config.principal_at_risk, VaultError::PrincipalNotAtRisk);
    require!(
        amount <= position.principal,
        VaultError::LossExceedsPrincipal
    );
    // A position can absorb only capital explicitly drawn from that position. This prevents an
    // administrator from charging one curator for capital deployed from another curator's row.
    require!(amount <= position.drawn, VaultError::LossExceedsDrawn);
    config.checkpoint_coupon(position, now)?;
    position.principal -= amount;
    position.drawn -= amount;
    position.losses_recorded = position
        .losses_recorded
        .checked_add(amount)
        .ok_or(VaultError::Overflow)?;
    config.total_principal -= amount;
    config.drawn -= amount;
    emit!(LossRecorded {
        owner: position.owner,
        amount,
        principal_after: position.principal,
        position_drawn_after: position.drawn,
        coupon_owed: position.coupon_owed,
        coupon_payable: position.coupon_payable,
        coupon_accrued_through: position.coupon_accrued_through,
        evidence_hash,
        ts: now,
    });
    Ok(())
}
