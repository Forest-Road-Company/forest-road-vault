use anchor_lang::prelude::*;

#[event]
pub struct Initialized {
    pub version: u8,
    pub admin: Pubkey,
    pub allowlist_authority: Pubkey,
    pub treasury_authority: Pubkey,
    pub emergency_authority: Pubkey,
    pub usdc_mint: Pubkey,
    pub vault_ata: Pubkey,
    pub coupon_ata: Pubkey,
    pub treasury_ata: Pubkey,
    pub lock_seconds: u64,
    pub notice_seconds: u64,
    pub principal_at_risk: bool,
    pub initial_bps: u16,
}

#[event]
pub struct RateEpochAdded {
    pub index: u8,
    pub start_ts: i64,
    pub bps: u16,
}

#[event]
pub struct TermsChanged {
    pub lock_seconds: u64,
    pub notice_seconds: u64,
}

#[event]
pub struct AuthoritiesChanged {
    pub allowlist_authority: Pubkey,
    pub treasury_authority: Pubkey,
    pub emergency_authority: Pubkey,
    pub treasury_ata: Pubkey,
}

#[event]
pub struct AdminTransferProposed {
    pub admin: Pubkey,
    pub pending_admin: Pubkey,
}

#[event]
pub struct AdminTransferAccepted {
    pub previous_admin: Pubkey,
    pub admin: Pubkey,
}

#[event]
pub struct PayoutHaltChanged {
    pub owner: Pubkey,
    pub halted: bool,
    pub actor: Pubkey,
    pub ts: i64,
}

#[event]
pub struct CouponsSwept {
    pub amount: u64,
    pub coupon_funded: u64,
    pub ts: i64,
}

#[event]
pub struct CouponFundingWithdrawn {
    pub amount: u64,
    pub coupon_funded: u64,
    pub ts: i64,
}

#[event]
pub struct PrincipalSurplusSwept {
    pub amount: u64,
    pub ts: i64,
}

#[event]
pub struct PauseChanged {
    pub paused: bool,
    pub actor: Pubkey,
    pub ts: i64,
}

#[event]
pub struct Allowlisted {
    pub owner: Pubkey,
    pub agreement_hash: [u8; 32],
    pub ts: i64,
}

#[event]
pub struct AllowlistRevoked {
    pub owner: Pubkey,
    pub ts: i64,
}

#[event]
pub struct Deposited {
    pub owner: Pubkey,
    pub amount: u64,
    pub principal_after: u64,
    pub lock_end: i64,
    pub total_principal: u64,
    pub position_drawn: u64,
    pub coupon_owed: u64,
    pub coupon_payable: u64,
    pub coupon_accrued_through: i64,
    pub ts: i64,
}

#[event]
pub struct WithdrawalRequested {
    pub owner: Pubkey,
    pub eligible_at: i64,
    pub ts: i64,
}

#[event]
pub struct WithdrawalCancelled {
    pub owner: Pubkey,
    pub ts: i64,
}

#[event]
pub struct Withdrawn {
    pub owner: Pubkey,
    pub amount: u64,
    pub principal_after: u64,
    pub total_principal: u64,
    pub position_drawn: u64,
    pub coupon_owed: u64,
    pub coupon_payable: u64,
    pub coupon_accrued_through: i64,
    pub ts: i64,
}

#[event]
pub struct TreasuryDraw {
    pub owner: Pubkey,
    pub amount: u64,
    pub drawn_after: u64,
    pub position_drawn_after: u64,
    pub ts: i64,
}

#[event]
pub struct PrincipalReturned {
    pub owner: Pubkey,
    pub amount: u64,
    pub drawn_after: u64,
    pub position_drawn_after: u64,
    pub ts: i64,
}

#[event]
pub struct CouponsFunded {
    pub amount: u64,
    pub coupon_funded: u64,
    pub ts: i64,
}

#[event]
pub struct CouponPaid {
    pub owner: Pubkey,
    pub period_end: i64,
    pub amount: u64,
    pub coupon_paid: u64,
    pub coupon_owed_after: u64,
    pub coupon_payable_after: u64,
    pub coupon_accrued_through: i64,
    pub surplus_recognized: u64,
    pub ts: i64,
}

#[event]
pub struct LossRecorded {
    pub owner: Pubkey,
    pub amount: u64,
    pub principal_after: u64,
    pub position_drawn_after: u64,
    pub coupon_owed: u64,
    pub coupon_payable: u64,
    pub coupon_accrued_through: i64,
    pub evidence_hash: [u8; 32],
    pub ts: i64,
}

#[event]
pub struct PositionClosed {
    pub owner: Pubkey,
    pub ts: i64,
}
