/**
 * Pure view helpers for the Ethereum curator surface on /curators. Kept out of the component
 * so the figures a curator is shown can be tested without a wallet or a chain.
 */

export type ClassView = {
  classId: bigint;
  name: string;
  approved: boolean;
  /** This wallet's share of the class pool, as the module values it now. */
  posted: bigint;
  /** Every curator's capital in the class. */
  pool: bigint;
  /** What live facilities in the class require the pool to hold. */
  required: bigint;
  /** Pool capital above the requirement, the most any curator may withdraw. */
  headroom: bigint;
  /** Non-zero while a facility in the class is in an unresolved default. */
  unresolvedDefaults: bigint;
};

/** The most this wallet can withdraw from a class right now: its own posting, capped by the
 *  class headroom, and nothing while the class is frozen on a default. */
export function withdrawableNow(
  view: Pick<ClassView, "posted" | "headroom" | "unresolvedDefaults">,
  blocked = false,
): bigint {
  if (blocked || view.unresolvedDefaults !== 0n) return 0n;
  return view.posted < view.headroom ? view.posted : view.headroom;
}

/** Whether a posting of `amount` needs an ERC-20 approval first. An unknown allowance is
 *  treated as insufficient so the button never offers a post that will revert. */
export function needsAllowance(amount: bigint | null, allowance: bigint | undefined): boolean {
  if (amount === null || amount === 0n) return false;
  return allowance === undefined || allowance < amount;
}

/** Sentence for the class's state, or null when there is nothing to flag. */
export function classNotice(view: Pick<ClassView, "unresolvedDefaults" | "headroom" | "posted">): string | null {
  if (view.unresolvedDefaults !== 0n) {
    return "A facility in this class is in default; withdrawals reopen when governance resolves the workout.";
  }
  if (view.posted > 0n && view.headroom === 0n) {
    return "Live facilities require everything posted in this class; nothing is withdrawable until they repay or more capital is posted.";
  }
  return null;
}
