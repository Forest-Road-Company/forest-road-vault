import type {Metadata} from "next";
import Link from "next/link";
import {PageShell} from "@/components/site/PageShell";
import {
  CHAIN_ID,
  CONTRACTS,
  EXPLORER_BASE_URL,
  IS_TESTNET,
  NETWORK_NAME,
  PROTOCOL_DEPLOYMENT_BLOCK,
  type ContractName,
} from "@/config/contracts";

export const metadata: Metadata = {
  title: "Deployed Addresses — Forest Road Vault",
  description:
    "Every deployed contract address this build reads, with its role and a block-explorer link.",
};

/**
 * What each module does, in a reader's terms.
 *
 * This map is prose only — the addresses themselves come from CONTRACTS, so this page
 * cannot show a stale address. A module with no entry here still renders, with its role
 * left blank: the table iterates the deployment config, never this map, so adding a
 * contract to the protocol can never silently drop it off this page.
 */
const ROLE: Partial<Record<ContractName, string>> = {
  USDfr: "The synthetic dollar. Minted 1:1 against approved stablecoins; does not itself yield.",
  sUSDfr:
    "The ERC-4626 yield vault. Stake USDfr here; value accrues through the exchange rate as the book performs.",
  ComplianceRegistry:
    "The KYC gate. Holds the transfer-eligibility set that USDfr and sUSDfr check on every transfer.",
  USDC: "The reserve stablecoin accepted for minting.",
  MintRedeemController:
    "The only path that mints or burns USDfr, and the contract that enforces the backing invariant on every mint.",
  ReserveManager:
    "Custodies idle stablecoin reserves and records deployed principal at conservative marks.",
  RedemptionQueue:
    "The single exit. Strict FIFO with a request-anchored cooldown; settles at the price struck when the epoch closes.",
  ClaimBridge:
    "Represents each funded facility on-chain and holds its terms, including the payment schedule.",
  CollateralRegistry:
    "The book: every facility, its vertical, its class, and the concentration limits an origination cannot breach.",
  CuratorModule:
    "Holds curator first-loss capital per class — the first layer of the loss cascade.",
  WaterfallEngine:
    "Allocates every repayment through the waterfall, and advances a facility's schedule on a performing payment.",
  DefaultManager:
    "Marks facilities past due, declares defaults, runs liquidation, and computes the senior impairment that prices exits.",
  AssessedImpairmentSource:
    "Carries the professional recovery assessment that the vault reads when marking an impaired facility.",
  AttestationOracle:
    "Verifies threshold-signed attestations — valuations, originations and terms changes all enter through here.",
  PointsModule: "Tracks participation points. No claim on protocol assets.",
  GROVE: "The governance token.",
  sGROVE:
    "Staked GROVE. The second layer of the loss cascade, absorbing after curator first-loss and ahead of senior principal.",
  GroveVotesAggregator: "Sums GROVE and sGROVE voting weight for governance.",
  Governor: "Submits and votes on governance proposals.",
  Timelock:
    "Executes passed proposals after their delay, and holds the upgrade authority for every proxy.",
};

const ENTRIES = (Object.entries(CONTRACTS) as Array<[ContractName, string]>).filter(
  ([, address]) => Boolean(address),
);

export default function AddressesPage() {
  return (
    <PageShell
      eyebrow="Deployed addresses"
      title="Every contract this build reads."
      lede={`Generated from the same typed configuration the application itself uses, so nothing here can drift from what the site actually calls. Network: ${NETWORK_NAME} (chain ${CHAIN_ID}).`}
    >
      <div className="mt-10 rounded-card border border-line bg-moss-faint/60 p-5">
        <p className="text-[13.5px] leading-relaxed text-ink-muted">
          {IS_TESTNET ? (
            <>
              <strong className="text-ink">Test deployment.</strong> These are{" "}
              {NETWORK_NAME} addresses. The tokens have no value, the stablecoin is a test
              token, and nothing here is a production deployment. A mainnet build publishes
              its own addresses in this same table.
            </>
          ) : (
            <>
              <strong className="text-ink">Production deployment.</strong> These are live
              Ethereum mainnet addresses.
            </>
          )}{" "}
          Proxy addresses are the permanent entry points; implementations sit behind them
          and change on upgrade, so verify state through the proxy. Deployment block{" "}
          <span className="font-mono text-[12.5px]">
            {PROTOCOL_DEPLOYMENT_BLOCK.toString()}
          </span>
          .
        </p>
      </div>

      <div className="mt-10 overflow-x-auto">
        <table className="w-full border-collapse text-left">
          <thead>
            <tr className="border-b border-line">
              <th className="pb-3 pr-4 font-mono text-[11px] uppercase tracking-[0.2em] text-ink-faint">
                Contract
              </th>
              <th className="pb-3 pr-4 font-mono text-[11px] uppercase tracking-[0.2em] text-ink-faint">
                Address
              </th>
              <th className="pb-3 font-mono text-[11px] uppercase tracking-[0.2em] text-ink-faint">
                Role
              </th>
            </tr>
          </thead>
          <tbody>
            {ENTRIES.map(([name, address]) => (
              <tr key={name} className="border-b border-line/60 align-top">
                <td className="py-4 pr-4 text-[13.5px] font-medium text-ink">{name}</td>
                <td className="py-4 pr-4">
                  {EXPLORER_BASE_URL ? (
                    <a
                      href={`${EXPLORER_BASE_URL}/address/${address}`}
                      target="_blank"
                      rel="noreferrer"
                      className="u-link break-all font-mono text-[12px] leading-relaxed text-ink-muted hover:text-moss"
                    >
                      {address}
                    </a>
                  ) : (
                    <span className="break-all font-mono text-[12px] leading-relaxed text-ink-muted">
                      {address}
                    </span>
                  )}
                </td>
                <td className="py-4 text-[13px] leading-relaxed text-ink-muted">
                  {ROLE[name] ?? "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="mt-8 text-[13px] leading-relaxed text-ink-faint">
        {ENTRIES.length} contracts.{" "}
        {EXPLORER_BASE_URL
          ? "Each address links to the block explorer, where the verified source can be read and every figure on the transparency dashboard reconciled independently."
          : "This local fork has no block explorer."}
      </p>

      <div className="mt-10 flex flex-wrap gap-3">
        <Link
          href="/transparency"
          className="rounded-pill border border-line bg-raised/70 px-5 py-2 text-[13px] text-ink transition-colors hover:border-moss/50"
        >
          Reconcile live state →
        </Link>
        <Link
          href="/docs/audit"
          className="rounded-pill border border-line bg-raised/70 px-5 py-2 text-[13px] text-ink transition-colors hover:border-moss/50"
        >
          Audit register →
        </Link>
      </div>
    </PageShell>
  );
}
