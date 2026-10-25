"use client";

import Link from "next/link";
import {useRef, useState, useSyncExternalStore} from "react";
import {useQuery, useQueryClient} from "@tanstack/react-query";
import {useAccount, usePublicClient, useSwitchChain} from "wagmi";
import {encodeFunctionData, formatUnits, type Hex} from "viem";
import {IS_MAINNET} from "@/config/contracts";
import {fmtAmount, shortAddress} from "@/lib/format";
import {assertTreasurySupplyCalls, CLOSED_MARKET_LAUNCH, MARKET_SAFE_ABI, MARKET_TOKEN_ABI, MORPHO_MARKET,
  isTreasury, marketAction, parseMarketAmount, treasurySupplyCalls, treasurySupplyDigest,
  type MarketAction, type MarketCall, type MarketLaunch} from "@/lib/morphoMarket";
import {postActionValues, repaymentQuote, safeBorrowMaximum, safeCollateralMaximum, withinMarketBuffer} from "@/lib/morphoMarketActions";
import {readMorphoMarket, type MorphoMarketSnapshot} from "@/lib/morphoMarketReader";
import {assertMarketQuoteCurrent, isMarketQuoteCurrent, type MarketQuoteTiming} from "@/lib/morphoMarketProjection";
import {simulateSafeMarketCalls} from "@/lib/morphoSafe";
import {assertNoTreasurySupply, clearResolvedTreasuryProposal, readTreasuryProposal, reserveTreasuryProposal,
  REVIEWED_TREASURY_GENERATOR, saveTreasuryProposal, treasuryProposalState} from "@/lib/morphoTreasury";
import {ConnectControl} from "./ConnectControl";
import {ActionButton, AmountInput, StatusLine, busyLabelFor} from "./WriteBits";
import {useWriteFlow} from "./useWriteFlow";
import {useMorphoSafe} from "./useMorphoSafe";
import {useNowSeconds} from "./useNowSeconds";

const P = MORPHO_MARKET.params;
const titles: Record<MarketAction, string> = {supply: "Lend USDC", withdraw: "Withdraw USDC", supplyCollateral: "Add sUSDfr collateral",
  borrow: "Borrow USDC", repay: "Repay USDC", withdrawCollateral: "Withdraw collateral"};
const isCollateralAction = (action: MarketAction) => action === "supplyCollateral" || action === "withdrawCollateral";
const addsExposure = (action: MarketAction) => action === "supply" || action === "borrow" || action === "supplyCollateral";
const actionOpen = (action: MarketAction, launch: MarketLaunch) => action === "supply" ? launch.lending
  : action === "borrow" || action === "supplyCollateral" ? launch.borrowing : true;

async function loadLaunch(): Promise<MarketLaunch> {
  const response = await fetch("/api/morpho/launch", {cache: "no-store"});
  if (!response.ok) throw new Error("Market availability could not be checked.");
  const value: unknown = await response.json();
  if (!value || typeof value !== "object" || !["lending", "borrowing", "treasury"].every(k => typeof (value as Record<string, unknown>)[k] === "boolean")) {
    throw new Error("Market availability could not be checked.");
  }
  return value as MarketLaunch;
}

export function MorphoMarketSurface() {
  const {address: browserAddress, chainId} = useAccount();
  const client = usePublicClient();
  const {switchChain} = useSwitchChain();
  const safe = useMorphoSafe();
  const wallet = safe.context?.address ?? browserAddress;
  const correctNetwork = safe.context?.chainId === 1 || chainId === 1;
  const cache = useQueryClient();
  const [action, setAction] = useState<MarketAction>("supply");
  const [amount, setAmount] = useState("");
  const [all, setAll] = useState(false);
  const [riskAccepted, setRiskAccepted] = useState(false);
  const now = useNowSeconds(1_000);
  const [safeStatus, setSafeStatus] = useState<{phase: "idle" | "simulating" | "review" | "proposed" | "error"; message?: string; hash?: Hex}>({phase: "idle"});
  const locked = useRef(false);
  const [preparing, setPreparing] = useState(false);
  const [preparedQuote, setPreparedQuote] = useState<MarketQuoteTiming | null>(null);
  const flow = useWriteFlow();
  const launchQuery = useQuery({queryKey: ["morpho-launch"], queryFn: loadLaunch, staleTime: 0, retry: 1, refetchInterval: 15_000});
  const launch = !launchQuery.isError ? launchQuery.data ?? CLOSED_MARKET_LAUNCH : CLOSED_MARKET_LAUNCH;
  const marketQuery = useQuery({queryKey: ["morpho-market", wallet ?? null],
    queryFn: () => readMorphoMarket(client!, wallet), enabled: IS_MAINNET && !!client,
    refetchInterval: 15_000, staleTime: 0, retry: 1});
  // Use the end of this display second: never extend expiry by rounding down.
  // The actual submission guard below uses the exact millisecond clock.
  const displayNow = now === null ? null : now * 1_000 + 999;
  const fresh = !!marketQuery.data && !marketQuery.isError && displayNow !== null
    && isMarketQuoteCurrent(marketQuery.data, displayNow) && displayNow - marketQuery.data.readAt < 30_000;
  const snapshot = fresh ? marketQuery.data : undefined;
  const account = snapshot?.account;
  const treasury = !!wallet && isTreasury(wallet);
  const treasurySeed = treasury && action === "supply";
  const proposalQuery = useQuery({queryKey: ["morpho-treasury-proposal", safe.context?.address ?? null],
    queryFn: () => treasuryProposalState(window.localStorage, safe.context!.sdk, client!),
    enabled: treasury && !!safe.context && !!client, refetchInterval: 15_000, retry: false});
  const proposal = proposalQuery.data;
  const decimals = isCollateralAction(action) ? MORPHO_MARKET.collateralDecimals : MORPHO_MARKET.loanDecimals;
  const symbol = isCollateralAction(action) ? "sUSDfr" : "USDC";
  const parsed = treasurySeed ? MORPHO_MARKET.seed : parseMarketAmount(amount, decimals);
  const repayAll = action === "repay" && all;
  const withdrawAll = action === "withdraw" && all;
  const repayment = snapshot ? repaymentQuote(snapshot) : null;
  const requiredAllowance = repayAll ? repayment?.required ?? null : parsed;
  const approvalAction = action === "supply" || action === "supplyCollateral" || action === "repay";
  const allowance = isCollateralAction(action) ? account?.collateralAllowance : account?.usdcAllowance;
  const needsApproval = approvalAction && requiredAllowance !== null && allowance !== undefined && allowance < requiredAllowance;
  const requiresRisk = addsExposure(action) || (action === "withdrawCollateral" && !!account?.position.borrowShares);
  const networkReason = !IS_MAINNET ? "This market is available on Ethereum mainnet. This build is connected to a different network."
    : !wallet ? "Connect your wallet to manage a position." : !correctNetwork ? "Switch your wallet to Ethereum mainnet." : null;
  const limitReason = account && snapshot ? validateAmount(action, parsed, all, snapshot) : null;
  const disabledReason = networkReason ?? (!fresh ? "Waiting for current, verified market data." : null)
    ?? (treasurySeed && !safe.context ? "Open this page inside the Treasury Safe to review its atomic supply." : null)
    ?? (treasurySeed && safe.context && (proposalQuery.isError || !proposal) ? "Treasury proposal tracking is unavailable. No proposal can be prepared." : null)
    ?? (treasurySeed && proposal?.record ? "A Treasury seed proposal is already recorded. Reconcile the Safe queue before continuing." : null)
    ?? (treasurySeed && !launch.treasury ? "The Treasury supply is awaiting its final launch checks." : null)
    ?? (!treasurySeed && !actionOpen(action, launch) ? "New positions are awaiting launch checks. Existing positions can still be repaid or withdrawn." : null)
    ?? limitReason ?? (!riskAccepted && requiresRisk ? "Review and acknowledge the market risks before continuing." : null);
  const safeBusy = safeStatus.phase === "simulating" || safeStatus.phase === "review" || safeStatus.phase === "proposed";
  const busy = preparing || flow.busy || safeBusy;
  // A background refresh must not give a pending wallet request/proposal a new expiry.
  const displayedQuote = busy && preparedQuote ? preparedQuote : marketQuery.data;
  const quoteExpired = !!displayedQuote && displayNow !== null && displayNow >= displayedQuote.expiresAt;
  const switchAction = (next: MarketAction) => {if (busy) return; setAction(next); setAmount(""); setAll(false); setRiskAccepted(false); setSafeStatus({phase: "idle"});};
  const maximum = account ? action === "supply" ? account.usdc
    : action === "repay" ? min(account.usdc, max(0n, account.values.borrowed - 1n))
    : action === "supplyCollateral" ? account.collateral : action === "withdrawCollateral" ? safeCollateralMaximum(snapshot!)
    : action === "withdraw" ? min(account.values.supplied, snapshot!.liquidity)
    : safeBorrowMaximum(snapshot!) : 0n;
  const preview = snapshot && (all || parsed !== null) ? postActionValues(action, all ? 0n : parsed!, all, snapshot) : null;

  async function submit() {
    if (disabledReason || busy || locked.current || !client || !wallet || !snapshot) return;
    locked.current = true;
    setPreparing(true);
    try {
      const currentLaunch = await loadLaunch();
      const current = await readMorphoMarket(client, wallet);
      setPreparedQuote({issuedAt: current.issuedAt, expiresAt: current.expiresAt});
      if (!current.account || (requiresRisk && !riskAccepted)) throw new Error("Refresh and review your position.");
      if (treasurySeed ? !currentLaunch.treasury : !actionOpen(action, currentLaunch)) throw new Error("This action is awaiting launch checks.");
      const error = validateAmount(action, parsed, all, current);
      if (error) throw new Error(error);
      const walletCode = await client.getCode({address: wallet});
      if (!safe.context && walletCode && walletCode !== "0x" && !walletCode.startsWith("0xef0100")) {
        throw new Error("Open this page inside your Safe to submit an atomic batch from that wallet.");
      }
      assertMarketQuoteCurrent(current);
      const currentRepayment = repaymentQuote(current);
      const currentRequired = repayAll ? currentRepayment.required : parsed!;
      const currentApproval = repayAll ? currentRepayment.approval : parsed!;
      const currentAllowance = isCollateralAction(action) ? current.account.collateralAllowance : current.account.usdcAllowance;
      // Safe execution can wait for signatures: retain its atomic cushioned approval.
      // Only the two-click EOA flow uses required, so its approval cannot chase itself.
      const approve = approvalAction && currentAllowance < (safe.context ? currentApproval : currentRequired);
      const target = marketAction(action, repayAll || withdrawAll ? 0n : parsed!, wallet,
        repayAll ? current.account.position.borrowShares : withdrawAll ? current.account.position.supplyShares : 0n);
      const approval = {address: isCollateralAction(action) ? P.collateralToken : P.loanToken, abi: MARKET_TOKEN_ABI,
        functionName: "approve" as const, args: [MORPHO_MARKET.address, currentApproval] as const};
      if (safe.context) {
        setSafeStatus({phase: "simulating"});
        let calls: MarketCall[];
        if (treasurySeed) {
          calls = treasurySupplyCalls(); assertTreasurySupplyCalls(calls);
          if (readTreasuryProposal(window.localStorage)) throw new Error("A Treasury seed proposal is already recorded. Reconcile the Safe queue before continuing.");
          await assertNoTreasurySupply(client, current.block);
        } else {
          const data = encodeFunctionData(target as Parameters<typeof encodeFunctionData>[0]);
          calls = [...(approve ? [{to: approval.address, value: "0" as const, data: encodeFunctionData(approval)}] : []),
            {to: target.address, value: "0", data}];
        }
        await simulateSafeMarketCalls(client, wallet, calls);
        const info = await safe.context.sdk.safe.getInfo();
        if (info.chainId !== 1 || info.safeAddress.toLowerCase() !== wallet.toLowerCase()) throw new Error("The connected Safe changed. Refresh before continuing.");
        if (treasurySeed) {
          if (info.threshold !== 2 || info.owners.length !== 4) throw new Error("The Treasury Safe governance differs from the reviewed 2-of-4 configuration.");
          const nonce = await client.readContract({address: wallet, abi: MARKET_SAFE_ABI, functionName: "nonce"});
          if (nonce !== current.account.safeNonce) throw new Error("The Treasury nonce changed. Refresh and review again.");
        }
        assertMarketQuoteCurrent(current);
        setSafeStatus({phase: "review"});
        const intent = treasurySeed ? reserveTreasuryProposal(window.localStorage, current.account.safeNonce!) : null;
        assertMarketQuoteCurrent(current);
        const result = await safe.context.sdk.txs.send({txs: calls});
        setSafeStatus({phase: "proposed", hash: result.safeTxHash as Hex});
        if (intent) {
          saveTreasuryProposal(window.localStorage, intent, result.safeTxHash);
          void proposalQuery.refetch();
        }
      } else {
        await flow.run({...(!treasurySeed && approve ? approval : target), keepPendingUntilReceipt: true,
          assertBeforeWallet: () => assertMarketQuoteCurrent(current),
          onSuccess: () => {void cache.invalidateQueries({queryKey: ["morpho-market"]}); if (!approve) {setAmount(""); setAll(false);}}});
      }
    } catch (error) {
      setSafeStatus({phase: "error", message: error instanceof Error && error.message.length < 240 ? error.message : "The action could not be prepared. Refresh and try again."});
    } finally {locked.current = false; setPreparing(false); if (treasurySeed && safe.context) void proposalQuery.refetch();}
  }

  const borrowApr = snapshot ? apr(snapshot.rate) : "—";
  return <div className="space-y-8">
    <section aria-label="Market overview" className="border-y border-line-strong py-6">
      <div className="flex flex-wrap items-start justify-between gap-5">
        <div><h2 className="font-display text-2xl font-semibold">USDC / sUSDfr</h2>
          <p className="mt-2 text-sm text-ink-muted">Ethereum · Morpho Blue · 86% liquidation LTV</p></div>
        {safe.context ? <p className="rounded-pill border border-line px-4 py-2 font-mono text-xs">Safe {shortAddress(safe.context.address)} · {safe.context.threshold}-of-{safe.context.owners.length}</p> : <ConnectControl />}
      </div>
      <dl className="mt-7 grid grid-cols-2 gap-6 md:grid-cols-4">
        <Metric label="Total lent" value={snapshot ? `${fmtAmount(snapshot.market.totalSupplyAssets, 6)} USDC` : "—"} />
        <Metric label="Available liquidity" value={snapshot ? `${fmtAmount(snapshot.liquidity, 6)} USDC` : "—"} />
        <Metric label="Lending APR · variable" value={snapshot ? apr(snapshot.supplyRate) : "—"} />
        <Metric label="Borrowing APR · variable" value={borrowApr} />
      </dl>
      <p className="mt-5 text-xs text-ink-faint">{fresh ? `Read at Ethereum block ${snapshot!.block.toLocaleString()}. Displayed rates are averages since the market's last update and change with utilization.` : "Current market figures are unavailable. Refresh before making a decision."}</p>
    </section>
    {networkReason ? <div role="status" className="border-l-2 border-accent pl-4 text-sm text-ink-muted">{networkReason}
      {IS_MAINNET && wallet && !correctNetwork && !safe.context ? <button type="button" className="u-link ml-2 text-accent" onClick={() => switchChain({chainId: 1})}>Switch to Ethereum</button> : null}</div> : null}
    {marketQuery.isError ? <div role="alert" className="text-sm text-danger">Market data could not be verified. No balances have been assumed. <button type="button" className="u-link" onClick={() => void marketQuery.refetch()}>Retry</button></div> : null}
    {safe.error ? <p role="alert" className="text-sm text-danger">{safe.error}</p> : null}
    <div className="grid gap-8 lg:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)]">
      <section className="panel min-w-0 p-6 sm:p-8" aria-label="Manage market position">
        <div className="flex flex-wrap gap-2 border-b border-line pb-5" aria-label="Market actions">
          {(Object.keys(titles) as MarketAction[]).map(key => <button type="button" key={key} disabled={busy} aria-pressed={key === action}
            onClick={() => switchAction(key)} className={`rounded-pill border px-3 py-2 text-xs transition-colors ${key === action ? "border-navy bg-navy text-on-navy" : "border-line text-ink-muted hover:border-accent"}`}>{titles[key]}</button>)}
        </div>
        <h3 className="mt-6 font-display text-xl font-semibold">{treasurySeed ? "Treasury seed · 50,000 USDC" : titles[action]}</h3>
        <p className="mt-3 text-sm leading-relaxed text-ink-muted">{actionDescription(action)}</p>
        {treasurySeed ? <div className="mt-5 border-l-2 border-accent pl-4 text-sm leading-relaxed">
          <p>Approve exactly 50,000 USDC, then supply 50,000 USDC in one Safe transaction.</p>
          <p className="mt-2 text-ink-muted">The Treasury owns the lending shares. A 100,000-USDC starting balance leaves 50,000 USDC reserved for PT.</p>
        </div> : <AmountInput value={amount} onChange={v => {setAmount(v); setAll(false);}} symbol={symbol} maxDecimals={decimals}
          disabled={busy || repayAll || withdrawAll} onMax={account ? () => {
            const close = action === "repay" ? account.position.borrowShares > 0n && account.usdc >= repayment!.required
              : action === "withdraw" && account.position.supplyShares > 0n && account.values.supplied <= snapshot!.liquidity;
            setAll(close); setAmount(close ? "" : formatUnits(maximum, decimals));
          } : undefined} />}
        {account ? <p className="mt-3 text-xs text-ink-muted">Wallet: {fmtAmount(account.usdc, 6, 6)} USDC · {fmtAmount(account.collateral, MORPHO_MARKET.collateralDecimals, 6)} sUSDfr</p> : null}
        {action === "borrow" || action === "withdrawCollateral" ? <p className="mt-2 text-xs text-ink-muted">Typed amounts and Max retain an 80% LTV buffer. Max also leaves interest headroom until quote expiry, covering head age and read latency without assuming a collateral price increase. This is a page-level limit, not protection from liquidation. The on-chain threshold is 86%; collateral value and interest can change.</p> : null}
        {(action === "repay" || action === "withdraw") && !treasurySeed ? <label className="mt-4 flex items-center gap-2 text-sm">
          <input type="checkbox" checked={all} disabled={busy} onChange={e => setAll(e.target.checked)} />
          {action === "repay" ? "Repay all debt, including accrued interest" : "Withdraw all lending shares"}</label> : null}
        {repayAll ? <p className="mt-2 text-xs leading-relaxed text-ink-muted">The balance and allowance checks cover five minutes from quote issuance, including head age, read latency, rising rates and a small rounding margin. A new approval adds 0.1% to that estimate. Only the actual debt is repaid; unused allowance may remain. Other market transactions can require a fresh quote.</p> : null}
        {displayedQuote ? <div role="status" className="mt-3 space-y-1 text-xs leading-relaxed text-ink-muted">
          <p>{quoteExpired ? "Quote expired. Refresh and review again before signing." : "Quote valid for five minutes from issuance."} Expires {new Date(displayedQuote.expiresAt).toISOString().replace("T", " ").replace(/\.\d{3}Z$/, " UTC")}.</p>
          <p>This is not an on-chain deadline. Expiry cannot cancel a wallet request or Safe proposal already handed over. After expiry, refresh and review before signing; later execution is not protected.</p>
          {quoteExpired && !busy ? <button type="button" className="u-link" onClick={() => void marketQuery.refetch()}>Refresh quote</button> : null}
        </div> : null}
        {account && snapshot && (action === "borrow" || action === "withdrawCollateral" || action === "repay") ? <div className="mt-4 space-y-2 text-sm">
          <p>Current LTV: {formatLtv(account.values)} · liquidation LTV: 86%</p>
          {preview ? <p>Estimated post-action LTV: {formatLtv(preview)}. Rechecked before signing; execution conditions can change.</p> : null}
        </div> : null}
        {requiresRisk ? <label className="mt-5 flex items-start gap-3 text-sm leading-relaxed text-ink-muted">
          <input type="checkbox" checked={riskAccepted} disabled={busy} onChange={e => setRiskAccepted(e.target.checked)} className="mt-1" />
          <span>I understand the <Link href="/risk" className="u-link text-accent">market risks</Link>, including credit losses, liquidation and limited withdrawal liquidity.</span></label> : null}
        <ActionButton label={treasurySeed ? "Review 50,000-USDC supply in Safe" : safe.context ? `Review ${titles[action].toLowerCase()} in Safe` : needsApproval ? `Approve ${symbol}` : titles[action]}
          busyLabel={safeStatus.phase === "proposed" ? "Awaiting Safe execution…" : safeStatus.phase === "review" ? "Review in Safe…" : safeStatus.phase === "simulating" ? "Simulating Safe batch…" : busyLabelFor(flow.status)}
          busy={busy} disabled={!!disabledReason} onClick={() => void submit()} />
        {disabledReason ? <p role="status" className="mt-3 text-xs leading-relaxed text-ink-muted">{disabledReason}</p> : null}
        {flow.status.phase === "pending" ? <p role="status" className="mt-4 text-sm text-ink-muted">
          Transaction submitted; its outcome is still being checked. Check your wallet before submitting again.{" "}
          <a href={`https://etherscan.io/tx/${flow.status.hash}`} className="u-link text-accent" target="_blank" rel="noreferrer">View transaction</a>
        </p> : <StatusLine status={flow.status} />}
        {safeStatus.phase === "error" ? <p role="alert" className="mt-4 text-sm text-danger">{safeStatus.message}</p> : null}
        {safeStatus.phase === "proposed" ? <div role="status" className="mt-4 break-words text-sm leading-relaxed text-ink-muted">
          Safe review returned a proposal reference. Funds have not been confirmed as moved. The Safe&apos;s owners must review its nonce, signatures and execution.
          <p className="mt-2 font-mono text-xs">{safeStatus.hash}</p><p className="mt-2">Check the Safe transaction queue before creating another proposal.</p>
        </div> : null}
        {treasurySeed && proposal?.record ? <div role="status" className="mt-4 break-words text-xs leading-relaxed text-ink-muted">
          <p>Saved Treasury proposal: {proposal.status}.</p>
          {proposal.record.hash ? <p className="mt-2 font-mono">{proposal.record.hash}</p> : <p>The Safe reply was not recorded. Do not retry before reconciling its queue.</p>}
          <p className="mt-2">This browser record does not cover other devices or origins. Reconcile the complete Safe queue before any signature.</p>
          <button type="button" className="u-link mt-2 text-accent" disabled={busy} onClick={() => void proposalQuery.refetch()}>Recheck proposal status</button>
          {proposal.canClear ? <button type="button" className="u-link ml-3 mt-2 text-accent" disabled={busy} onClick={() => {
            void clearResolvedTreasuryProposal(window.localStorage, safe.context!.sdk, client!).then(() => proposalQuery.refetch()).catch(error =>
              setSafeStatus({phase: "error", message: error instanceof Error ? error.message : "The proposal record could not be reconciled."}));
          }}>Clear confirmed obsolete record</button> : null}
        </div> : null}
        {treasury ? <SafeInstructions /> : null}
      </section>
      <aside className="min-w-0 space-y-7">
        <section className="border-t border-line-strong pt-6"><h3 className="font-display text-lg font-semibold">Your position</h3>
          <dl className="mt-5 grid grid-cols-2 gap-6">
            <Metric label="USDC lent" value={account ? fmtAmount(account.values.supplied, 6, 6) : "—"} />
            <Metric label="USDC borrowed" value={account ? fmtAmount(account.values.borrowed, 6, 6) : "—"} />
            <Metric label="sUSDfr collateral" value={account ? fmtAmount(account.position.collateral, MORPHO_MARKET.collateralDecimals, 6) : "—"} />
            <Metric label="Collateral value · USDC" value={account ? fmtAmount(account.values.collateralValue, 6, 6) : "—"} />
          </dl>
          {!wallet ? <p className="mt-5 text-sm text-ink-muted">Connect a wallet to see your lending balance, collateral and debt.</p> : null}
        </section>
        <section className="border-t border-line pt-6"><h3 className="font-display text-lg font-semibold">How this market works</h3>
          <p className="mt-3 text-sm leading-relaxed text-ink-muted">Lenders earn variable interest from USDC borrowers. Withdrawals depend on available liquidity. Borrowers deposit sUSDfr before borrowing and must maintain collateral above the liquidation threshold.</p>
          <p className="mt-3 text-sm leading-relaxed text-ink-muted">sUSDfr carries the underlying credit book&apos;s gains and losses. Its redemption queue and the market&apos;s liquidation process can limit exits. USDC lending here is a separate position from staking USDfr.</p>
          <p className="mt-3 text-sm leading-relaxed text-ink-muted">The PT market is not open on this page.</p>
          <Link href="/app" className="u-link mt-4 inline-block text-sm text-accent">Buy USDfr or stake into sUSDfr →</Link>
        </section>
        <details className="border-t border-line pt-5"><summary className="cursor-pointer text-sm font-medium">Verify the market</summary>
          <div className="mt-4 space-y-3 break-all font-mono text-xs text-ink-muted">
            <p>Market ID: {MORPHO_MARKET.id}</p><p>Oracle: {P.oracle}</p>
            <a href={`https://etherscan.io/address/${MORPHO_MARKET.address}`} target="_blank" rel="noreferrer" className="u-link text-accent">Morpho Blue on Etherscan</a>
            {treasury ? <><p>Treasury: {MORPHO_MARKET.treasury}</p><p>Unsigned call digest: {treasurySupplyDigest()}</p>
              <p>Safe nonce at the displayed block: {account?.safeNonce?.toString() ?? "unavailable"}. Verify the proposal&apos;s nonce in Safe before signing.</p></> : null}
          </div>
        </details>
      </aside>
    </div>
  </div>;
}

function min(a: bigint, b: bigint) {return a < b ? a : b;}
function max(a: bigint, b: bigint) {return a > b ? a : b;}
function formatLtv(v: {borrowed: bigint; ltvBps: bigint | null}) {return v.borrowed === 0n ? "0%" : v.ltvBps === null ? "undefined (no collateral value)" : `${Number(v.ltvBps) / 100}%`;}
function apr(rate: bigint) {return `${fmtAmount(rate * 31_536_000n * 100n, 18, 2)}%`;}
function Metric({label, value}: {label: string; value: string}) {
  return <div className="min-w-0"><dt className="text-xs leading-relaxed text-ink-muted">{label}</dt><dd className="mt-2 break-words text-lg font-semibold tabular-nums">{value}</dd></div>;
}
function actionDescription(action: MarketAction) {
  return {supply: "Supply USDC directly to this market and receive lending shares. Interest is variable, and withdrawals depend on unborrowed liquidity.",
    withdraw: "Withdraw your supplied USDC and accrued interest to your connected wallet, subject to available liquidity.",
    supplyCollateral: "Deposit sUSDfr into your own collateral position. Adding collateral alone does not borrow USDC.",
    borrow: "Receive USDC into your connected wallet against the sUSDfr already posted as collateral. Interest accrues until repayment.",
    repay: "Reduce your debt with USDC from the connected wallet. Repay all uses your debt shares to avoid leaving interest dust.",
    withdrawCollateral: "Return sUSDfr collateral to your connected wallet. Morpho refuses any withdrawal that would make your debt unhealthy."}[action];
}
export function validateAmount(action: MarketAction, amount: bigint | null, all: boolean, s: MorphoMarketSnapshot): string | null {
  const a = s.account;
  if (!a) return "Connect your wallet and refresh its balances.";
  if (all && action === "repay") return a.position.borrowShares === 0n ? "There is no debt to repay." : a.usdc < repaymentQuote(s).required ? "Your USDC balance cannot cover the full debt and five-minute interest estimate." : null;
  if (all && action === "withdraw") return a.position.supplyShares === 0n ? "There are no lending shares to withdraw." : a.values.supplied > s.liquidity ? "The market does not have enough liquidity to withdraw all shares." : null;
  if (amount === null || amount <= 0n) return "Enter a positive amount with the token’s exact decimal precision.";
  if ((action === "supply" || action === "repay") && amount > a.usdc) return "Insufficient USDC in this wallet.";
  if (action === "supplyCollateral" && amount > a.collateral) return "Insufficient sUSDfr in this wallet.";
  if (action === "withdraw" && (amount > a.values.supplied || amount > s.liquidity)) return "The amount exceeds your lending balance or the market’s available liquidity.";
  if (action === "repay" && amount >= a.values.borrowed) return "Choose Repay all to close the debt by shares without leaving interest dust.";
  if (action === "borrow" && amount > a.values.borrowAvailable) return "The amount exceeds your collateral capacity or the market’s available liquidity.";
  if (action === "borrow" && !withinMarketBuffer(postActionValues(action, amount, false, s)!)) return "This borrow would exceed the page’s 80% LTV safety buffer. Reduce the amount.";
  if (action === "withdrawCollateral") {
    if (amount > a.position.collateral) return "The amount exceeds your posted collateral.";
    const after = postActionValues(action, amount, false, s)!;
    if (a.values.borrowed > after.liquidationDebt) return "This withdrawal would leave insufficient collateral for your debt.";
    if (!withinMarketBuffer(after)) return "This withdrawal would exceed the page’s 80% LTV safety buffer. Reduce the amount or repay debt first.";
  }
  return null;
}
const subscribeOrigin = () => () => {};
const browserOrigin = () => window.location.origin;
const serverOrigin = () => "";
function SafeInstructions() {
  const origin = useSyncExternalStore(subscribeOrigin, browserOrigin, serverOrigin);
  const url = origin.startsWith("https://") ? `https://app.safe.global/apps/open?safe=eth:${MORPHO_MARKET.treasury}&appUrl=${encodeURIComponent(`${origin}/markets`)}` : null;
  return <div className="mt-5 border-t border-line pt-5 text-xs leading-relaxed text-ink-muted">
    <p>Use the Treasury Safe as the connected account. Its owners review an atomic batch together; an owner&apos;s personal wallet is a different lending position.</p>
    {url ? <a href={url} target="_blank" rel="noreferrer" className="u-link mt-3 inline-block text-accent">Open this market in the Treasury Safe →</a> : null}
    <p className="mt-3">Before the final signature, repeat the full live book, governance, bot-protection, balance, allowance and exact-byte checks. An enabled button does not replace those checks.</p>
    <details className="mt-3 break-words"><summary className="cursor-pointer">Reviewed 50,000-USDC generator</summary>
      <p className="mt-2 font-mono">{REVIEWED_TREASURY_GENERATOR.commit}:{REVIEWED_TREASURY_GENERATOR.path}</p>
      <p className="mt-2 font-mono">SHA-256: {REVIEWED_TREASURY_GENERATOR.sha256}</p>
      <p className="mt-2">Regenerate only from these reviewed bytes. The older 250,000-USDC generator is not approved for this contribution.</p>
    </details>
  </div>;
}
