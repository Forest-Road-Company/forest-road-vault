use anchor_lang::prelude::*;
use anchor_spl::token::{Mint, Token, TokenAccount};

use crate::constants::*;
use crate::error::VaultError;
use crate::events::*;
use crate::math;
use crate::state::{Config, RateEpoch};

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct InitializeParams {
    pub allowlist_authority: Pubkey,
    pub treasury_authority: Pubkey,
    pub emergency_authority: Pubkey,
    pub lock_seconds: u64,
    pub notice_seconds: u64,
    pub principal_at_risk: bool,
    pub initial_bps: u16,
}

#[derive(Accounts)]
#[instruction(params: InitializeParams)]
pub struct Initialize<'info> {
    /// The admin funds the accounts and holds the admin authority afterwards. It must be the
    /// program's upgrade authority: the singleton config would otherwise belong to whoever
    /// landed `initialize` first in the window between deployment and the ceremony. On mainnet
    /// the upgrade authority is the Squads multisig, which signs through its vault.
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(constraint = program.programdata_address()? == Some(program_data.key()) @ VaultError::Unauthorized)]
    pub program: Program<'info, crate::program::ForestroadCuratorVault>,
    #[account(constraint = program_data.upgrade_authority_address == Some(admin.key()) @ VaultError::Unauthorized)]
    pub program_data: Account<'info, ProgramData>,
    #[account(
        init,
        payer = admin,
        space = 8 + Config::INIT_SPACE,
        seeds = [CONFIG_SEED],
        bump
    )]
    pub config: Account<'info, Config>,
    pub usdc_mint: Account<'info, Mint>,
    #[account(
        init,
        payer = admin,
        seeds = [VAULT_SEED],
        bump,
        token::mint = usdc_mint,
        token::authority = config
    )]
    pub vault_ata: Account<'info, TokenAccount>,
    #[account(
        init,
        payer = admin,
        seeds = [COUPON_SEED],
        bump,
        token::mint = usdc_mint,
        token::authority = config
    )]
    pub coupon_ata: Account<'info, TokenAccount>,
    /// The draw destination: a token account of the right mint owned by the treasury authority,
    /// so a draw can only ever land with the party that signs draws. The admin rotates it later
    /// under the same rule.
    #[account(
        constraint = treasury_ata.mint == usdc_mint.key() @ VaultError::WrongMint,
        constraint = treasury_ata.owner == params.treasury_authority @ VaultError::WrongTokenAccount
    )]
    pub treasury_ata: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

pub fn handle_initialize(ctx: Context<Initialize>, params: InitializeParams) -> Result<()> {
    require!(
        params.allowlist_authority != Pubkey::default()
            && params.treasury_authority != Pubkey::default()
            && params.emergency_authority != Pubkey::default(),
        VaultError::ZeroAuthority
    );
    require!(
        (MIN_TERM_SECONDS..=MAX_TERM_SECONDS).contains(&params.lock_seconds)
            && (MIN_TERM_SECONDS..=MAX_TERM_SECONDS).contains(&params.notice_seconds),
        VaultError::BadTerms
    );
    require!(
        (1..=MAX_RATE_BPS).contains(&params.initial_bps),
        VaultError::BadRate
    );
    let now = Clock::get()?.unix_timestamp;
    let config = &mut ctx.accounts.config;
    config.version = ACCOUNT_VERSION;
    config.admin = ctx.accounts.admin.key();
    config.pending_admin = Pubkey::default();
    config.allowlist_authority = params.allowlist_authority;
    config.treasury_authority = params.treasury_authority;
    config.emergency_authority = params.emergency_authority;
    config.usdc_mint = ctx.accounts.usdc_mint.key();
    config.vault_ata = ctx.accounts.vault_ata.key();
    config.coupon_ata = ctx.accounts.coupon_ata.key();
    config.treasury_ata = ctx.accounts.treasury_ata.key();
    config.lock_seconds = params.lock_seconds;
    config.notice_seconds = params.notice_seconds;
    config.day_count = DAY_COUNT_ACTUAL_360;
    config.principal_at_risk = params.principal_at_risk;
    config.paused = false;
    config.rate_epochs = [RateEpoch::default(); math::MAX_RATE_EPOCHS];
    config.rate_epochs[0] = RateEpoch {
        start_ts: now,
        bps: params.initial_bps,
    };
    config.rate_epoch_count = 1;
    config.bump = ctx.bumps.config;
    emit!(Initialized {
        version: config.version,
        admin: config.admin,
        allowlist_authority: config.allowlist_authority,
        treasury_authority: config.treasury_authority,
        emergency_authority: config.emergency_authority,
        usdc_mint: config.usdc_mint,
        vault_ata: config.vault_ata,
        coupon_ata: config.coupon_ata,
        treasury_ata: config.treasury_ata,
        lock_seconds: config.lock_seconds,
        notice_seconds: config.notice_seconds,
        principal_at_risk: config.principal_at_risk,
        initial_bps: params.initial_bps,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct AdminOnly<'info> {
    pub admin: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = admin)]
    pub config: Account<'info, Config>,
}

pub fn handle_set_rate(ctx: Context<AdminOnly>, bps: u16, start_ts: i64) -> Result<()> {
    require!((1..=MAX_RATE_BPS).contains(&bps), VaultError::BadRate);
    let now = Clock::get()?.unix_timestamp;
    let config = &mut ctx.accounts.config;
    config.require_version()?;
    let count = config.rate_epoch_count as usize;
    require!(count < math::MAX_RATE_EPOCHS, VaultError::RateEpochsFull);
    let last = config.rate_epochs[count - 1].start_ts;
    require!(
        start_ts > last && start_ts >= now,
        VaultError::RateNotForward
    );
    // A mistyped epoch (milliseconds, or a year that never comes) would pin the schedule until
    // an upgrade; two years is the horizon the terms themselves are bounded to.
    require!(
        start_ts <= now.saturating_add(MAX_TERM_SECONDS as i64),
        VaultError::RateTooFar
    );
    config.rate_epochs[count] = RateEpoch { start_ts, bps };
    config.rate_epoch_count += 1;
    emit!(RateEpochAdded {
        index: count as u8,
        start_ts,
        bps
    });
    Ok(())
}

pub fn handle_set_terms(
    ctx: Context<AdminOnly>,
    lock_seconds: u64,
    notice_seconds: u64,
) -> Result<()> {
    require!(
        (MIN_TERM_SECONDS..=MAX_TERM_SECONDS).contains(&lock_seconds)
            && (MIN_TERM_SECONDS..=MAX_TERM_SECONDS).contains(&notice_seconds),
        VaultError::BadTerms
    );
    let config = &mut ctx.accounts.config;
    config.require_version()?;
    config.lock_seconds = lock_seconds;
    config.notice_seconds = notice_seconds;
    emit!(TermsChanged {
        lock_seconds,
        notice_seconds
    });
    Ok(())
}

#[derive(Accounts)]
#[instruction(allowlist_authority: Pubkey, treasury_authority: Pubkey, emergency_authority: Pubkey)]
pub struct SetAuthorities<'info> {
    pub admin: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = admin)]
    pub config: Account<'info, Config>,
    /// Must be owned by the treasury authority being set and must not be one of the vault's own
    /// accounts, so principal can never be drawn into the coupon pool or back into the vault.
    #[account(
        constraint = treasury_ata.mint == config.usdc_mint @ VaultError::WrongMint,
        constraint = treasury_ata.owner == treasury_authority @ VaultError::WrongTokenAccount,
        constraint = treasury_ata.key() != config.vault_ata && treasury_ata.key() != config.coupon_ata @ VaultError::WrongTokenAccount
    )]
    pub treasury_ata: Account<'info, TokenAccount>,
}

pub fn handle_set_authorities(
    ctx: Context<SetAuthorities>,
    allowlist_authority: Pubkey,
    treasury_authority: Pubkey,
    emergency_authority: Pubkey,
) -> Result<()> {
    require!(
        allowlist_authority != Pubkey::default()
            && treasury_authority != Pubkey::default()
            && emergency_authority != Pubkey::default(),
        VaultError::ZeroAuthority
    );
    let config = &mut ctx.accounts.config;
    config.require_version()?;
    config.allowlist_authority = allowlist_authority;
    config.treasury_authority = treasury_authority;
    config.emergency_authority = emergency_authority;
    config.treasury_ata = ctx.accounts.treasury_ata.key();
    emit!(AuthoritiesChanged {
        allowlist_authority,
        treasury_authority,
        emergency_authority,
        treasury_ata: config.treasury_ata,
    });
    Ok(())
}

/// Begins a two-step admin rotation. The proposed key must explicitly accept before the current
/// admin loses control, so a typo cannot orphan the program after the upgrade authority freezes.
pub fn handle_propose_admin(ctx: Context<AdminOnly>, new_admin: Pubkey) -> Result<()> {
    require!(new_admin != Pubkey::default(), VaultError::ZeroAuthority);
    let config = &mut ctx.accounts.config;
    config.require_version()?;
    config.pending_admin = new_admin;
    emit!(AdminTransferProposed {
        admin: config.admin,
        pending_admin: new_admin
    });
    Ok(())
}

#[derive(Accounts)]
pub struct AcceptAdmin<'info> {
    pub pending_admin: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
}

pub fn handle_accept_admin(ctx: Context<AcceptAdmin>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    config.require_version()?;
    require!(
        config.pending_admin == ctx.accounts.pending_admin.key(),
        VaultError::NotPendingAdmin
    );
    let previous_admin = config.admin;
    config.admin = ctx.accounts.pending_admin.key();
    config.pending_admin = Pubkey::default();
    emit!(AdminTransferAccepted {
        previous_admin,
        admin: config.admin
    });
    Ok(())
}

pub fn handle_set_paused(ctx: Context<AdminOnly>, paused: bool) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    ctx.accounts.config.require_version()?;
    ctx.accounts.config.paused = paused;
    emit!(PauseChanged {
        paused,
        actor: ctx.accounts.admin.key(),
        ts: now
    });
    Ok(())
}

#[derive(Accounts)]
pub struct EmergencyOnly<'info> {
    pub emergency_authority: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = emergency_authority)]
    pub config: Account<'info, Config>,
}

/// One-way hot-key brake. Only the time-locked admin may clear the pause.
pub fn handle_emergency_pause(ctx: Context<EmergencyOnly>) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    ctx.accounts.config.require_version()?;
    ctx.accounts.config.paused = true;
    emit!(PauseChanged {
        paused: true,
        actor: ctx.accounts.emergency_authority.key(),
        ts: now
    });
    Ok(())
}
