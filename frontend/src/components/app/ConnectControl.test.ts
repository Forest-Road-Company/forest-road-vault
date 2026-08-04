import {describe, expect, it} from "vitest";
import {visibleWalletChoices} from "@/components/app/ConnectControl";

const connector = (id: string, name: string) => ({id, name});

describe("ConnectControl wallet choices", () => {
  it("keeps the generic browser connector beside WalletConnect", () => {
    const injected = connector("injected", "Browser wallet");
    const walletConnect = connector("walletConnect", "WalletConnect");

    expect(visibleWalletChoices([injected, walletConnect])).toEqual([
      injected,
      walletConnect,
    ]);
  });

  it("deduplicates generic injection without hiding WalletConnect", () => {
    const injected = connector("injected", "Browser wallet");
    const rabby = connector("io.rabby", "Rabby");
    const metamask = connector("io.metamask", "MetaMask");
    const walletConnect = connector("walletConnect", "WalletConnect");

    expect(
      visibleWalletChoices([injected, rabby, metamask, walletConnect]),
    ).toEqual([rabby, metamask, walletConnect]);
  });

  it("retains the injected-only local-fork path", () => {
    const injected = connector("injected", "Browser wallet");

    expect(visibleWalletChoices([injected])).toEqual([injected]);
  });
});
