import { IS_TESTNET } from "@/config/contracts";

/**
 * Deployment status, stated before anything else on the page. This is a
 * functional status colour, not decoration: the label carries the meaning
 * on its own, so the hue is never the only signal.
 *
 * MERGE NOTE (2026-08-28). Structure, tone and contrast come from the FRAM
 * design system. The testnet COPY does not: the design-system version read
 * "No mainnet deployment, no real value", which was true when that branch was
 * cut and has been false since 2026-08-16. Commit 3ff5183 fixed exactly that
 * claim, and it is preserved here. A testnet build must say the mainnet
 * deployment exists and point at it, because a visitor on the Sepolia build
 * otherwise concludes there is no live protocol.
 */
export function TestnetBanner() {
  return (
    <div
      className={`border-b px-4 py-2 ${
        IS_TESTNET
          ? "border-warn/25 bg-warn-faint"
          : "border-line bg-navy-deepest"
      }`}
    >
      <p className="mx-auto flex max-w-6xl flex-wrap items-baseline justify-center gap-x-2 gap-y-1 text-center text-[11.5px] leading-snug">
        <span
          className={`font-semibold uppercase tracking-[0.14em] ${
            IS_TESTNET ? "text-warn" : "text-on-navy-accent"
          }`}
        >
          {IS_TESTNET ? "Testnet build" : "Ethereum mainnet"}
        </span>
        <span className={IS_TESTNET ? "text-ink-muted" : "text-on-navy-muted"}>
          {IS_TESTNET
            ? "This site reads Sepolia. Test assets have no value, and nothing here is an offer or a live financial product. The contracts are separately deployed to Ethereum mainnet; see Docs, Addresses."
            : "Transactions use real assets. Access is KYC-gated; review the legal and risk disclosures before transacting."}
        </span>
      </p>
    </div>
  );
}
