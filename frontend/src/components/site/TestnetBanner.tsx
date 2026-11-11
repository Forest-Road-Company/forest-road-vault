import { IS_TESTNET } from "@/config/contracts";

/**
 * Deployment status, stated before anything else on the page. This is a
 * functional status colour, not decoration: the label carries the meaning
 * on its own, so the hue is never the only signal.
 *
 * A testnet build distinguishes this Sepolia preview from the separate
 * Ethereum contract deployment. Contract deployment is a technical fact, not
 * a claim that every legal, operational or product-entry gate is closed.
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
      <p className="mx-auto flex max-w-6xl flex-wrap items-baseline justify-center gap-x-2 gap-y-1 text-center text-[13px] leading-snug">
        <span
          className={`font-semibold uppercase tracking-[0.14em] ${
            IS_TESTNET ? "text-warn" : "text-on-navy-accent"
          }`}
        >
          {IS_TESTNET ? "Sepolia preview" : "Ethereum contracts deployed"}
        </span>
        <span className={IS_TESTNET ? "text-ink-muted" : "text-on-navy-muted"}>
          {IS_TESTNET
            ? "This build reads Sepolia and its test assets have no value. A separate Ethereum mainnet contract deployment exists; this preview is not that application and does not show that every launch gate is closed."
            : "Transactions may use real assets. Primary-market minting and instant redemption are KYC-gated; deployment does not mean every product or entry path is open. Review the legal and risk disclosures."}
        </span>
      </p>
    </div>
  );
}
