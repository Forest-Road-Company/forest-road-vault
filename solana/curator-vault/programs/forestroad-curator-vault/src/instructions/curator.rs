use anchor_lang::prelude::*;
use anchor_spl::associated_token::get_associated_token_address;
use anchor_spl::token::{self, Token, TokenAccount, Transfer};

use crate::constants::*;
use crate::error::VaultError;
use crate::events::*;
use crate::state::{Config, Position};

// ── allowlist (allowlist authority) ─────────────────────────────────────────

#[derive(Accounts)]
pub struct Allowlist<'info> {
    #[account(mut)]
    pub allowlist_authority: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = allowlist_authority)]
    pub config: Account<'info, Config>,
    /// CHECK: the wallet being allowlisted; it signs nothing here and receives a position it can
    /// later close. Only its key is used, as a PDA seed and as the position owner.
    pub owner: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = allowlist_authority,
        space = 8 + Position::INIT_SPACE,
        seeds = [POSITION_SEED, owner.key().as_ref()],
        bump
    )]
    pub position: Account<'info, Position>,
    pub system_program: Program<'info, System>,
}

pub fn handle_allowlist(ctx: Context<Allowlist>, agreement_hash: [u8; 32]) -> Result<()> {
    require!(agreement_hash != [0u8; 32], VaultError::ZeroHash);
    require!(
        ctx.accounts.owner.key() != Pubkey::default(),
        VaultError::ZeroAuthority
    );
    ctx.accounts.config.require_version()?;
    let now = Clock::get()?.unix_timestamp;
    let position = &mut ctx.accounts.position;
    require!(!position.allowlisted, VaultError::AlreadyAllowlisted);
    if position.version == 0 {
        position.version = ACCOUNT_VERSION;
        position.owner = ctx.accounts.owner.key();
        position.bump = ctx.bumps.position;
        ctx.accounts.config.positions = ctx
            .accounts
            .config
            .positions
            .checked_add(1)
            .ok_or(VaultError::Overflow)?;
    } else {
        position.require_version()?;
        require!(
            position.owner == ctx.accounts.owner.key(),
            VaultError::WrongTokenAccount
        );
        let live_obligations = position.principal != 0
            || position.coupon_owed != 0
            || position.notice_requested_at != 0;
        require!(
            !live_obligations || position.agreement_hash == agreement_hash,
            VaultError::AgreementChangeWithBalance
        );
    }
    position.agreement_hash = agreement_hash;
    position.allowlisted = true;
    emit!(Allowlisted {
        owner: position.owner,
        agreement_hash,
        ts: now
    });
    Ok(())
}

#[derive(Accounts)]
pub struct RevokeAllowlist<'info> {
    pub allowlist_authority: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, has_one = allowlist_authority)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [POSITION_SEED, position.owner.as_ref()], bump = position.bump)]
    pub position: Account<'info, Position>,
}

pub fn handle_revoke_allowlist(ctx: Context<RevokeAllowlist>) -> Result<()> {
    ctx.accounts.config.require_version()?;
    ctx.accounts.position.require_version()?;
    let now = Clock::get()?.unix_timestamp;
    let position = &mut ctx.accounts.position;
    position.allowlisted = false;
    emit!(AllowlistRevoked {
        owner: position.owner,
        ts: now
    });
    Ok(())
}

/// A screening hit halts the crank for one position without touching its entitlement: accrual
/// continues and the amount stays owed until the halt is lifted.
pub fn handle_set_payout_halt(ctx: Context<RevokeAllowlist>, halted: bool) -> Result<()> {
    ctx.accounts.config.require_version()?;
    ctx.accounts.position.require_version()?;
    let now = Clock::get()?.unix_timestamp;
    let position = &mut ctx.accounts.position;
    position.payout_halted = halted;
    emit!(PayoutHaltChanged {
        owner: position.owner,
        halted,
        actor: ctx.accounts.allowlist_authority.key(),
        ts: now
    });
    Ok(())
}

#[derive(Accounts)]
pub struct EmergencyHalt<'info> {
    pub emergency_authority: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, has_one = emergency_authority)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [POSITION_SEED, position.owner.as_ref()], bump = position.bump)]
    pub position: Account<'info, Position>,
}

/// One-way hot-key screening brake. Only the allowlist authority may clear the halt.
pub fn handle_emergency_halt(ctx: Context<EmergencyHalt>) -> Result<()> {
    ctx.accounts.config.require_version()?;
    ctx.accounts.position.require_version()?;
    let now = Clock::get()?.unix_timestamp;
    ctx.accounts.position.payout_halted = true;
    emit!(PayoutHaltChanged {
        owner: ctx.accounts.position.owner,
        halted: true,
        actor: ctx.accounts.emergency_authority.key(),
        ts: now
    });
    Ok(())
}

// ── curator actions ─────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct CuratorAction<'info> {
    pub owner: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [POSITION_SEED, owner.key().as_ref()], bump = position.bump, has_one = owner)]
    pub position: Account<'info, Position>,
}

#[derive(Accounts)]
pub struct CuratorTransfer<'info> {
    pub owner: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [POSITION_SEED, owner.key().as_ref()], bump = position.bump, has_one = owner)]
    pub position: Account<'info, Position>,
    #[account(mut, seeds = [VAULT_SEED], bump, address = config.vault_ata)]
    pub vault_ata: Account<'info, TokenAccount>,
    #[account(
        mut,
        constraint = owner_ata.mint == config.usdc_mint @ VaultError::WrongMint,
        constraint = owner_ata.owner == owner.key() @ VaultError::WrongTokenAccount
    )]
    pub owner_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

pub fn handle_deposit(ctx: Context<CuratorTransfer>, amount: u64) -> Result<()> {
    require!(amount > 0, VaultError::ZeroAmount);
    require!(
        ctx.accounts.owner_ata.key()
            == get_associated_token_address(
                &ctx.accounts.owner.key(),
                &ctx.accounts.config.usdc_mint
            ),
        VaultError::WrongAssociatedTokenAccount
    );
    let now = Clock::get()?.unix_timestamp;
    let config = &mut ctx.accounts.config;
    let position = &mut ctx.accounts.position;
    config.require_version()?;
    position.require_version()?;
    require!(!config.paused, VaultError::Paused);
    require!(position.allowlisted, VaultError::NotAllowlisted);
    require!(position.notice_requested_at == 0, VaultError::NoticePending);

    // A zero-principal opening snapshots the current contractual terms. If no older coupon remains,
    // it also starts a fresh monthly payment schedule and discards only sub-USDC-unit remainder
    // that could not be paid or represented after the prior position closed.
    if position.principal == 0 {
        position.lock_seconds = config.lock_seconds;
        position.notice_seconds = config.notice_seconds;
        position.deposited_at = now;
        position.lock_end = 0;
    }
    if position.principal == 0 && position.coupon_owed == 0 {
        position.coupon_accrued_through = now;
        position.coupon_paid_through = crate::math::month_start(now);
        position.coupon_payable = 0;
        position.coupon_remainder = 0;
    }
    config.checkpoint_coupon(position, now)?;

    token::transfer(
        CpiContext::new(
            ctx.accounts.token_program.key(),
            Transfer {
                from: ctx.accounts.owner_ata.to_account_info(),
                to: ctx.accounts.vault_ata.to_account_info(),
                authority: ctx.accounts.owner.to_account_info(),
            },
        ),
        amount,
    )?;

    position.principal = position
        .principal
        .checked_add(amount)
        .ok_or(VaultError::Overflow)?;
    config.total_principal = config
        .total_principal
        .checked_add(amount)
        .ok_or(VaultError::Overflow)?;
    let lock_end = now
        .checked_add(position.lock_seconds as i64)
        .ok_or(VaultError::Overflow)?;
    if lock_end > position.lock_end {
        position.lock_end = lock_end;
    }
    emit!(Deposited {
        owner: position.owner,
        amount,
        principal_after: position.principal,
        lock_end: position.lock_end,
        total_principal: config.total_principal,
        position_drawn: position.drawn,
        coupon_owed: position.coupon_owed,
        coupon_payable: position.coupon_payable,
        coupon_accrued_through: position.coupon_accrued_through,
        ts: now,
    });
    Ok(())
}

pub fn handle_request_withdrawal(ctx: Context<CuratorAction>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let config = &ctx.accounts.config;
    let position = &mut ctx.accounts.position;
    config.require_version()?;
    position.require_version()?;
    require!(position.principal > 0, VaultError::ZeroAmount);
    require!(position.notice_requested_at == 0, VaultError::NoticePending);
    let after_notice = now
        .checked_add(position.notice_seconds as i64)
        .ok_or(VaultError::Overflow)?;
    position.notice_requested_at = now;
    position.withdrawal_eligible_at = after_notice.max(position.lock_end);
    emit!(WithdrawalRequested {
        owner: position.owner,
        eligible_at: position.withdrawal_eligible_at,
        ts: now
    });
    Ok(())
}

pub fn handle_cancel_withdrawal(ctx: Context<CuratorAction>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let position = &mut ctx.accounts.position;
    ctx.accounts.config.require_version()?;
    position.require_version()?;
    require!(position.notice_requested_at != 0, VaultError::NoNotice);
    position.notice_requested_at = 0;
    position.withdrawal_eligible_at = 0;
    emit!(WithdrawalCancelled {
        owner: position.owner,
        ts: now
    });
    Ok(())
}

pub fn handle_withdraw(ctx: Context<CuratorTransfer>, amount: u64) -> Result<()> {
    require!(amount > 0, VaultError::ZeroAmount);
    require!(
        ctx.accounts.owner_ata.key()
            == get_associated_token_address(
                &ctx.accounts.owner.key(),
                &ctx.accounts.config.usdc_mint
            ),
        VaultError::WrongAssociatedTokenAccount
    );
    let now = Clock::get()?.unix_timestamp;
    let config = &mut ctx.accounts.config;
    let position = &mut ctx.accounts.position;
    config.require_version()?;
    position.require_version()?;
    require!(
        position.withdrawal_eligible_at != 0 && now >= position.withdrawal_eligible_at,
        VaultError::Locked
    );
    require!(
        amount <= position.principal,
        VaultError::AmountExceedsPrincipal
    );
    let principal_after = position
        .principal
        .checked_sub(amount)
        .ok_or(VaultError::Overflow)?;
    require!(
        position.drawn <= principal_after,
        VaultError::PositionCapitalDrawn
    );
    require!(
        ctx.accounts.vault_ata.amount >= amount,
        VaultError::InsufficientVaultLiquidity
    );

    config.checkpoint_coupon(position, now)?;

    let bump = config.bump;
    let seeds: &[&[u8]] = &[CONFIG_SEED, &[bump]];
    token::transfer(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.key(),
            Transfer {
                from: ctx.accounts.vault_ata.to_account_info(),
                to: ctx.accounts.owner_ata.to_account_info(),
                authority: config.to_account_info(),
            },
            &[seeds],
        ),
        amount,
    )?;

    position.principal = principal_after;
    config.total_principal = config
        .total_principal
        .checked_sub(amount)
        .ok_or(VaultError::Overflow)?;
    // I2: a withdrawal can never leave the treasury holding more than the principal outstanding.
    require!(
        config.drawn <= config.total_principal,
        VaultError::DrawExceedsPrincipal
    );
    if position.principal == 0 {
        position.lock_end = 0;
        position.notice_requested_at = 0;
        position.withdrawal_eligible_at = 0;
    }
    emit!(Withdrawn {
        owner: position.owner,
        amount,
        principal_after: position.principal,
        total_principal: config.total_principal,
        position_drawn: position.drawn,
        coupon_owed: position.coupon_owed,
        coupon_payable: position.coupon_payable,
        coupon_accrued_through: position.coupon_accrued_through,
        ts: now,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct ClosePosition<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(
        mut,
        close = owner,
        seeds = [POSITION_SEED, owner.key().as_ref()],
        bump = position.bump,
        has_one = owner
    )]
    pub position: Account<'info, Position>,
}

pub fn handle_close_position(ctx: Context<ClosePosition>) -> Result<()> {
    ctx.accounts.config.require_version()?;
    ctx.accounts.position.require_version()?;
    let now = Clock::get()?.unix_timestamp;
    let position = &ctx.accounts.position;
    require!(
        position.principal == 0
            && position.drawn == 0
            && position.coupon_owed == 0
            && position.notice_requested_at == 0,
        VaultError::PositionNotEmpty
    );
    ctx.accounts.config.positions = ctx
        .accounts
        .config
        .positions
        .checked_sub(1)
        .ok_or(VaultError::Overflow)?;
    emit!(PositionClosed {
        owner: position.owner,
        ts: now
    });
    Ok(())
}
