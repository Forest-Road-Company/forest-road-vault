/**
 * Revert decoding (CLAUDE.md §3.3: "decode custom errors to human-readable messages").
 * Every write is simulated with an ABI that includes the merged protocol error set
 * (lib/abi.ts), so viem surfaces a named ContractFunctionRevertedError; this module
 * turns that name into copy a depositor can act on. Unknown reverts fall back to
 * viem's shortMessage — never swallowed (Prime Directive 4: fail loudly).
 */

import {BaseError, ContractFunctionRevertedError} from "viem";

/** Exported for the error-ABI drift guard in `audit-logic-test.mts`. Every key here MUST
 *  have a matching entry in `PROTOCOL_ERRORS`, or the copy is unreachable. */
export const ERROR_MESSAGES: Record<string, string> = {
  Controller_NotKYCAllowed:
    "This address is not KYC-verified. Verified addresses can mint and redeem; any address can hold, view, transfer, and stake.",
  SUSDfr_TransferBlocked:
    "This sUSDfr transfer is blocked — one of the addresses is on the sanctions blocklist.",
  USDfr_TransferNotAllowed:
    "This transfer is blocked — one of the addresses is on the sanctions blocklist.",
  Controller_ZeroAmount: "Enter an amount greater than zero.",
  Queue_AllInCooldown:
    "Your redemption is still in its configured minimum holding period. The live countdown on your queue position shows when it first becomes eligible; FIFO order and available liquidity can make settlement later.",
  ReserveManager_InsufficientIdleValue:
    "The treasury does not hold enough idle USDC to fill this redemption right now. Try a smaller amount, or the sUSDfr redemption queue.",
  Queue_ZeroAmount: "Enter an amount greater than zero.",
  Controller_AmountTooSmall:
    "Amount is below one whole unit of the stablecoin — too small to redeem without dust.",
  Controller_BackingInvariantViolated:
    "The mint would push USDfr supply above its backing — refused by the backing invariant.",
  Queue_BelowMinRedemption:
    "This redemption is below the $1 minimum. Queued redemptions must be worth at least $1 to enter the queue — increase the amount.",
  Queue_HeadNotRedeemable:
    "Settlement is paused: the senior book is currently marked below a redeemable value, so nothing can be paid out right now. This clears automatically once the mark recovers or a loss is realized.",
  Queue_NothingClaimable:
    "Nothing to claim on this request yet. Requests fill when an epoch settles with available liquidity.",
  Queue_NotRequestOwner: "Only the address that created this request can claim it.",
  Queue_UnknownRequest: "Unknown queue request id.",
  Queue_EpochNotOver:
    "The next settlement window has not opened yet. Settlements run on a short heartbeat; your own wait is set by the redemption cooldown on your position, not by this.",
  Queue_NotSettling: "The queue is not in a settlement window.",
  Queue_NoLiquidity: "No stable liquidity is available for settlement right now.",
  EnforcedPause: "This module is paused by the guardian. Try again once it is unpaused.",
  ERC20InsufficientBalance: "Balance is too low for this amount.",
  ERC20InsufficientAllowance: "Approval is too low — approve the amount first.",
  ERC4626ExceededMaxDeposit: "Deposit exceeds the vault's current limit for this address.",
  ERC4626ExceededMaxRedeem: "Redeem exceeds this address's staked balance.",
  SUSDfr_QueueOnly:
    "Direct vault exits are disabled — sUSDfr redemptions go through the redemption queue.",
  AccessControlUnauthorizedAccount: "This address does not hold the role required for this action.",
  SafeERC20FailedOperation: "The token transfer failed.",
  ReentrancyGuardReentrantCall: "Reentrant call refused.",
};

export type DecodedError = {
  /** Human copy for the UI. */
  message: string;
  /** The decoded custom-error name (or null if not a named protocol error). */
  errorName: string | null;
};

export function decodeWriteError(err: unknown): DecodedError {
  if (err instanceof BaseError) {
    if (err.name === "WaitForTransactionReceiptTimeoutError") {
      return {
        message:
          "The transaction was submitted, but this app did not see its receipt on the configured RPC within 90 seconds. For local-fork testing, both the app and wallet must use the same loopback RPC and dedicated chain ID 31337.",
        errorName: null,
      };
    }
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName ?? revert.signature ?? null;
      if (name && ERROR_MESSAGES[name]) return {message: ERROR_MESSAGES[name], errorName: name};
      if (name) return {message: `Reverted: ${name}`, errorName: name};
    }
    // User rejected in the wallet, RPC failure, etc. — viem's short message is honest.
    return {message: err.shortMessage, errorName: null};
  }
  return {message: err instanceof Error ? err.message : "Unknown error", errorName: null};
}
