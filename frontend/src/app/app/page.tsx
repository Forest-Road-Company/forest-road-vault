import type { Metadata } from "next";
import { PageShell } from "@/components/site/PageShell";
import { AppSurface } from "@/components/app/AppSurface";
import {IS_LOCAL_FORK, NETWORK_NAME} from "@/config/contracts";

export const metadata: Metadata = {
  title: "App — Forest Road Vault",
};

export default function AppPage() {
  return (
    <PageShell
      eyebrow="App"
      title="Deposit, stake, redeem"
      lede={`${IS_LOCAL_FORK ? "Connected to disposable" : "Live against the deployed"} ${NETWORK_NAME} contracts. Every write simulates before you sign, reverts decode to plain language, and the KYC gate is enforced on-chain at the primary market only — non-verified addresses can hold, view, transfer, and stake freely, but cannot mint or instant-redeem.`}
    >
      <AppSurface />
    </PageShell>
  );
}
