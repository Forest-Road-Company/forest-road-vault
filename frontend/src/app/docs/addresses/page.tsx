import type {Metadata} from "next";
import Link from "next/link";
import {PageShell} from "@/components/site/PageShell";
import {
  CHAIN_ID,
  CONTRACTS,
  EXPLORER_BASE_URL,
  IS_MAINNET,
  IS_TESTNET,
  NETWORK_NAME,
  PROTOCOL_DEPLOYMENT_BLOCK,
  type ContractName,
} from "@/config/contracts";

export const metadata: Metadata = {
  title: "Deployed Addresses | Forest Road Vault",
  description:
    "Every Forest Road Vault contract address, what each contract does, and the USDfr/USDC market, with block-explorer links.",
};

/**
 * What each contract does, in a reader's terms.
 *
 * This map is prose only: the addresses come from CONTRACTS, the same typed configuration the
 * application calls, and the production build gate checks every one of them against the approved
 * deployment manifest, so this page cannot show a stale address.
 */
const ROLE: Record<ContractName, string> = {
  USDfr:
    "The stablecoin. Minted 1:1 against USDC and redeemable back to USDC. Holding USDfr earns no yield by itself.",
  sUSDfr:
    "The yield vault (ERC-4626). Stake USDfr to receive sUSDfr, whose exchange rate rises as loan interest is earned. Exits go through the redemption queue.",
  GROVE:
    "The governance token. Fixed supply, minted in full to the Forest Road treasury. It carries voting rights and sGROVE staking eligibility, and no automatic right to protocol revenue.",
  sGROVE:
    "The second loss layer. It holds the USDfr coverage reserve that absorbs losses after curator first-loss capital and before senior sUSDfr principal. GROVE can be staked here too; staked GROVE keeps its vote and is never sold to cover a loss.",
  USDC: "Circle's USD Coin. The reserve asset used to mint USDfr and paid out on redemption.",
  MintRedeemController:
    "Mints and burns USDfr, and enforces the backing invariant on every mint: USDfr supply can never exceed the reserves and loans behind it.",
  ReserveManager:
    "Custodies the protocol's USDC, records deployed loan principal at conservative marks, and runs continuous interest accrual across the loan book. USDC sent to it directly is treated as a donation and never inflates backing.",
  RedemptionQueue:
    "The sUSDfr exit. Requests wait out a minimum hold, then settle strictly first-in, first-out within each settlement's liquidity budget, at the price struck when they fill. Settled requests are claimed in USDfr.",
  ComplianceRegistry:
    "Holds the KYC allowlist for minting and instant redemption, the sanctions and jurisdiction blocklist screened on every transfer, and the governance-approved list of loan payout destinations.",
  ClaimBridge:
    "Issues the Loan NFT for each facility once its required attestations are in place, and holds the facility's signed terms: amount, rates, schedule and payout destination.",
  AttestationOracle:
    "Verifies threshold-signed attestations from the approved m-of-n attester set. Originations, payments, valuations and terms changes all enter through it. This is the protocol's main trust assumption: it acts on whatever an attester quorum signs.",
  CollateralRegistry:
    "The book's rulebook: collateral classes, loan-to-value and tenor limits, and the borrower, state and class concentration limits every loan must pass.",
  WaterfallEngine:
    "Funds each originated facility from reserves and routes every attested repayment: interest to the protocol fee and the vault, principal back to reserves, with nothing created or lost on the way.",
  DefaultManager:
    "Marks loans past due, declares defaults, runs liquidations and the loss cascade, and computes the impairment that prices vault exits during a default.",
  AssessedImpairmentSource:
    "Carries the professional recovery assessment used to value an impaired loan.",
  MtmAtomicExecutor:
    "Protects digital-asset loans: relays a signed collateral valuation and, in the same transaction, applies the liquidation, margin call or cure the on-chain rules require. Anyone can call it; it holds no authority of its own.",
  CuratorModule:
    "Holds curators' first-loss capital for each collateral class. It absorbs losses first, ahead of sGROVE and senior sUSDfr holders.",
  PointsModule:
    "Accrues participation points on USDfr, sUSDfr and curator capital held over time. Points are not a claim on any asset or token.",
  Governor:
    "Where governance proposals are made and voted on with GROVE. Forest Road holds the GROVE supply, so it controls governance outcomes at launch.",
  Timelock:
    "Executes approved proposals after a mandatory delay, and holds upgrade authority over every upgradeable contract.",
  GroveVotesAggregator:
    "Adds GROVE held in wallets to GROVE staked in sGROVE, so staking never costs a holder their vote. The Governor reads voting power from here.",
};

/** Reading order. A contract missing from every group still renders, under "Other". */
const GROUPS: ReadonlyArray<{title: string; names: readonly ContractName[]}> = [
  {title: "Tokens", names: ["USDfr", "sUSDfr", "GROVE", "sGROVE", "USDC"]},
  {
    title: "Minting, reserves and exits",
    names: ["MintRedeemController", "ReserveManager", "RedemptionQueue", "ComplianceRegistry"],
  },
  {
    title: "Loans",
    names: [
      "ClaimBridge",
      "AttestationOracle",
      "CollateralRegistry",
      "WaterfallEngine",
      "DefaultManager",
      "AssessedImpairmentSource",
      "MtmAtomicExecutor",
    ],
  },
  {title: "Loss protection", names: ["CuratorModule"]},
  {title: "Governance", names: ["Governor", "Timelock", "GroveVotesAggregator"]},
  {title: "Participation", names: ["PointsModule"]},
];

/**
 * The USDfr/USDC market is a third-party Uniswap v4 pool, not a Forest Road deployment, so it is
 * not in the deployment manifest. Verified on chain: USDC is currency0, USDfr currency1, LP fee
 * 375 (0.0375%), tick spacing 4, no hooks, on the canonical v4 PoolManager.
 */
const UNISWAP_POOL = {
  id: "0x72ef9130b1c7bd2daa49405e618b7ad27eb90e03c893629ba1d28a4562fc7b55",
  manager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
  url: "https://app.uniswap.org/explore/pools/ethereum/0x72ef9130b1c7bd2daa49405e618b7ad27eb90e03c893629ba1d28a4562fc7b55",
} as const;

const configured = (name: ContractName) => Boolean(CONTRACTS[name]);
const grouped = new Set(GROUPS.flatMap((group) => group.names));
const SECTIONS = [
  ...GROUPS.map((group) => ({...group, names: group.names.filter(configured)})),
  {
    title: "Other",
    names: (Object.keys(CONTRACTS) as ContractName[]).filter(
      (name) => configured(name) && !grouped.has(name),
    ),
  },
].filter((section) => section.names.length > 0);
const COUNT = SECTIONS.reduce((total, section) => total + section.names.length, 0);

function AddressLink({address}: {address: string}) {
  return EXPLORER_BASE_URL ? (
    <a
      href={`${EXPLORER_BASE_URL}/address/${address}`}
      target="_blank"
      rel="noreferrer"
      className="u-link break-all font-mono text-[12px] leading-relaxed text-ink-muted hover:text-accent"
    >
      {address}
    </a>
  ) : (
    <span className="break-all font-mono text-[12px] leading-relaxed text-ink-muted">{address}</span>
  );
}

const HEAD = "text-[11px] font-semibold uppercase tracking-[0.2em] text-ink-faint";

export default function AddressesPage() {
  return (
    <PageShell
      section="Deployed addresses"
      title="Every contract, and what it does."
      lede={`Generated from the same typed configuration the application itself uses, so nothing here can drift from what the site actually calls. Network: ${NETWORK_NAME} (chain ${CHAIN_ID}).`}
    >
      <div className="mt-10 rounded-card border border-line bg-accent-faint/60 p-5">
        <p className="text-[13.5px] leading-relaxed text-ink-muted">
          {IS_TESTNET ? (
            <>
              <strong className="text-ink">Test deployment.</strong> These are{" "}
              {NETWORK_NAME} addresses. The tokens have no value: the stablecoin is a test
              token, and nothing here is a production deployment. A mainnet build publishes
              its own addresses in this same table.
            </>
          ) : (
            <>
              <strong className="text-ink">Live Ethereum mainnet addresses.</strong> Bootstrap
              authority has been surrendered to timelocked governance and the protocol is
              lending. Minting USDfr and redeeming it instantly for USDC require KYC; holding,
              transferring and staking are open to any wallet that is not sanctions- or
              jurisdiction-blocked. Read the{" "}
              <Link href="/docs/status" className="u-link text-ink">
                live status
              </Link>{" "}
              and the risk disclosures before transacting.
            </>
          )}{" "}
          Proxy addresses are the permanent entry points; implementations sit behind them and
          change on upgrade, so verify state through the proxy. Deployment block{" "}
          <span className="font-mono text-[12.5px]">{PROTOCOL_DEPLOYMENT_BLOCK.toString()}</span>.
        </p>
      </div>

      <div className="mt-10">
        <div className={`hidden gap-6 border-b border-line pb-3 md:grid md:grid-cols-[13rem_1fr_minmax(0,24rem)]`}>
          <span className={HEAD}>Contract</span>
          <span className={HEAD}>What it does</span>
          <span className={HEAD}>Address</span>
        </div>
        {SECTIONS.map((section) => (
          <section key={section.title} aria-labelledby={`group-${section.title}`}>
            <h2
              id={`group-${section.title}`}
              className="mt-8 text-[12px] font-semibold uppercase tracking-[0.16em] text-accent"
            >
              {section.title}
            </h2>
            <ul className="mt-2">
              {section.names.map((name) => (
                <li
                  key={name}
                  className="grid gap-1.5 border-b border-line/60 py-4 md:grid-cols-[13rem_1fr_minmax(0,24rem)] md:gap-6"
                >
                  <span className="text-[13.5px] font-medium text-ink">{name}</span>
                  <span className="text-[13px] leading-relaxed text-ink-muted">{ROLE[name]}</span>
                  <span className="min-w-0">
                    <AddressLink address={CONTRACTS[name]!} />
                  </span>
                </li>
              ))}
            </ul>
          </section>
        ))}

        {IS_MAINNET ? (
          <section aria-labelledby="group-market">
            <h2
              id="group-market"
              className="mt-8 text-[12px] font-semibold uppercase tracking-[0.16em] text-accent"
            >
              Market (third party)
            </h2>
            <ul className="mt-2">
              <li className="grid gap-1.5 border-b border-line/60 py-4 md:grid-cols-[13rem_1fr_minmax(0,24rem)] md:gap-6">
                <span className="text-[13.5px] font-medium text-ink">USDfr/USDC pool</span>
                <span className="text-[13px] leading-relaxed text-ink-muted">
                  A Uniswap v4 pool pairing USDfr with USDC (0.0375% fee, no hooks). Uniswap is
                  independent of Forest Road; its price can differ from the 1:1 mint and redeem
                  rate.{" "}
                  <a href={UNISWAP_POOL.url} target="_blank" rel="noreferrer" className="u-link text-ink">
                    View on Uniswap
                  </a>
                </span>
                <span className="min-w-0 space-y-1">
                  <span className="block text-[11px] uppercase tracking-[0.14em] text-ink-faint">Pool ID</span>
                  <span className="block break-all font-mono text-[12px] leading-relaxed text-ink-muted">
                    {UNISWAP_POOL.id}
                  </span>
                  <span className="block pt-1 text-[11px] uppercase tracking-[0.14em] text-ink-faint">
                    Uniswap v4 PoolManager
                  </span>
                  <AddressLink address={UNISWAP_POOL.manager} />
                </span>
              </li>
            </ul>
          </section>
        ) : null}
      </div>

      <p className="mt-8 text-[13px] leading-relaxed text-ink-faint">
        {COUNT} contracts.{" "}
        {EXPLORER_BASE_URL
          ? "Each address links to the block explorer, where the verified source can be read and every figure on the transparency dashboard reconciled independently."
          : "This local fork has no block explorer."}
      </p>

      <div className="mt-10 flex flex-wrap gap-3">
        <Link
          href="/transparency"
          className="rounded-pill border border-line bg-raised/70 px-5 py-2 text-[13px] text-ink transition-colors hover:border-accent/50"
        >
          Reconcile live state →
        </Link>
        <Link
          href="/docs/audit"
          className="rounded-pill border border-line bg-raised/70 px-5 py-2 text-[13px] text-ink transition-colors hover:border-accent/50"
        >
          Audit register →
        </Link>
      </div>
    </PageShell>
  );
}
