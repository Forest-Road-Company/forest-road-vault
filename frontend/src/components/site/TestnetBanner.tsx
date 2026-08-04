import {IS_TESTNET} from "@/config/contracts";

export function TestnetBanner() {
  return (
    <div className="border-b border-line bg-moss-faint px-4 py-1.5 text-center">
      <p className="font-mono text-[11px] tracking-wide text-moss">
        {IS_TESTNET
          ? "TESTNET BUILD — no mainnet deployment, no real value. Nothing on this site is an offer or a live financial product."
          : "ETHEREUM MAINNET — transactions use real assets. Access is KYC-gated; review the legal and risk disclosures before transacting."}
      </p>
    </div>
  );
}
