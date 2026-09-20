use anchor_lang::prelude::*;

#[error_code]
pub enum VaultError {
    #[msg("Wallet is not allowlisted for this vault")]
    NotAllowlisted,
    #[msg("Deposits and treasury draws are paused")]
    Paused,
    #[msg("Amount must be greater than zero")]
    ZeroAmount,
    #[msg("A withdrawal notice is pending; cancel it before changing exposure")]
    NoticePending,
    #[msg("No withdrawal notice is pending")]
    NoNotice,
    #[msg("Withdrawal is not yet eligible; wait for the lock and notice to elapse")]
    Locked,
    #[msg("Vault liquidity is below the requested amount; principal must be returned first")]
    InsufficientVaultLiquidity,
    #[msg("Draw would exceed outstanding principal")]
    DrawExceedsPrincipal,
    #[msg("Return would exceed the amount drawn")]
    ReturnExceedsDrawn,
    #[msg("Nothing is due for this position at this boundary")]
    NothingDue,
    #[msg("Coupon pool is below the amount due")]
    InsufficientCouponPool,
    #[msg("Rate epoch history is full")]
    RateEpochsFull,
    #[msg("A rate epoch must start after the previous one and not in the past")]
    RateNotForward,
    #[msg("Rate must be between 1 and 10,000 basis points")]
    BadRate,
    #[msg("Terms must be between one day and two years")]
    BadTerms,
    #[msg("Token account has the wrong mint")]
    WrongMint,
    #[msg("Token account is not owned by the expected authority")]
    WrongTokenAccount,
    #[msg("Principal is not at risk under this vault's agreements")]
    PrincipalNotAtRisk,
    #[msg("Loss exceeds the position's principal")]
    LossExceedsPrincipal,
    #[msg("Loss exceeds the drawn amount; undrawn capital cannot be lost")]
    LossExceedsDrawn,
    #[msg("Hash must be non-zero")]
    ZeroHash,
    #[msg("Position still holds principal, owed coupon or a notice")]
    PositionNotEmpty,
    #[msg("Arithmetic overflow")]
    Overflow,
    #[msg("Position already allowlisted")]
    AlreadyAllowlisted,
    #[msg("Amount exceeds the position's principal")]
    AmountExceedsPrincipal,
    #[msg("Only the program's upgrade authority may initialise the vault")]
    Unauthorized,
    #[msg("A rate epoch may not start more than two years ahead")]
    RateTooFar,
    #[msg("An authority cannot be the zero address")]
    ZeroAuthority,
    #[msg("Coupon payouts to this position are halted pending review")]
    PayoutHalted,
    #[msg("Sweep exceeds the recoverable token surplus")]
    SweepExceedsPool,
    #[msg("Token account is not the owner's associated token account")]
    WrongAssociatedTokenAccount,
    #[msg("Coupon funds are reserved for accrued obligations")]
    CouponLiabilityReserved,
    #[msg("Token balances are below the program's accounted balance")]
    AccountingMismatch,
    #[msg("An agreement hash cannot change while the position has live obligations")]
    AgreementChangeWithBalance,
    #[msg("The requested principal is deployed for this position and must be returned first")]
    PositionCapitalDrawn,
    #[msg("Account layout version is not supported by this program")]
    UnsupportedVersion,
    #[msg("Only the pending admin may accept the admin role")]
    NotPendingAdmin,
    #[msg("Unused coupon funding can be withdrawn only after every position is closed")]
    VaultNotEmpty,
}
