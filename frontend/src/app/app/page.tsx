import type { Metadata } from "next";
import { pageMetadata } from "@/lib/shareCards";
import { PageShell } from "@/components/site/PageShell";
import { AppSurface } from "@/components/app/AppSurface";
import { ProtocolScene } from "@/components/site/ProtocolScene";
import {IS_LOCAL_FORK, NETWORK_NAME} from "@/config/contracts";

export const metadata: Metadata = pageMetadata({
  title: "App | Forest Road Vault",
  description:
    "Mint USDfr with USDC, stake it for sUSDfr and exit through the redemption queue. Every write simulates before you sign; minting and instant redemption are KYC-gated on-chain.",
  socialTitle: "Deposit, stake, redeem | Forest Road Vault",
});

export default function AppPage() {
  return (
    <PageShell
      section="App"
      title="Deposit, stake, redeem"
      lede={`${IS_LOCAL_FORK ? "Connected to disposable" : "Live against the deployed"} ${NETWORK_NAME} contracts. Every write simulates before you sign, reverts decode to plain language, and the KYC gate is enforced on-chain at the primary market only. Non-verified addresses can hold, view, transfer, and stake freely, but cannot mint or instant-redeem.`}
      visual={<ProtocolScene scene="lifecycle" />}
    >
      <AppSurface />
    </PageShell>
  );
}
