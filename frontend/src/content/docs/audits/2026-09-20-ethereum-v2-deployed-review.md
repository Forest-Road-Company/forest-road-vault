# Review of the exact deployed Ethereum V2 contracts

## Result

No new Critical, High or Medium contract defect was confirmed. The review targeted the exact 18
mainnet proxy addresses, their implementation and linked-library identities, and their live role
and parameter state. It made no Solidity change and submitted no mainnet transaction.

The clean serialized fork population passed 537 tests across 69 suites with zero failures or
skips. Focused scenarios exercised lifecycle, accounting, governance and cross-contract failure
modes against the deployed addresses. Deliberate incorrect changes turned each important new test
red before the source was restored.

## Live-state limit

The credit book was empty during review. Fork scenarios created facilities, capital, accrual,
defaults and losses against the deployed bytecode; they are not a claim that a real mainnet loan
had completed those events. The first real facility still needs its own reviewed signed facts and
capital.

The extreme rounding remainder and conservative fee-withholding policy remain disclosed in the
findings list. Both favor a fail-closed or senior-protective result; neither is described as fixed.

## Subsequent acceptance

The same deployed implementations later completed the funded mainnet canary and the Ops Safe
jurisdiction block/unblock drill. Supply equalled backing, physical USDC equalled the idle reserve
ledger, and no implementation or role changed during those exercises.
