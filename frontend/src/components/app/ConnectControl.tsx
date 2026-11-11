"use client";

/**
 * Wallet connect/disconnect. Browser wallets are discovered through EIP-6963 and listed by their
 * own name and icon; production/testnet builds also offer WalletConnect when a public Reown project
 * ID is configured. When several options exist, a chooser opens in place.
 *
 * One request at a time, page-wide. A wallet request cannot be withdrawn (its prompt can still be
 * approved later, and wagmi then makes that wallet active), so there is no Cancel: while a request
 * is open, every connect button on the page shows what it is waiting for and offers no other wallet,
 * and a late approval is simply the connection the visitor asked for. WalletConnect's own modal
 * close ends its request. Opening the chooser (an explicit step towards connecting) starts the
 * WalletConnect provider and its relay connection, so its QR code is not kept waiting.
 */

import {useCallback, useEffect, useId, useRef, useState, useSyncExternalStore, type ReactNode} from "react";
import {useAccount, useConnect, useConnectors, useDisconnect} from "wagmi";
import {getConnectLock, getServerConnectLock, startLockedConnect, subscribeConnectLock} from "@/lib/connectLock";
import {shortAddress} from "@/lib/format";

type Connector = ReturnType<typeof useConnectors>[number];

/** The generic injected connector, which EIP-6963 discovery usually duplicates by name. */
const INJECTED = "injected";
const WALLETCONNECT = "walletConnect";

/**
 * The choices to offer. EIP-6963 usually re-surfaces the configured generic injected connector, so
 * that duplicate is hidden whenever a wallet announced itself; the generic one is offered only when
 * nothing was discovered and the page does have an injected provider (`window.ethereum`), and never
 * when there is none. WalletConnect always stays available alongside browser wallets.
 */
export function visibleWalletChoices<T extends {id: string}>(
  connectors: readonly T[],
  injectedProviderPresent = true,
): T[] {
  const walletConnectChoices = connectors.filter((connector) => connector.id === WALLETCONNECT);
  const browserChoices = connectors.filter((connector) => connector.id !== WALLETCONNECT);
  const discoveredBrowserChoices = browserChoices.filter((connector) => connector.id !== INJECTED);
  const genericBrowserChoices = injectedProviderPresent ? browserChoices : [];
  return [
    ...(discoveredBrowserChoices.length > 0 ? discoveredBrowserChoices : genericBrowserChoices),
    ...walletConnectChoices,
  ];
}

/** What a choice is called on the page. The generic connector's own name ("Injected") never shows. */
export function walletChoiceLabel(connector: {id: string; name: string}): {name: string; hint: string} {
  if (connector.id === WALLETCONNECT) return {name: "WalletConnect", hint: "Mobile wallet or QR code"};
  if (connector.id === INJECTED) return {name: "Browser wallet", hint: "The wallet in this browser"};
  return {name: connector.name, hint: "Browser extension"};
}

/**
 * An EIP-6963 icon is shown only as an inline image (the standard requires a data URI); anything
 * else would be a request to a third party, which the page's content policy also refuses.
 */
export function walletIconSource(icon: unknown): string | null {
  return typeof icon === "string" && /^data:image\/(svg\+xml|png|jpeg|webp|gif)[;,]/i.test(icon) ? icon : null;
}

function hasInjectedProvider(): boolean {
  return typeof window !== "undefined" && Boolean((window as {ethereum?: unknown}).ethereum);
}

/** After this long without a QR code, the page says the relay is slow rather than spinning. */
export const WALLETCONNECT_SLOW_MS = 5_000;
/** After this long, a browser wallet that has not answered gets a hint to look for its window. */
export const BROWSER_WALLET_SLOW_MS = 8_000;

type Stage = "opening" | "showing-code" | "slow";

/**
 * Starts the WalletConnect provider and, where its relay client exposes it, the relay connection, so
 * that choosing WalletConnect does not then wait for either. Best effort: if the provider's shape
 * differs, the connection simply opens on the click instead.
 */
function prewarmWalletConnect(connector: Connector | undefined) {
  if (!connector) return;
  void connector
    .getProvider()
    .then((provider) => {
      // `toEstablishConnection` is what the relay client itself calls before its first subscription;
      // its public `transportOpen` declines while the client has no topics, which is the case here.
      const relayer = (
        provider as
          | {signer?: {client?: {core?: {relayer?: {connected?: boolean; connecting?: boolean; toEstablishConnection?: () => Promise<void>}}}}}
          | undefined
      )?.signer?.client?.core?.relayer;
      if (relayer && !relayer.connected && !relayer.connecting && typeof relayer.toEstablishConnection === "function") {
        return relayer.toEstablishConnection();
      }
    })
    .catch(() => undefined);
}

function WalletConnectGlyph() {
  return (
    <svg viewBox="0 0 300 185" className="h-[15px] w-6" aria-hidden focusable="false">
      <path
        fill="currentColor"
        d="M61.44 36.26c48.91-47.89 128.21-47.89 177.12 0l5.89 5.76a6.04 6.04 0 0 1 0 8.67l-20.14 19.71a3.18 3.18 0 0 1-4.43 0l-8.1-7.93c-34.12-33.41-89.45-33.41-123.57 0l-8.67 8.49a3.18 3.18 0 0 1-4.43 0L54.98 51.25a6.04 6.04 0 0 1 0-8.67l6.46-6.32Zm218.77 40.77 17.92 17.54a6.04 6.04 0 0 1 0 8.67l-80.78 79.09a6.37 6.37 0 0 1-8.86 0l-57.33-56.13a1.59 1.59 0 0 0-2.21 0l-57.33 56.13a6.37 6.37 0 0 1-8.86 0L1.97 103.24a6.04 6.04 0 0 1 0-8.67l17.92-17.54a6.37 6.37 0 0 1 8.86 0l57.33 56.13a1.59 1.59 0 0 0 2.21 0l57.33-56.13a6.37 6.37 0 0 1 8.86 0l57.33 56.13a1.59 1.59 0 0 0 2.21 0l57.33-56.13a6.37 6.37 0 0 1 8.86 0Z"
      />
    </svg>
  );
}

function BrowserWalletGlyph() {
  return (
    <svg viewBox="0 0 24 24" className="h-5 w-5" aria-hidden focusable="false" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 7.5A2.5 2.5 0 0 1 6.5 5H18a1 1 0 0 1 1 1v2" />
      <path d="M4 7.5v10A2.5 2.5 0 0 0 6.5 20H19a1 1 0 0 0 1-1v-9a1 1 0 0 0-1-1H6.5A2.5 2.5 0 0 1 4 7.5Z" />
      <circle cx="16" cy="14.5" r="1.2" fill="currentColor" stroke="none" />
    </svg>
  );
}

function WalletIcon({connector}: {connector: Connector}) {
  const source = walletIconSource(connector.icon);
  return (
    <span className="grid h-9 w-9 flex-none place-items-center overflow-hidden rounded-[10px] border border-line bg-raised text-accent">
      {connector.id === WALLETCONNECT ? (
        <WalletConnectGlyph />
      ) : source ? (
        // An inline data: URI from the wallet itself; there is nothing for the image optimizer to fetch.
        // eslint-disable-next-line @next/next/no-img-element
        <img src={source} alt="" width={24} height={24} className="h-6 w-6" />
      ) : (
        <BrowserWalletGlyph />
      )}
    </span>
  );
}

export function progressText(connector: {id: string; name: string}, stage: Stage): string {
  const {name} = walletChoiceLabel(connector);
  if (connector.id === WALLETCONNECT) {
    if (stage === "showing-code") {
      return "Scan the QR code with your phone's wallet, or approve in the wallet you opened.";
    }
    if (stage === "slow") {
      return "Still reaching the WalletConnect relay. On some networks this takes up to 20 seconds.";
    }
    return "Opening WalletConnect…";
  }
  const waiting = `Waiting for ${name}. Approve or reject the request in your wallet.`;
  return stage === "slow"
    ? `${waiting} Nothing showing? Open your wallet and reject the request there, then choose again.`
    : waiting;
}

export function ConnectControl() {
  const {address, isConnected} = useAccount();
  const {connectAsync} = useConnect();
  const {disconnect} = useDisconnect();
  const connectors = useConnectors();
  const [chooserOpen, setChooserOpen] = useState(false);
  // The stage the visitor has reached on the open request (keyed by the request, so it starts fresh).
  const [stage, setStage] = useState<{id: number; stage: Stage} | null>(null);
  const [failure, setFailure] = useState<{error: unknown; connectorId: string} | null>(null);
  // The page-wide open request: every connect button shows it, whichever button started it.
  const lock = useSyncExternalStore(subscribeConnectLock, getConnectLock<Connector>, getServerConnectLock);
  const pendingConnector = lock?.connector ?? null;
  // Read after mount: the server render has no window, and the first client render must match it.
  const [injectedPresent, setInjectedPresent] = useState(true);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const firstChoiceRef = useRef<HTMLButtonElement>(null);
  const chooserRef = useRef<HTMLDivElement>(null);
  const statusRef = useRef<HTMLParagraphElement>(null);
  /** The request this button started, so only this button moves focus for it. */
  const ownRequest = useRef<number | null>(null);
  const headingId = useId();

  useEffect(() => {
    // Deferred so the change lands as an update after hydration, never during it.
    const id = setTimeout(() => setInjectedPresent(hasInjectedProvider()), 0);
    return () => clearTimeout(id);
  }, []);

  const choices = visibleWalletChoices(connectors, injectedPresent);
  const walletConnect = choices.find((connector) => connector.id === WALLETCONNECT);
  const pendingStage: Stage = lock && stage?.id === lock.id ? stage.stage : "opening";

  const focusTrigger = useCallback(() => {
    setTimeout(() => triggerRef.current?.focus(), 0);
  }, []);

  const closeChooser = useCallback(
    (restoreFocus: boolean) => {
      setChooserOpen(false);
      if (restoreFocus) focusTrigger();
    },
    [focusTrigger],
  );

  // Opening the chooser starts WalletConnect, and moves focus to the first choice.
  useEffect(() => {
    if (!chooserOpen) return;
    prewarmWalletConnect(walletConnect);
    firstChoiceRef.current?.focus();
  }, [chooserOpen, walletConnect]);

  // Escape or a click outside closes the chooser.
  useEffect(() => {
    if (!chooserOpen) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") closeChooser(true);
    };
    const onPointer = (event: PointerEvent) => {
      if (chooserRef.current && !chooserRef.current.contains(event.target as Node)) closeChooser(false);
    };
    document.addEventListener("keydown", onKey);
    document.addEventListener("pointerdown", onPointer);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("pointerdown", onPointer);
    };
  }, [chooserOpen, closeChooser]);

  // While a request is open: WalletConnect reports when its QR code is ready, and anything that
  // takes longer than expected is said in words, not left as a spinner.
  useEffect(() => {
    if (!lock) return;
    const {id, connector} = lock;
    const onMessage = ({type}: {type: string}) => {
      if (type === "display_uri") setStage({id, stage: "showing-code"});
    };
    connector.emitter.on("message", onMessage);
    const slow = setTimeout(
      () => setStage((current) => (current?.id === id && current.stage !== "opening" ? current : {id, stage: "slow"})),
      connector.id === WALLETCONNECT ? WALLETCONNECT_SLOW_MS : BROWSER_WALLET_SLOW_MS,
    );
    return () => {
      connector.emitter.off("message", onMessage);
      clearTimeout(slow);
    };
  }, [lock]);

  // With no Cancel to offer, focus moves to the status that says what the page is waiting for.
  useEffect(() => {
    if (lock && ownRequest.current === lock.id) statusRef.current?.focus();
  }, [lock]);

  const choose = (connector: Connector) => {
    const started = startLockedConnect(connector, () => connectAsync({connector}));
    // Another request is open (another button started it): nothing is asked of a second wallet.
    if (!started) return;
    ownRequest.current = started.id;
    setChooserOpen(false);
    setFailure(null);
    void started.settled.then((outcome) => {
      if (!outcome.ok) setFailure({error: outcome.error, connectorId: connector.id});
      focusTrigger();
    });
  };

  // A failed attempt is said plainly; a click that silently does nothing (e.g. no wallet
  // installed) would violate fail-loudly. Closing WalletConnect's own modal is the visitor's
  // choice, not a failure, so it is not reported.
  const failureName = (failure?.error as {name?: string} | undefined)?.name;
  const closedWalletConnect = failure?.connectorId === WALLETCONNECT && failureName === "UserRejectedRequestError";
  const connectError =
    failure && !lock && !closedWalletConnect ? (
      <p role="alert" className="mt-2 w-full text-[13px] leading-snug text-danger">
        {failureName === "ProviderNotFoundError"
          ? "No browser wallet found. Install one (e.g. MetaMask or Rabby) and reload."
          : failureName === "UserRejectedRequestError"
            ? "The connection was not approved."
            : typeof (failure.error as {shortMessage?: unknown}).shortMessage === "string"
              ? (failure.error as {shortMessage: string}).shortMessage
              : failure.error instanceof Error
                ? failure.error.message
                : "The wallet did not connect."}
      </p>
    ) : null;

  if (isConnected && address) {
    return (
      <div className="flex items-center gap-2.5">
        <span className="rounded-pill border border-line bg-raised px-3.5 py-1.5 font-mono text-[12px] text-ink">
          {shortAddress(address)}
        </span>
        <button
          type="button"
          onClick={() => disconnect()}
          className="min-h-10 rounded-pill border border-line-strong px-3.5 py-2 text-[12.5px] text-ink-muted transition-colors hover:border-danger/50 hover:text-danger"
        >
          Disconnect
        </button>
      </div>
    );
  }

  if (choices.length === 0) {
    return (
      <p className="text-[13px] text-ink-muted">
        No wallet option is available here. Install a browser wallet, or open this page in your
        wallet&apos;s browser.
      </p>
    );
  }

  let body: ReactNode;
  // The page-wide lock is taken on the click and released when the request settles, so every
  // button shows the open request from the first frame, and offers nothing else until it ends.
  if (pendingConnector) {
    body = (
      <div className="flex w-full max-w-[26rem] items-start gap-3">
        <span
          className="mt-1 h-3 w-3 flex-none animate-spin rounded-full border-2 border-accent border-t-transparent motion-reduce:animate-none"
          aria-hidden
        />
        <p
          ref={statusRef}
          tabIndex={-1}
          role="status"
          aria-live="polite"
          className="flex-1 text-[13px] leading-snug text-ink-muted outline-none"
        >
          {progressText(pendingConnector, pendingStage)}
        </p>
      </div>
    );
  } else if (choices.length > 1 && chooserOpen) {
    body = (
      <div
        ref={chooserRef}
        role="dialog"
        aria-modal="false"
        aria-labelledby={headingId}
        className="w-full max-w-[22rem] rounded-card border border-line-strong bg-raised p-3 shadow-[0_18px_40px_-24px_rgba(20,33,58,0.45)]"
      >
        <div className="flex items-center justify-between gap-3 pb-2 pl-1.5">
          <p id={headingId} className="text-[13px] font-semibold text-ink">
            Choose a wallet
          </p>
          <button
            type="button"
            onClick={() => closeChooser(true)}
            aria-label="Close the wallet chooser"
            className="grid h-9 w-9 place-items-center rounded-full text-ink-muted transition-colors hover:bg-surface hover:text-ink"
          >
            <svg viewBox="0 0 16 16" className="h-4 w-4" aria-hidden focusable="false" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
              <path d="m4 4 8 8M12 4l-8 8" />
            </svg>
          </button>
        </div>
        <ul className="space-y-1.5">
          {choices.map((connector, index) => {
            const {name, hint} = walletChoiceLabel(connector);
            return (
              <li key={connector.uid}>
                <button
                  ref={index === 0 ? firstChoiceRef : undefined}
                  type="button"
                  onClick={() => choose(connector)}
                  className="flex min-h-12 w-full items-center gap-3 rounded-[10px] border border-line px-3 py-2 text-left transition-colors hover:border-accent/60 hover:bg-surface"
                >
                  <WalletIcon connector={connector} />
                  <span className="min-w-0">
                    <span className="block text-[14px] font-medium text-ink">{name}</span>
                    <span className="block text-[12px] text-ink-faint">{hint}</span>
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
        <button
          type="button"
          onClick={() => closeChooser(true)}
          className="mt-2 min-h-10 w-full rounded-[10px] px-3 py-2 text-[13px] font-medium text-ink-muted transition-colors hover:bg-surface hover:text-ink"
        >
          Cancel
        </button>
      </div>
    );
  } else {
    body = (
      <button
        ref={triggerRef}
        type="button"
        onClick={() => (choices.length === 1 ? choose(choices[0]) : setChooserOpen(true))}
        aria-haspopup={choices.length > 1 ? "dialog" : undefined}
        className="min-h-11 rounded-pill bg-accent px-5 py-2.5 text-[13.5px] font-medium text-raised transition-transform hover:scale-[1.02] hover:bg-accent-strong"
      >
        Connect wallet
      </button>
    );
  }

  return (
    <div className="flex flex-wrap items-center">
      {body}
      {connectError}
    </div>
  );
}
