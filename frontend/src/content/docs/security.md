# Security and Testing

Forest Road Vault V2 is live on Ethereum mainnet. Its permanent proxy entry points were deployed
at block 26,006,832 from the manifest identified on the
[deployed-addresses page](/docs/addresses). Bootstrap authority has been removed from the deployer;
administration and upgrades are held by timelocked governance.

Security reviews and tests reduce risk. They do not prove that the contracts, governance,
custodians, keepers, signers or real-world loan facts cannot fail. Each review on the
[audit register](/docs/audit) states its own source baseline and scope because a clean result
outside that boundary is not evidence about the rest of the system.

## Current release evidence

The deployment qualification and the later deployed-contract review resolved the live proxies,
implementations, linked libraries, roles, negative roles, module wiring, fee settings, risk
parameters and continuous-accrual bindings against the production manifest. Etherscan recorded
source verification for all 60 deployment inventory addresses and implementation association for
all 18 proxies. On-chain code hashes and ERC-1967 implementation slots are the authoritative
identity checks.

The exact deployed source tree completed:

- a clean production build with Solidity 0.8.30, optimizer runs 100, Cancun and no IR;
- 3,108 non-fork release checks, comprising 3,105 passing tests and three separately executed
  endpoint checks;
- 208 heavy invariant tests at 512 runs and depth 256;
- eight Halmos symbolic properties;
- executable reachability for 1,074 of 1,074 deployed-scope functions;
- 99.40% line and 94.95% branch coverage over `contracts/src`; and
- a later clean mainnet-fork population of 69 suites and 537 passing tests with zero failures or
  skips.

The deployed-address scenarios cover cash and PIK origination, continuous accrual, scheduled PIK
capitalization, both fee layers, repayment, delinquency and cure, assessed impairment, the
curator-to-sGROVE-to-senior loss order, recovery, queue FIFO and settlement, direct redemption,
sGROVE rewards and unbonding, voting and timelock execution, custody controls, signature quorum and
replay, stale accrual, donations, late entry, pausing, and split sub-par exits.

The important new tests were checked with deliberate incorrect changes. The review asserted that
each change actually applied, observed the intended failures, restored the source byte for byte,
and reran the passing cases. This matters because a test that stays green after the behavior it is
supposed to protect is removed provides no useful evidence.

## Continuous adversarial testing

Security is an operating discipline, not a launch event. Forest Road continually forks the
deployed Ethereum contracts with their live state and attacks accounting, authorization, loan
lifecycles, liquidity, redemption ordering and cross-contract boundaries without touching live
assets.

Through 29 September 2026, the fork programme completed **130 strict-novelty rounds and 196
novel attack scenarios**. The canonical ledger contains **10,307 adversarial attempts across 302
campaigns**, retaining both successful and unsuccessful attacks. A scenario counts as novel only
after its mechanism, target, trigger, state transition, consequence and cross-contract composition
are screened against the existing ledger; regressions, parameter sweeps and harness checks do not
inflate the total.

Round 59 initially appeared to confirm **High / Open LMV-17**, but control review showed that the
comparison skipped the remaining sUSDfr loss layer and the mandatory frozen G3 remedy. Forest Road
withdrew and refuted the classification: the measured difference was not an attacker-reachable
contract defect. The failed analysis and its correction remain in the ledger rather than being
erased. No attacker-reachable High or Critical is currently confirmed.

The latest round challenged whether permissionless accrual maintenance could create financing
inside an external liquidation callback. After Morpho delivered **1,000 sUSDfr** of seized
collateral, a roleless contract posted existing virtual interest, materialized both USDfr issuance
legs, reposted the collateral and recursively borrowed. The planned oracle stayed exactly
**0.651096550750396791 USDC per sUSDfr**: the accounting representation changed, but economic
value did not. The nested borrow reached **559.943032 USDC**, below the **623.750496 USDC** outer
repayment, so the zero-capital route reverted atomically and still required **63.807464 USDC** of
outside capital. This is **Held / no finding**; the planned market remains undeployed, the separate
Round 128 launch blocker remains accepted, and the campaign is paused at this reproducible
checkpoint.

The separate **Medium / Open** economic finding LMV-09 has High technical impact but very-low
practical likelihood. During a marked-credit window, an ordinary KYC holder can amplify settlement of an
unrelated non-cancellable request; the fork stayed gross-positive across every tested cure
combination and severe-loss control while the queued depositor suffered material permanent loss.
Practical execution requires roughly USD 6m of real or term-borrowed capital across transactions,
pre-aged and precisely aligned queue positions, an existing recovery-bearing stake, two keeper
batches, and margins exposed to financing and gas. Neither party knows which loans will cure, and
the attacker is an identifiable KYC participant exposed to monitoring and blacklisting. Those
combined prerequisites drive the Medium rating; they do not refute the technical evidence. The
[Audit Register](/docs/audit) carries the measurements and current disposition, and LMV-09 remains
material until remediated and independently retested.

Round 34 also confirmed **Medium / Open LMV-11**. Under a conditional multi-class sequence, a
global prepayment ledger can let a later realized credit loss consume junior capital previously
drawn against an unrelated reversible mark. The fork shifted about **261,069 USDfr** between
curator classes while depositor value, aggregate junior capital, supply and backing all remained
unchanged. It requires an approved curator, substantial compliant liquidity and legitimate
governance, default and signed-loss events; those prerequisites and the absence of depositor loss
support Medium rather than High.

Round 35 attacked the boundary between a fixed queue claim and the direct-redemption junior draw.
With both callers deliberately accepting any sub-par price, first position shifted about
**10,293 USDC** between them while aggregate value stayed unchanged. The protection control used
the same one-argument route as the frontend: its built-in par floor rejected the post-front-run
haircut without burning the claimant's USDfr or moving USDC. The attempted forced-loss property
therefore held and no new finding opened.

Round 36 tested a harder self-financing route across deployed Aave, the open-executor timelock,
MintRedeemController and uncapped sGROVE coverage. The optimized attack borrowed about
**2.509m USDC**, executed a ready 5m-USDfr impairment, funded coverage and made a pre-existing
4m-USDfr exit whole. It nevertheless finished about **547,939 USDC worse** than the same no-flash
exit. The difference remained as additional protocol backing plus Aave's fee, so the attempted
self-rescue held and no new finding opened.

Round 37 tested a split-version governance boundary. During an authorized custody transfer, an
untrusted ERC-721 receiver publicly executed the exact ready FRV-005 installation while the old
ClaimBridge implementation remained on the call stack. The unusual ordering was reachable, but
the attacked and orderly branches ended at the exact same complete protocol-state hash: all five
implementation slots, facility and queue state, supply, backing, impairment and accrual state
matched, mixed-interest activation remained off and no value moved. No new finding opened.

Round 38 tried to manufacture governance quorum by voting three times with the same 21m-GROVE
position. After its valid first ballot, the position moved to a fresh delegated wallet and then
into sGROVE delegated to a third identity, all without advancing the timestamp. All three ballots
were accepted, but the two later identities had zero weight at the frozen proposal snapshot. The
final tally stayed at 21m against the live 40m quorum and the proposal was defeated. No new finding
opened.

Round 39 confirmed **Medium / Open LMV-12**. A compliant contract borrowed `15,292.524153` USDC
from deployed Aave, minted immediately before public execution of a ready 5m-USDfr impairment and
redeemed immediately afterward. The `7.646263`-USDC premium forced an irreversible burn of about
**500,001 USDfr of live junior capital** while all temporary principal returned. A second
cross-class proof paid `119.911678` USDC in premium, generated almost 500,000 USDfr of global
prepayment and later preserved about **300,000.08 USDfr** of the attacking curator's class-B claim
at the exact aggregate expense of unrelated live curator pools. Depositor value, backing and
aggregate junior burn matched control. The rating remains Medium because the immediate path is
non-profitable junior-layer sabotage; the profitable extension needs approved-curator status and
legitimate future loss events, and the preserved claim remains default-frozen and
jurisdiction-blockable before withdrawal.

Round 40 attacked the exact queued FRV-005 installation across two unresolved loss states. A
roleless account executed all five proxy upgrades while a measured **1,000-USDC custody shortfall**
was armed but not yet ratified, and separately after genuine facility default declaration but
before a signed **1,000-USDfr loss** was realized. In both cases the complete pending state was
unchanged across installation, and resolution under new code matched old-code-first control
exactly. The executor gained nothing, backing held and no depositor value moved.

Round 41 attacked a different upgrade seam: genuine `PaymentReceived` and `TermsAmended` facts
were quorum-recorded for live facility 11 while the old implementations remained installed, then
a roleless account executed exact FRV-005 before the ordinary authorized consumer acted. The
**964.968171-USDfr** interest receipt and the **1-bps** prospective rate amendment retained
identical meaning and one-shot state. Both branches matched old-code-first controls across debt,
cash, fees, yield, exposure, supply, backing, vault and impairment state. The executor gained
nothing and no depositor value moved.

Round 42 carried the one-second PIK-entry share difference through canonical Uniswap V2 Router02
and the deployed sUSDfr/USDC pool. Across 50, 500 and 5,000 USDfr trades, entry before the five
public PIK services increased sale proceeds by only `$0.000001`, `$0.000005` and `$0.000034` over
time-matched post-service entry. Those trades still lost `$0.423083`, `$12.924008` and
`$855.897501` respectively versus primary redemption. The route was reachable but economically
negative; no depositor loss or new finding occurred, and the separate generic R14-02 risk remains
open.

Round 43 opened a genuine signed margin call on live MTM facility 1 and reversed exact FRV-005
installation around both a signed cure and an expired-call liquidation. The curing 6,400-bps mark
and continuing-breach 7,250-bps mark each produced the exact same complete terminal state whether
consumed before or after installation. The standing deadline and every measured oracle, facility,
debt, accrual, default, impairment, supply, backing and reserve-cash field were preserved. The
roleless executor gained nothing, no depositor value moved and no new finding opened.

Round 44 challenged the practical blacklist against the deployed secondary market. Removing only
the holder's primary-market KYC entry left existing sUSDfr transferable by design, and the holder
sold through canonical Router02. From the identical snapshot, applying the separate jurisdiction
block stopped direct holder transfer, direct pair transfer and complete router cash-out before any
value or pool reserve moved. This validates the on-chain blacklist once applied; it does not claim
that off-chain monitoring will always identify and block a participant before a transaction.

Round 45 confirmed **Medium / Open LMV-13** at the boundary of that address-level control. A
holder first placed sUSDfr and USDC into the public pool and received its separate bearer LP
token. After the LP owner was blocked, withdrawal back to that owner failed, but Router02 could
redeem the LP token to an unblocked recipient and route about **1,998.68 USDfr-equivalent**. No
depositor value or protocol accounting moved. The finding records a general composability limit:
address blocking cannot freeze external wrappers created before enforcement, so monitoring and
public descriptions must not imply otherwise.

Round 46 tested whether a publicly confirmed signed MTM liquidation could be externalized through
the deployed pool. The external pair quoted exactly the same **4,151.682544 USDC** before and after
a fork-only 2m-USDfr facility default, even though conservative value of the sold shares had fallen
to about **2,642.52 USDfr**. That transferred marked exposure to LP holders, as ordinary AMM price
discovery permits, but did not create profit: the seller remained **848.317456 USDfr worse** than
its acquisition basis. Remaining depositor value and every measured protocol accounting field were
unchanged. No protocol finding opened; the evidence makes explicit that pool spot price is not a
synchronous NAV oracle and LPs bear external market risk.

Round 47 tested a split-version execution boundary around the exact live-approved FRV-007 token
upgrade. The deployed pair delivered **100 sUSDfr** under the old implementation; a roleless
borrower executed both reviewed proxy upgrades from `uniswapV2Call`; and repayment used new code
before the pair completed its invariant check. The borrower paid the normal
**0.300902708124373119358075-share fee**. Pair reserves and invariant, proxy state, token supply,
vault assets, backing, PointsModule state and attacker wealth matched upgrade-before-swap control
exactly. The ordering was reachable but no finding opened.

Round 48 tested whether public overdue marks could reproduce Round 39's junior-capital damage
without a governance principal write-down. A compliant contract borrowed **6m USDC** from deployed
Aave, minted USDfr, called all five first-legally-available live cash-facility marks inside the
callback, directly redeemed and repaid Aave. The marks recorded about **2.721m USDfr** of raw
past-due exposure and **1.110m USDfr** of conservative senior impairment, but did not change
custody backing. The controller burned **zero** junior capital, created zero exit prepayment and
matched the mark-only terminal state exactly. The actor retained no USDfr and paid the
**3,000-USDC** premium, so the attempted public-trigger amplification held and no finding opened.

Round 49 tested whether temporary capital could capture already-earned continuous income as it
moved from virtual accounting into physical USDfr. Across real Aave loans of **50, 500 and 5,000
USDC**, the callback minted and deposited before permissionless delivery of about **11,063.58
USDfr**, sold every share through the deployed pair and repaid the loan. The control delivered the
same income before entry. Both orderings minted identical shares and received identical cash, so
the timing advantage was zero; the actor instead lost **0.381304, 12.529447 and 853.732559 USDC**.
Complete protocol accounting matched and no finding opened.

Round 50 tested the informed-borrower cash-receipt sandwich. A genuine borrower used its facility
proceeds to enter sUSDfr immediately before its own two-attester **5,833.333333-USDC** interest
receipt, then sold every temporary share through the deployed pair. Across **50, 500 and 5,000
USDC**, entry-first and receipt-first controls received identical native USDC. The timing advantage
was zero, the pre-receipt entrant received slightly fewer shares, incumbents were not diluted and
the largest trade lost **924.476558 USDC** excluding the genuine payment. No finding opened.

Round 51 attacked PointsModule's exact-time loss boundary. Two separate class-3 facilities took
authenticated losses of **200,000 and 300,000 USDfr** at the same block timestamp. A roleless
caller reconciled an aged 1m-USDfr curator between the losses; the control reconciled only after
both. Each branch recorded two loss epochs and ended with identical 500,000-USDfr live and tracked
curator capital, points, facility faces, supply, backing and vault state. No destroyed capital
retained points and no finding opened.

Round 52 confirmed **Medium / Open LMV-14**. Seven fully attested Pending facilities temporarily
added **94m USDfr** to the concentration denominator, allowing a **16m-USDfr** target that the same
live state rejected directly to pass. Cancelling every filler left that target at **76.1754%** of
the remaining loan book with zero headroom, but the funding gate still activated it and sent
**15.68m USDC**. This is not available to an external attacker: it needs the Operations Safe,
valid attestation packages for all eight facilities, substantial future liquidity and departure
from the required atomic origination/funding procedure. It can nevertheless expose future
depositor capital to excess single-borrower concentration, so it remains open below High.

Round 53 tested whether an ordinary holder could enter immediately before genuine facility
funding and capture the borrower's separately capitalized origination fee. The production path
retained and capitalized **2,000 USDfr**, minted it to the configured fee Safe and sent **98,000
USDC** to the sole approved funding recipient. Across **50, 500 and 5,000 USDC** of temporary
entry, entry-first and funding-first controls minted exactly the same shares and sold them for
exactly the same cash through the deployed pool. Attacker advantage and incumbent-value difference
were zero; the largest market round trip instead lost **848.317456 USDC**. Every measured facility,
reserve, supply, accrual, vault and pair field converged, so no finding opened.

Round 54 confirmed **Low / Open LMV-15** at the realized-loss/external-market boundary. Healthy
and confirmed-but-unrealized-default routes could not repay the tested cross-token flash swap.
After an authorized full **2m-USDfr** loss realization, an ordinary allowlisted contract starting
with no assets borrowed USDC from the treasury-owned deployed pair, minted and deposited at the
lower realized NAV, repaid that pair in newly minted sUSDfr and sold its surplus shares. The
near-optimal **4,947-USDC** branch finished **1,846.270364 USDC** positive, exactly matching the
treasury LP position's fair-value loss. Existing depositor value changed by zero and supply
remained backed. This is standard constant-product adverse selection and a treasury-liquidity
operating risk, not a depositor-loss or insolvency finding; treasury liquidity should be removed
or repriced before material loss realization.

Round 55 tested whether permissionless execution of the exact already-approved **FRV-005** upgrade
could change a legacy facility's first funding. A fully attested **100,000-USDfr** cash facility
was originated Pending under old code. A roleless executor installed FRV-005 before funding; the
control funded under old code and upgraded afterwards. Both paths paid the sole approved recipient
**98,000 USDC**, minted the same **2,000-USDfr** fee and ended at the exact same complete
protocol-state hash across implementations, debt, exposure, facts, accrual, reserve, backing,
impairment and vault state. The executor gained no asset or role, so no finding opened.

Round 56 tested a strictly novel external-integration boundary and confirmed a distinct extension
of **Medium / Open LMV-13**. The scenario required the actor to pre-position its own value before
enforcement. Depositor value, token supplies, vault assets, backing and protocol accounting
remained unchanged. Exact operational mechanics remain in the private attack ledger while the
affected integration is live.

Round 57 challenged a second deployed external-market architecture and confirmed another
strictly novel extension of **Medium / Open LMV-13**. The actor again had to pre-position its own
value before enforcement, the external claim remained fully backed, and depositor value, supply,
backing, reserve cash and vault assets remained unchanged. Exact operational mechanics and
negative controls remain in the private attack ledger while the integration is live.

Round 58 tested a new external-liquidity boundary around a severe, authorized credit-state change
and confirmed **Medium / Open LMV-16**. Two strictly novel cross-contract scenarios reproduced a
material transfer from a Forest Road-operated external position, including an economically
interested existing-holder differential. Depositor value was not harmed, reserve cash and backing
reconciled, and the holder still bore a large absolute credit loss. Exact mechanics, amounts and
controls remain private while the affected integration is live.

Round 59 then tested a strictly novel stressed-loss settlement boundary. Its initial
**High / Open LMV-17** classification was withdrawn after review showed that the mark-first control
bypassed the remaining sUSDfr loss layer and the mandatory frozen G3 remedy. The six-figure
differential was therefore an artifact of an invalid control, not an attacker-reachable finding.
The attempt still counts as a novel scenario and its refutation is retained in the canonical
ledger.

Round 60 tested whether an approved smart-contract recipient could redirect a live facility during
its ERC-721 receipt callback. The callback was reached after ownership changed, but the
unauthorized nested custody hop was rejected. The approved outer transfer completed and facility
state, principal, deployed balance, backing, supply and exposure accounting remained exact. No
finding opened.

Round 61 tested whether an unrelated open-executor caller could create inconsistent protocol state
by reversing two independently approved live upgrades after both timelock delays elapsed. Both
orders installed the same seven reviewed implementations and converged exactly across governance
state, roles, bindings, accounting, exposure, supply, backing, the live queue and participation
points after ordinary mint, vault-deposit and token-transfer operations. The caller gained nothing
and no finding opened.

Round 62 tested whether an unrelated caller could exploit the persistent intermediate state made
by processing only part of simultaneous mixed-interest accounting work. Fourteen price- or
value-bearing paths refused the incomplete frontier atomically. Public maintenance completed the
remaining work, ordinary operations resumed, and the result matched uninterrupted maintenance
exactly with zero caller gain. No finding opened.

Round 63 crossed that deliberately incomplete accounting frontier into a deployed secondary
market. An ordinary holder's material sale returned exactly the same proceeds whether public
maintenance completed before or after it. Market reserves, balances, participation points,
facilities, supply, backing, vault value and accrual state all converged; no incremental value or
depositor loss arose and no finding opened.

Round 64 combined external atomic liquidity, both deployed Forest Road markets and primary vault
entry into one circular-arbitrage attempt. Every tested size lost value after lender and market
costs, with losses increasing as trades grew. The actor retained no protocol token, USDfr supply
and reserve backing stayed fixed, and existing vault shares were not diluted. No finding opened.

Round 65 removed external lending and starting capital from a different market composition. It
tested whether transaction-local settlement in the deployed USDfr market could finance the exact
primary conversion owed back to that market. The only value captured was the external market's
tiny pre-existing price difference—about three cents at the best tested size—and larger sizes
eliminated it. The reserve received full value for every USDfr issued, supply and backing moved
together, and sUSDfr depositor value was unchanged. This was ordinary market price normalization,
not a protocol finding.

Round 66 attacked the reverse direction: acquire USDfr through the deployed market before paying
for it, redeem against the primary reserve and try to settle the market entirely from that
redemption. None of 24 tested sizes could complete without the participant adding value; the
shortfall increased with size. Complete diagnostic settlements retired the matching USDfr
liability, kept supply and backing aligned and left sUSDfr depositor value unchanged. No finding
opened.

Round 67 timed an already-approved token implementation change during the real five-request
redemption process. Splitting the requests across old and new reviewed implementations produced
the same request credits, queue custody, supply, vault value, reserve backing and participation-
points state as completing settlement before the change. Every request settled, the unrelated
executor gained no asset and no finding opened.

Round 68 moved that reviewed change to a separate custody boundary: after all five real
redemptions had been credited but before their owners withdrew. Every claim paid identically, all
requests cleared, and queue custody, owner balances, token supply, vault value, reserve backing and
participation points converged. The unrelated executor gained no asset and no finding opened.

Round 69 moved a separate approved credit-system change onto a real scheduled-accounting boundary.
Five live loan schedules produced exactly the same debt and claim accounting whether their due
work was processed immediately before or after the change. Both paths then settled and paid six
redemption requests identically and returned the same USDC through primary redemption. Facility,
registry, risk, token, vault, queue, reserve, backing and participation records converged; the
unrelated executor gained no asset and no finding opened.

Round 70 crossed a pending user authorization with the approved token implementation change. A
genuine USDfr permit signed under old code remained valid exactly once after the change, only for
its signed spender and amount. Its nonce advanced once, its allowance was consumed, replay failed
without mutation, and delegated vault shares, balances, participation records, supply and reserve
backing matched authorization-before-change control. The unrelated executor gained no asset and no
finding opened.

Round 71 crossed a partially completed mixed-loan accounting boundary with a separately
authenticated full loan loss and the depositor exit path. The loss refused the incomplete global
frontier atomically and retained its authorization. After maintenance completed, both paths
recognized the same loss, applied the same intended junior-then-sUSDfr waterfall, credited the same
queue claim, returned the same USDC and converged across facility, reserve, backing, risk, token,
vault and queue state. The unrelated caller gained no asset and no finding opened.

Round 72 crossed the exact approved USDfr/sUSDfr implementation change with a genuine
authenticated three-layer loss and depositor exit. Executing the change immediately before rather
than immediately after realization consumed the same curator capital, sGROVE coverage and sUSDfr
assets in the intended order and conserved the exact loss. Both paths credited the same queue
claim, returned the same USDC and converged across facility, commitment, reserve, backing, token,
vault, queue and participation records. The unrelated executor gained no asset and no finding
opened.

Round 73 tested whether cumulative per-call rounding could turn one large marked-book redemption
into a profitable thousand-way split or shift value from an independent depositor. The split route
paid exactly the same **512,000 USDC** as one aggregate redemption and exhausted the same curator
capital. Its additional protocol-backstop draw was only **0.000000000000000771 USDfr**. After the
same valuation release, the independent depositor received the same partial queue claim, retained
the same queued remainder and redeemed the same **2,545.907488 USDC**. Vault assets, senior
shortfall, supply and backing remained protected, so no finding opened.

Round 74 tested whether a genuine loan-loss cascade could consume streamed sGROVE rewards or
assign them to the wrong holder while the complete active stake moved between two accounts. Each
holder received exactly its earned half of the **604,800-USDfr** stream. The real **400,000-USDfr**
loss used exactly the intended curator, protocol-backstop and sUSDfr layers without touching the
reward liabilities. An independent depositor then received the same
**19,345.168176996527273644-USDfr** queue claim and **19,345.168176 USDC** payout in both
orderings. Supply and backing remained protected, so no finding opened.

Round 75 confirmed **Medium / Open LMV-18**. After genuine curator and protocol-backstop capital
absorbed **250,000 USDfr** of a loan loss, the next vault fee calculation treated that contributed
protection as performance and issued fee shares worth almost exactly **25,000 USDfr** at the
current 10% rate. The independent queued position lost about **153.26 USDfr** of immediate value.
The public caller received nothing, could not create the authenticated loss, and supply and backing
remained protected. Those constraints keep the finding below High, but the depositor dilution is
material and remains open pending remediation and independent retesting.

Round 76 tested whether that fee behavior was a general consequence of junior protection absorbing
losses. A separate **1,000,000-USDfr native custody loss** consumed **600,001 USDfr** of global
curator capital, **150,000 USDfr** of protocol backstop and **249,999 USDfr** of senior vault
assets. The post-loss checkpoint issued no performance-fee shares, the independent depositor was
unchanged and both orderings converged exactly. No finding opened. This confines the observed
LMV-18 behavior to the facility-loss accounting path rather than junior loss absorption generally.

Round 77 challenged repeated-transition and cumulative-rounding behavior by splitting that same
total custody loss into 128 separately measured incidents. The repeated path created 231
participation-loss records versus three in the one-shot control, but reconciled to identical fee,
class, protection-layer and backing state. The independent depositor received the same
**22,352.732427-USDC** payout in both paths, so no finding opened.

Round 78 executed the exact approved USDfr/sUSDfr update and attacked its replacement points-hook
gas policy at the caller-selected commit boundary. The first cold successful transfers occurred at
**186,324 gas for USDfr** and **195,201 gas for sUSDfr**; each attempt one gas lower failed
atomically, while every successful call updated both participation positions exactly. Low-gas and
normal-gas paths then accrued identical 30-day points, credited the same
**18,777.907495511719781884-USDfr** queue claim, paid **18,777.907495 USDC** and converged across
token, vault, reserve, queue, points and governance state. No finding opened.

Round 79 challenged a quorum-authenticated prospective mixed cash/PIK amendment between two chunks
of one live redemption settlement after executing the exact approved mixed-interest update. The
control and attack kept identical chunk boundaries and carried two equal **50,000-USDfr** positions
through claims and canonical cash exits. Both holders received exactly **50,906.994626 USDC** in
both paths; facility debt, USDfr supply and reserve backing were exact, and the largest raw claim
movement was roughly **0.000000000263 USDfr**, below one USDC atom. No finding opened.

Round 80 compared one authenticated **400,000-USDfr** facility loss with two sequential
**200,000-USDfr** facility losses while holding gross impairment and all three loss layers
constant. The mandatory checkpoint between the split losses did not compound LMV-18. It reduced
the measured fee by **26.435807796696831800 USDfr**, and the independent depositor received
**0.162067 USDC more**, not less. Both paths allocated exactly **100,000 / 150,000 / 150,000
USDfr** across curator protection, protocol backstop and sUSDfr, with supply no greater than
backing. No finding opened.

Round 81 challenged the interaction between compliant redemption, protection attribution,
authenticated facility-loss completion and vault fee accounting. Protection was consumed only
once, supply/backing accounting remained coherent and the independent queued depositor was not
harmed. The result reconfirmed an existing **Medium / Open** interaction between LMV-11 and
LMV-18; it did not establish a new root cause or High.

Round 82 challenged an authorized facility-custody operation whose recipient callback completed
scheduled loan accounting before the outer custody call returned. Against an identical
same-timestamp control, facility, schedule, exposure, accrual, supply, backing, vault and
participation-accounting state converged exactly, and the callback recipient gained no value. No
finding opened.

Round 83 held one authenticated risk observation constant while varying its permitted submission
time across ordinary loan accrual. The later submission changed the protective lifecycle action
only after current debt genuinely satisfied the configured condition. The loss followed the
intended **sUSDfr-before-USDfr** ordering, the submitting account gained no value and the stablecoin
remained covered. No finding opened.

Round 84 rehearsed the complete emergency procedure for a loan loss larger than immediately
available absorption capacity. The failed loss attempt left no partial accounting; independent
controller, vault and queue freezes stopped every prepared primary holder path while an
already-settled claim remained payable. An authorized protection-layer top-up then completed the
full loss through sGROVE and sUSDfr, with **zero unstaked USDfr-holder burn** and exact supply,
backing, facility and exposure reconciliation. No finding opened.

Round 85 tested a partial loan recovery after sGROVE had already absorbed an authenticated loss.
Reversing the order of the later cash recovery and remaining loss cleared every loan, commitment,
protection and impairment record, allocated the same **250,000 USDfr** to sGROVE and
**100,000 USDfr** to sUSDfr, and paid the independent queued depositor the same
**19,654.114161 USDC**. Unstaked USDfr holders absorbed zero and no finding opened.

Round 86 tested whether an ordinary caller could combine public overdue-loan accounting with later
income and fee timing to disadvantage depositors. Eight independently underwritten facilities
preserved every production concentration limit while exercising continuous accrual, authenticated
receipts, full cures and the FIFO exit path. The conservative valuation reached the entire
**3,387,822.368608702896663699-USDfr** vault asset base, yet fee crystallization changed the
independent depositor's fee-net quote by zero and both timing paths paid **21,901.500325 USDC**.
No caller gain or depositor loss was established and no finding opened.

Round 87 tested duplicate loan-recovery and resolution attempts after a real loss had consumed
protection capital. Ordinary callers were rejected, repeated recovery callbacks at an unchanged
balance were exact no-ops, and a fresh authenticated receipt after resolution was refused before
its fact was consumed or any cash moved. Both branches cleared every risk record and paid the
independent depositor **19,654.114161 USDC**. A separate direct trusted-module probe reconfirmed an
existing Low revision-only hardening item; it changed no economic state and has no externally
reachable trigger.

Round 88 tested whether splitting the same genuine loan recovery across 64 independently
authenticated receipts could distort accounting after protection capital had already absorbed a
real loss. The fragmented and aggregate paths produced identical recovered principal,
commitments, loss allocation and terminal economics. sGROVE absorbed **250,000 USDfr** before
sUSDfr absorbed **94,000 USDfr**, and both paths paid the independent depositor
**19,691.187679 USDC**. No finding opened.

Round 89 compared the same 64 eligible FIFO withdrawals priced together or one request at a time
under a genuine authenticated impairment, substantial earned income and a live fee checkpoint.
Chunking created no additional fee shares, moved no fee-recipient value and paid depositors the
same **43,266.576552 USDC**. Only 43 wei of claim flooring and 63 wei of fee-hurdle rounding
differed, both conservatively retained and far below one USDC base unit. No finding opened.

Round 90 combined an in-progress multi-request settlement with a deliberately partial scheduled-
loan update. The protocol refused to price the next withdrawal against the half-updated state,
changed no request or settlement value, and retained the live settlement. After the remaining
updates, both schedules paid exactly **122.444322 USDC** and **122.444325 USDC**, reached the same
final state and gave the ordinary caller no asset. No finding opened.

Round 91 tested whether explicitly issuing the fee shares implicated by Medium/Open LMV-18 could
create a separate price jump against deployed external liquidity. A genuine loan loss was absorbed
entirely by curator and sGROVE protection. Fee-adjusted vault pricing had already included the
pending shares: the sUSDfr rate and independent depositor claim were exact across issuance, all
seven tested transaction-local routes failed before and after it, and the caller gained no asset.
No new finding opened; the underlying LMV-18 accounting overcharge remains Medium/Open.

Round 92 tested public execution of an approved prospective fee change immediately before versus
between two chunks of the same in-progress withdrawal settlement. Both schedules produced exact
individual claims, fee components, fee-recipient value and **10,123.594786 USDC** aggregate cash,
then converged across vault, queue, supply, backing, fee-hurdle and governance state. The unrelated
executor gained no asset. No finding opened.

Round 93 tested whether an unrelated relayer could crystallize already-due performance fees
immediately before submitting a genuine adverse signed valuation and atomic liquidation. The
public call changed only same-block checkpoint attribution. Both schedules recorded the same
**512,499 USDfr** senior impairment and paid the depositor **8,995.464662 USDC**. Residual fee and
claim differences were far below one USDC base unit, and the relayer gained no asset. No finding
opened.

Round 94 tested public execution of an already-approved recovery assessment between two
transactions of one FIFO settlement. Pricing the unrelated head request before execution lowered
its complete wealth by about **6,293.88 USDfr**, while the second requester and large stayer gained
about **5,023.58 USDfr**. The actor had committed **9m USDfr before default**, could not create the
default, assessment, governance approval or keeper split, and held no relevant role. This is a new
upward-execution reproduction of the already accepted **Medium G4** pricing-session risk, not a new
root or an attacker-reachable High.

Round 95 executed the exact approved FRV-005 upgrade from inside the receiver callback of an
old-code facility origination, then exercised both funding and cancellation under the new code.
Funding paid the approved recipient and fee exactly; cancellation burned the NFT and released the
full concentration. Both paths matched orderly upgrade-first controls across every measured
ledger, the roleless callback/executor gained no asset, and no finding opened.

Round 96 compared six public physical deliveries over 90 days of mixed-loan accrual with one
aggregate delivery, then continued through the same authenticated **618,000 USDfr** full loss and
an independent depositor's withdrawal. Senior income, protocol fee, loss allocation and the
depositor's **9,440.214108 USDC** payout matched exactly, all measured ledgers converged and the
roleless caller gained nothing. No finding opened.

Round 97 tested whether a normal sub-USDC payment-rounding draw against loss protection could
leave a more optimistic recovery assessment usable when the ordinary impairment version stayed
fixed. The assessment's independent capacity check invalidated it immediately. Automatic
conservative fallback and an explicit governance clear both paid the depositor **9,191.400311
USDC**, all measured ledgers converged, and no finding opened.

Round 98 tested whether public execution of an already-approved continuous-accrual fee-recipient
rotation could redirect historical fees or change depositor value when it landed during a live
withdrawal settlement. The outgoing recipient received its full pre-rotation entitlement, the
approved replacement received only subsequently earned fees, and execution on either side of the
first settlement chunk produced identical claims and an identical **10,123.847026 USDC** aggregate
payout. The executor gained nothing and no finding opened.

Round 99 tested whether public execution of an already-approved one-day withdrawal-cooldown
increase could corrupt an in-progress settlement after its first depositor had been paid. The next
FIFO request became eligible one day later, as approved, but was neither skipped nor stranded: the
old budget released, the same request settled normally at its governed deadline, aggregate value
and backing remained conserved, and the delayed holder received the intervening return. The
executor gained nothing and no finding opened.

Round 100 tested a different governance boundary: whether tightening a borrower's concentration
limit after a facility entered Pending would stop later funding. Applying the new limit first
correctly rejected the facility. Applying it after admission reported the facility over limit with
zero headroom, but the funding gate still deployed it. This confirms a new consequence path for
Medium/Open LMV-14, not a new finding: governance, authorized origination and servicing, and valid
facility attestations are required, backing remained intact, and any depositor loss would still
depend on later borrower underperformance. The funding gate should nevertheless enforce the
current risk policy before capital leaves the reserve.

Round 101 tested whether extending a class's valuation-freshness window could make an older,
previously expired valuation usable again. It could, but only because the newly approved policy
expressly accepted that age. A fresh quorum-backed control at the same value produced identical
impairment, depositor claim, cash payout and terminal economics; backing held and the public
executor gained nothing. No finding opened. The result nevertheless adds a concrete operating
safeguard: refresh affected live valuations whenever governance widens their freshness window, or
make the change prospective.

Round 102 tested a stronger governance composition: an approved past-due risk-weight increase and
assessment clear were ready as separate operations while an eligible withdrawal stood. Executing
the weight but delaying the clear until immediately after settlement transferred about
**20,064.46 USDfr** from aggregate remaining redemption value to the exiting holder. This is a new
consequence of the already accepted Medium G4 pricing-session risk, not a new root or High:
governance must approve every state change, a keeper must settle inside a publicly closable gap,
and the KYC beneficiary is identifiable. Operations must batch every such weight increase and
assessment clear atomically.

Round 103 tested whether a later governance decision to lower a marked-to-market class's maximum
draw ratio reaches a facility that is approved but still unfunded. The new ceiling rejected
identical fresh terms, but the Pending facility still passed the funding gate, paid **98,000
USDC** to the approved recipient and became Active at five times the current ceiling. This extends
the existing Medium funding-time policy-revalidation finding, not a High: governance, authorized
origination and servicing, and genuine facility and valuation attestations are required; backing
remained intact and depositor loss would require later facility underperformance. The protocol
should either revalidate current class policy before funding or record explicit, auditable
grandfathering.

Round 104 exercised the planned, not-yet-deployed Morpho USDC/sUSDfr integration against real
mainnet state and deployed market liquidity. A newly valid public overdue mark invalidated a
professional assessment, materially repriced an unrelated borrower's collateral, enabled full
liquidation and left residual bad debt with the fork-only lender. This is a new external-market
consequence of the already disclosed **Medium / Accepted M-2** assessment-invalidation risk, not a
new root or live High. No current Forest Road depositor funds were exposed, and the integration
remains behind its monitoring, liquidity, disclosure and parameter launch gates.

Round 105 attacked the exact first five-facility cash-payment package by publicly submitting its
five genuine signed facts before the reviewed Operations Safe transaction. The original package
then failed, validating the runbook's confidentiality and private-relay controls. The stronger
attack did not succeed: the Safe nonce and payer cash remained untouched, and a replacement Safe
package reused every recorded fact without new attester signatures, settled exactly **7,948.590854
USDC** and matched normal terminal economics. The outsider gained nothing. This is a novel
recovery rehearsal and held control, not a contract finding or High.

Round 106 attacked a mixed-interest payment one second before its shared PIK capitalization date
and compared it with one aggregate receipt immediately after public capitalization. Both branches
continued through default, the full curator-to-sGROVE-to-sUSDfr waterfall, an independent FIFO
claim and canonical USDC redemption. Each capitalized exactly **12,000 USDfr**, reached and lost
the same **512,000-USDfr** face and cleared exposure. Paying principal one second earlier saved
only the correct **$0.000129** of cash interest; sub-micro-dollar allocation dust changed the
independent depositor's final cash payout by one native USDC unit. The roleless caller gained
nothing. This is a novel held full-system result, not a finding or High.

Round 107 attacked the planned external-lending integration by having an approved curator post
first-loss capital, borrow canonical USDC against the improved sUSDfr exit-value oracle and then
try to reclaim the support. Freely withdrawable capital moved the oracle by zero. Capital that did
move it increased borrowing power by only **86.270546 USDC** while locking **44,611.737234 USDfr**
in the marked class; the withdrawal failed with zero headroom and the Morpho position remained
healthy. This is a held external-consumer bypass test, not a new root or High. The oracle and
market are not deployed, so it is not current depositor exposure.

## Live acceptance

A funded mainnet canary completed USDfr minting and transfer, sUSDfr deposit and transfer, direct
USDfr redemption and sUSDfr queue entry. Supply equalled recognized backing, and physical USDC in
ReserveManager equalled its idle ledger.

The operations Safe then blocked the canary by jurisdiction. USDfr and sUSDfr transfers, minting
and redemption refused the blocked wallet; one signed transfer was mined with failed status and no
value movement. Unrelated wallets and protocol burn legs remained available. The Safe cleared the
block, the wallet's retained allowlist status became effective again, and the temporary drill
balance redeemed for exactly 1 USDC.

The queue request remains in its contractually required 21-day cooldown until 12 October 2026.
The full settlement and claim sequence has passed on a fork, while its live settlement remains a
scheduled observation rather than a completed claim.

## Recent review history

The Audit Register now includes the September review sequence:

- the 13 September Corrovera dual-chain ensemble, which read 125 source files individually and
  explicitly did not establish dependency closure or review deployment scripts;
- the 17 September Corrovera diff review and its follow-up probes over the accrual, impairment,
  custody and legacy-default changes;
- the 18 September internal Solana and curator correctness review;
- the 20 September Corrovera curator-vault review and its remediation verification;
- the 20 September internal review of the exact Ethereum V2 deployment on forked mainnet state;
  and
- 76 post-launch strict-novelty attack rounds through 29 September, followed by the
  outcome-independent LMV-09 technical-impact adjudication and owner-adjusted disposition.

The 13 September headline claim count is not presented as 317 confirmed defects. It was a claim
corpus: reviewers agreed on some claims, disagreed on others, and many depended on context that a
one-file review could not see. Later dependency-aware checks refuted the two proposed Highs,
confirmed and corrected the supported Mediums, and retained the scope limitation in the public
record.

The Solana curator vault is a separate product surface. Its canonical artifact is active and
verified on devnet; no Solana mainnet deployment has occurred. Its audit history must not be read
as assurance for the Ethereum contracts, or vice versa.

## Accepted and operational residuals

No new Critical, High or Medium contract defect was confirmed by the 20 September
deployed-Ethereum review. Subsequent post-launch testing initially classified LMV-17 as High/Open,
then withdrew it after its control was shown to bypass the intended loss waterfall and G3 remedy.
It also confirmed LMV-09's mechanism and High
technical impact; its owner-adjusted current disposition is Medium / Open because practical
likelihood is very low. It also confirmed Medium/Open LMV-11's conditional cross-curator
attribution defect, Medium/Open LMV-14's authorized Pending-denominator concentration bypass and
Medium/Open LMV-18's charge on consumed junior protection.
The following limits remain relevant:

- The accepted G3 procedure requires the controller, sUSDfr vault and redemption queue to be
  paused before an over-capacity loss attestation, with paths kept frozen through recapitalization
  or an independently reviewed accounting remedy. Round 59 did not establish a defect in that
  procedure.
- LMV-09 permits material third-party loss through the live redemption queue under the conditions
  described above. It is not fixed by the keeper gate and remains open pending containment or code
  remediation and independent retesting.
- LMV-11 can shift a later realized credit loss between curator classes after an unrelated
  reversible mark generated global prepaid absorption. The proof did not reduce depositor value or
  aggregate junior capital, but the class-specific loss promise remains open pending remediation
  and independent retesting.
- LMV-14 can leave a Pending facility fundable after cancellation of unrelated commitments moves
  it above its concentration limit, or after governance reduces that limit while it remains
  Pending. It requires authorized operations and valid attestations; the governance path also
  requires an approved policy change. Funding should revalidate the current limit before capital
  leaves the reserve.
- LMV-16 can transfer value out of Forest Road-operated external liquidity around a severe,
  authorized credit-state change. It does not take depositor funds, but the external position
  should be protected as part of the operating procedure for material credit-state changes.
- LMV-18 can charge sUSDfr holders a performance fee when curator and sGROVE protection absorbs a
  genuine loss. The caller cannot receive the fee, but the depositor dilution remains open pending
  remediation and independent retesting.
- If curator capital, sGROVE coverage and senior assets are all exhausted, a close can leave a
  remainder smaller than one USDC base unit. Value-sensitive operations fail closed. A funded
  worker may supply the exact correction under per-payment, daily and count limits.
- Repeated protocol-fee withholding during a standing senior impairment can reduce protocol
  revenue by more than the initial impairment. It favors senior backing and cannot extract senior
  assets.
- Live acceptance ran with an empty credit book; no synthetic loan was created to produce a launch
  receipt. Real facilities have been originated since 21 September 2026, each through the same
  attestation gate with its own documents, attester quorum and capital. See
  [Live deployment status](/docs/status).
- Module-wide Guardian pause/unpause has fork evidence but no recorded live Safe drill. The
  wallet-specific jurisdiction drill is complete and is a different control.
- Both marked-to-market keepers currently share Railway under an owner-accepted temporary hosting
  decision. This is a common administrative and hosting failure domain.

## Trust boundaries

Two valid attester signatures can establish any off-chain fact the accounting consumes. Credit
terms, payments, defaults, cures, losses, valuations and amendments each need two; the assignment
and lien-filing facts need one. The contracts enforce signer ordering, quorum, payload binding,
expiry and replay protection, but cannot inspect a legal document or independently prove that an
off-chain payment occurred.

The operations Safe controls KYC, operational servicing and emergency user-path pauses. It cannot
upgrade contracts or satisfy the attester quorum by itself. Timelocked governance can change
implementations and governed parameters after the voting and delay process. Canonical USDC,
Ethereum execution, RPC availability and keeper funding remain external dependencies.

Continuous accrual recognizes earned cash and PIK interest before receipt. It uses frozen facility
bases and constant-time aggregates. Lifecycle transactions checkpoint before changing a basis,
rate or earning status; differential and stateful tests compare those aggregates with independent
reference models over long event sequences.

## Reporting a vulnerability

Email **jevans@forestroad.com** and report privately rather than opening a public issue for a
problem that may affect deployed contracts or user funds. Include the affected contract and
function, the conditions needed to reach the behavior, its likely impact and, where possible, a
minimal test on a local deployment or fork.

Please do not test by moving another person's assets, accessing data that is not yours, or
degrading the live service. Findings that survive validation are added to the Audit Register with
their severity and disposition, including accepted findings.
