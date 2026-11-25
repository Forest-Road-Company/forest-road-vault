# ADR-0040: Governed borrower-payout allowlist

**Status:** Accepted and deployed on Ethereum V2 (`ComplianceRegistry.setFundingRecipientAllowed`
and `BorrowerPayoutLib` active on origination and funding paths).

**Date:** 2026-09-22

## Context

Loan terms contain a signed `fundingRecipient`, and funding sends USDC directly from
ReserveManager to that address. Documentary attestations prove the legal and credit facts, but the
contracts previously had no independent on-chain restriction on the destination. An otherwise
valid origination could therefore name a mistyped or unapproved address, and the same destination
would later be paid by `fund`.

The owner requires the initial production policy to permit only
`0x7FDe637d685A5486CCb1B0a8eF658Ad1a08e8337`. Any additional destination requires explicit owner
approval through governance. Ordinary KYC approval is not enough to receive loan proceeds.

## Decision

ComplianceRegistry carries a separate `fundingRecipientApproved` mapping in the tail of its
ERC-7201 namespace. Only `DEFAULT_ADMIN_ROLE`, held by the timelock after handover, may change it.
The operational compliance role cannot add a destination. A jurisdiction block overrides an
approval immediately and clearing the block restores the underlying governed approval.

ClaimBridge permanently binds the ComplianceRegistry and rejects an unapproved signed destination
before it creates the NFT or reserves exposure. ReserveManager independently binds the same
registry and checks the destination immediately before changing deployment accounting or
transferring USDC. The second check closes the interval between origination and funding: revocation
or a jurisdiction block during that interval stops the payout without changing the pending loan,
exposure, reserve accounting or token balances.

The two bindings are one-time. Fresh deployment validation requires ReserveManager's binding to
equal the deployed ComplianceRegistry and requires exactly the owner-approved initial destination.
The other genesis KYC addresses must not appear on the funding-recipient list.

## Upgrade and recovery

The Ethereum upgrade combines this policy with ADR-0039 because both changes touch ClaimBridge and
ReserveManager. One atomic governance proposal upgrades ComplianceRegistry, approves the exact
initial destination, upgrades and binds ReserveManager, then upgrades WaterfallEngine,
DefaultManager and ClaimBridge and binds ClaimBridge. Mixed-interest admission remains disabled
until its separate activation proposal.

Before mixed-interest activation, recovery may restore the recorded prior implementations. The
old implementations do not enforce this payout policy, so ClaimBridge and WaterfallEngine must be
guardian-paused before rollback and remain paused through the reviewed roll-forward. The proxy
storage survives: the approval and both permanent bindings become active again when the reviewed
implementations return. After mixed-interest activation, the existing version guards refuse the
old implementations.

## Consequences

Changing a borrower destination now takes governance time. A mistaken revocation can delay funding
but cannot redirect funds. KYC administration remains operationally separate, while jurisdiction
blocking can stop an already-approved destination immediately. Existing funded facilities and
their balances are unchanged; a pending facility is checked against the current policy when it is
funded.

The deployment and governance runbooks must display the exact destination, the approval call and
both permanent bindings. No operator should treat an off-chain list or an ordinary KYC entry as
authority to fund another address.
