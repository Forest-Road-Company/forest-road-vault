import type { Metadata } from "next";
import { PageShell } from "@/components/site/PageShell";
import { TransparencyDashboard } from "@/components/app/TransparencyDashboard";
import {IS_LOCAL_FORK, NETWORK_NAME} from "@/config/contracts";

export const metadata: Metadata = {
  title: "Transparency | Forest Road Vault",
};

export default function TransparencyPage() {
  return (
    <PageShell
      section="Transparency"
      title={IS_LOCAL_FORK ? "The forked book, verifiable on-chain" : "The live book, verifiable on-chain"}
      lede={`Every number below comes from ${NETWORK_NAME} contract state, previews, or events.${IS_LOCAL_FORK ? " This is disposable fork state, not live Sepolia." : " No off-chain estimate is substituted."}`}
    >
      <TransparencyDashboard />
    </PageShell>
  );
}
