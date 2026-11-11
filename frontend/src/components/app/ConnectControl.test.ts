import {describe, expect, it} from "vitest";
import {progressText, visibleWalletChoices, walletChoiceLabel, walletIconSource} from "@/components/app/ConnectControl";

const connector = (id: string, name: string) => ({id, name});

describe("ConnectControl wallet choices", () => {
  it("keeps the generic browser connector beside WalletConnect", () => {
    const injected = connector("injected", "Injected");
    const walletConnect = connector("walletConnect", "WalletConnect");

    expect(visibleWalletChoices([injected, walletConnect])).toEqual([
      injected,
      walletConnect,
    ]);
  });

  it("deduplicates generic injection without hiding WalletConnect", () => {
    const injected = connector("injected", "Injected");
    const rabby = connector("io.rabby", "Rabby");
    const metamask = connector("io.metamask", "MetaMask");
    const walletConnect = connector("walletConnect", "WalletConnect");

    expect(
      visibleWalletChoices([injected, rabby, metamask, walletConnect]),
    ).toEqual([rabby, metamask, walletConnect]);
    // Discovered wallets are listed whether or not window.ethereum exists.
    expect(visibleWalletChoices([injected, rabby, walletConnect], false)).toEqual([rabby, walletConnect]);
  });

  it("retains the injected-only local-fork path", () => {
    const injected = connector("injected", "Injected");

    expect(visibleWalletChoices([injected])).toEqual([injected]);
  });

  it("hides the generic browser connector when the page has no injected provider at all", () => {
    const injected = connector("injected", "Injected");
    const walletConnect = connector("walletConnect", "WalletConnect");

    expect(visibleWalletChoices([injected, walletConnect], false)).toEqual([walletConnect]);
    expect(visibleWalletChoices([injected], false)).toEqual([]);
  });

  it("names every choice for what it is, never as 'Injected'", () => {
    expect(walletChoiceLabel(connector("injected", "Injected"))).toEqual({name: "Browser wallet", hint: "The wallet in this browser"});
    expect(walletChoiceLabel(connector("walletConnect", "WalletConnect"))).toEqual({name: "WalletConnect", hint: "Mobile wallet or QR code"});
    expect(walletChoiceLabel(connector("io.rabby", "Rabby"))).toEqual({name: "Rabby", hint: "Browser extension"});
  });

  it("shows a wallet's own icon only as an inline image", () => {
    expect(walletIconSource("data:image/svg+xml;base64,PHN2Zy8+")).toBe("data:image/svg+xml;base64,PHN2Zy8+");
    expect(walletIconSource("data:image/png;base64,iVBORw0KGgo=")).toBe("data:image/png;base64,iVBORw0KGgo=");
    expect(walletIconSource("https://wallet.example/icon.png")).toBeNull();
    expect(walletIconSource("javascript:alert(1)")).toBeNull();
    expect(walletIconSource("data:text/html,<p>")).toBeNull();
    expect(walletIconSource(undefined)).toBeNull();
  });

  it("says what a pending connection is waiting for", () => {
    const wc = connector("walletConnect", "WalletConnect");
    expect(progressText(wc, "opening")).toBe("Opening WalletConnect…");
    expect(progressText(wc, "showing-code")).toMatch(/^Scan the QR code/);
    expect(progressText(wc, "slow")).toMatch(/^Still reaching the WalletConnect relay/);
    expect(progressText(connector("io.rabby", "Rabby"), "opening")).toBe(
      "Waiting for Rabby. Approve or reject the request in your wallet.",
    );
    expect(progressText(connector("injected", "Injected"), "slow")).toBe(
      "Waiting for Browser wallet. Approve or reject the request in your wallet. Nothing showing? Open your wallet and reject the request there, then choose again.",
    );
  });
});
