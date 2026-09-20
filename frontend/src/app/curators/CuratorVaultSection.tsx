import { Section, SectionHead } from "@/components/site/Blocks";
import { CONTRACTS } from "@/config/contracts";
import { CURATOR_VAULT } from "@/config/curatorVault";
import { EthereumCuratorPanel } from "@/components/curators/EthereumCuratorPanel";
import { SolanaProviders } from "@/components/curators/SolanaProviders";
import { CuratorVaultPanel } from "@/components/curators/CuratorVaultPanel";

/**
 * Server component: renders each chain's curator surface only when this build is wired to it.
 * Ethereum needs the CuratorModule and USDfr addresses (always present on Sepolia and mainnet
 * builds); Solana needs the three vault variables. An unconfigured build shows the programme copy
 * and the register-interest form alone, so the public page never carries a control that points
 * nowhere.
 */
export function CuratorVaultSection() {
  const ethereum = Boolean(CONTRACTS.CuratorModule && CONTRACTS.USDfr);
  const solana = CURATOR_VAULT.configured;
  if (!ethereum && !solana) return null;
  const lede =
    ethereum && solana
      ? "Approved curators act here. On Ethereum, post first-loss capital into the CuratorModule per collateral class and withdraw what the class does not require. On Solana, subscribe to the vault: deposit, give notice, withdraw when eligible, and claim coupons as they fall due."
      : ethereum
        ? "Approved Ethereum curators post first-loss capital into the CuratorModule per collateral class here, and withdraw what the class does not require."
        : "Approved Solana curators subscribe here: deposit, give notice, withdraw when eligible, and claim coupons as they fall due.";
  return (
    <Section tone="light" id="position">
      <div className="flex flex-col gap-12 lg:flex-row lg:gap-16">
        <div className="lg:w-[42%] lg:flex-none">
          <SectionHead title="Your position." lede={lede} />
        </div>
        <div className="flex-1 space-y-12">
          {ethereum ? (
            <div id="ethereum-position">
              <p className="text-[12px] font-semibold uppercase tracking-[0.12em] text-ink-muted">Ethereum</p>
              <div className="mt-3">
                <EthereumCuratorPanel />
              </div>
            </div>
          ) : null}
          {solana ? (
            <div id="solana-position">
              {ethereum ? (
                <p className="text-[12px] font-semibold uppercase tracking-[0.12em] text-ink-muted">Solana</p>
              ) : null}
              <div className={ethereum ? "mt-3" : ""}>
                <SolanaProviders>
                  <CuratorVaultPanel />
                </SolanaProviders>
              </div>
            </div>
          ) : null}
        </div>
      </div>
    </Section>
  );
}
