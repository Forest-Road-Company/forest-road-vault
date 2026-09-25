# Integrating with USDfr and sUSDfr

This page states the ways our tokens depart from what an integrator would assume from their
interfaces. Everything here is a property of shipped source, not a roadmap. If you are wiring a
router, an aggregator, a vault adapter or a yield-tokenisation protocol, read this first. Several
of these are invisible in the ABI and will surface as unexplained reverts.

## sUSDfr is ERC-4626 only partially: redemption is asynchronous

`sUSDfr` implements the full ERC-4626 interface: all sixteen mandated functions with correct
signatures, both `Deposit` and `Withdraw` events, and the complete ERC-20 share surface.

**But `withdraw()` and `redeem()` are not synchronous and are not callable by holders.** Senior exit
runs through the `RedemptionQueue`, where each request waits out a 21-day minimum hold before it can
fill. Both functions are gated so that the only workable
combination is `owner == msg.sender == redemptionQueue`. Concretely:

- An ordinary holder calling `redeem()` reverts. So does a contract holding shares on a user's behalf.
- The ERC-4626 approval flow, a spender redeeming an owner's shares under an allowance, has **no**
  satisfying combination, because the guard tests the caller rather than the owner.
- `maxWithdraw()` and `maxRedeem()` correctly return `0` for every address except the queue, so a
  well-behaved integrator that checks limits first will see the restriction rather than revert.

To exit, a holder requests through the queue and claims after settlement. If you are building on
top of `sUSDfr`, treat it as an asynchronous-redemption vault (the shape ERC-7540 describes) rather
than a standard 4626 vault, even though it does not implement ERC-7540 and does not signal async
semantics on-chain. `supportsInterface` does not return true for `IERC4626`.

Entry is synchronous: `deposit()` and `mint()` behave like ordinary ERC-4626 entry points, while
the token's compliance checks still apply to the receiver.

## NAV includes earned but unreceived interest

Ethereum V2 recognizes earned cash and PIK interest continuously from each facility's frozen
basis. `totalAssets()` therefore changes with time even when no repayment transaction has occurred.
The protocol interest split and sUSDfr performance fee are applied to that earned income as it
streams; receipt or PIK capitalization must not be treated by an integrator as new income a second
time.

PIK capitalization remains a contractual schedule event. A facility may have continuously earned
PIK in NAV while its on-chain principal does not change until the scheduled boundary is serviced.
Quotes should be read at one block and should not be cached across a lifecycle transaction,
default declaration or keeper checkpoint.

## Every balance change requires 500,000 gas *available*

`USDfr` and `sUSDfr` both run a participation-points hook inside `_update`. Before calling it, the
token requires `gasleft() >= 500,000` and reverts with `PointsHook_InsufficientGas` otherwise. This
applies to **every** mint, burn and plain ERC-20 transfer.

This is a deliberate control: without a floor, a caller could supply just enough gas to commit the
transfer while starving the hook's accounting, so the requirement fails closed against
caller-selected underfunding.

The practical consequence, which is easy to miss:

- **Ordinary wallets are fine.** `eth_estimateGas` binary-searches for a limit at which the call
  *succeeds*, so it naturally returns one that clears the floor.
- **You will break if you size gas from observed consumption.** A transfer consumes far less than
  500,000; provisioning from a measured or simulated figure and applying a percentage buffer will
  under-provision and revert. This is not proportional to the transfer's cost: the floor is an
  absolute constant, so the cheaper your call, the larger the multiple you need.
- **Bounded gas stipends will fail.** Any pattern that forwards a fixed sub-500,000 stipend to a
  transfer cannot succeed.
- **Multi-hop routes need headroom.** A route that touches these tokens needs 500,000 spare at that
  hop, on top of everything else in the transaction.

If you hardcode a gas limit anywhere near these tokens, set it from the floor, not from consumption.

Governance proposal FRV-007, in voting from 26 to 28 September 2026, would upgrade both tokens to
remove this floor. Until it executes, the floor applies; this section will change if it does.

## Transfers are permissionless but jurisdiction-screened

Share and token transfers are **not** gated by ordinary allowlist membership. A wallet-specific
jurisdiction block denies a transfer if either party is blocked and not a protocol module. Burns
remain available so the protocol can reduce supply safely.

For integrators this means a DEX pool or router does not need allowlisting, but a token that can
refuse a specific recipient is unusual, and aggregators generally do not model it. Expect occasional
route failures that look opaque unless you decode `SUSDfr_TransferBlocked` / the USDfr equivalent.

Note the asymmetry: **minting and redeeming USDfr against USDC is KYC-gated**, while transferring
either token is not.

## `sUSDfr.decimals()` is 24

The vault uses a six-decimal virtual-share offset over an 18-decimal asset, so `decimals()` returns
`24` and par is `1e18`, not `1e12`. This is OpenZeppelin's standard inflation-attack defence and is
spec-legal, but it has repeatedly caught reviewers who assumed 18. Any hardcoded scaling constant
against `sUSDfr` share amounts should be derived from `decimals()`.

## Conversion views can revert

`convertToShares()`, `convertToAssets()` and `maxWithdraw()` can revert when the impairment source
is unreadable or returns a semantically invalid ordering. ERC-4626 requires the conversions not to
revert except on overflow, and requires `maxWithdraw` not to revert at all, so this is a genuine
deviation rather than a documented design choice.

It is reachable only in a degraded state: the protocol provides
`clearUnreadableImpairmentSource()` to recover, but if you price off `convertToAssets()`, handle
the revert rather than assuming a number. In particular, an adapter that derives an exchange rate
from `convertToAssets(1e18)` will propagate the failure to everything downstream of it.

`totalAssets()` and `totalSupply()` do **not** touch that path and cannot revert for this reason.

## Three asset bases coexist

Do not assume one "assets" number. Entry prices off realised `totalAssets()`; exit prices off a
conservative `redemptionTotalAssets()`; performance measurement uses a third base that excludes
temporary curator and sGROVE capital. Mixing them has produced High-severity findings in our own review history. If you are
comparing an amount against a total, check which base you are holding.

## Where to look next

The [audit register](/docs/audit) records each review's scope, material findings and
disposition, including accepted findings. The [security](/docs/security) and
[live-status](/docs/status) pages state what was reviewed, what ran on mainnet, and which
observations or operating dependencies remain.
