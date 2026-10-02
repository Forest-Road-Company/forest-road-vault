"use client";

/**
 * The Buy tab of the Get USDfr card: USDC to USDfr through the third-party USDfr/USDC Uniswap v4
 * pool, executed on this page by Uniswap's own Universal Router. Open to any address that can
 * receive USDfr, KYC-verified or not, because the only on-chain transfer restriction is the
 * jurisdiction block, which USDfr applies when the pool pays the buyer.
 *
 * Flow (every transaction through the shared write flow, so it is simulated before the wallet
 * opens and its revert is decoded into words):
 *   1. once per wallet, if USDC's allowance to Permit2 is below the amount: a maximum ERC-20
 *      approval to Permit2, as Uniswap's own app grants it (owner decision, 1 October 2026);
 *   2. Buy: fresh reads (latest block, Permit2 allowance and nonce, and the same compliance
 *      predicate USDfr applies to the pool's payout), then, unless the router already holds a
 *      Permit2 allowance covering the amount until the deadline, a PermitSingle signature for
 *      exactly this amount, then `execute` with the quote less the slippage limit as the minimum.
 * Encoding lives in `lib/uniswapV4Swap.ts`, which the mainnet-fork test drives against the real
 * pool.
 */

import {useEffect, useId, useRef, useState} from "react";
import {parseUnits} from "viem";
import {useAccount, usePublicClient, useReadContract, useSignTypedData} from "wagmi";
import {useQuery} from "@tanstack/react-query";
import {CONTRACTS} from "@/config/contracts";
import {USDFR_USDC_POOL} from "@/config/markets";
import {COMPLIANCE_ABI, ERC20_ABI} from "@/lib/abi";
import {fmtAmount} from "@/lib/format";
import {PERMIT2_ABI, POOL_ID, STATE_VIEW_ABI, V4_POOL_MANAGER, V4_STATE_VIEW} from "@/lib/uniswapV4Liquidity";
import {
  DEFAULT_SLIPPAGE_BPS,
  PERMIT2,
  UNIVERSAL_ROUTER,
  USDC,
  USDC_DECIMALS,
  USDFR,
  USDFR_DECIMALS,
  V4_QUOTER,
  assertBuyArgsMatch,
  buildBuyExecuteArgs,
  buildPermitSingle,
  buyRequest,
  buySwapFeePips,
  decodeQuoteResult,
  decodeSwapError,
  describeParity,
  describeQuoteFailure,
  encodeQuoteCall,
  formatBpsPercent,
  formatPipsPercent,
  isBelowWarningFloor,
  minAmountOut,
  needsPermit,
  needsPermit2Approval,
  parseSlippagePercent,
  permit2ApprovalRequest,
  permitTypedData,
  priceE18,
  swapDeadline,
  type SignedPermit,
} from "@/lib/uniswapV4Swap";
import {useWriteFlow} from "@/components/app/useWriteFlow";
import {ActionButton, AmountInput, StatusLine, busyLabelFor} from "@/components/app/WriteBits";

const POLL = {refetchInterval: 30_000} as const;
/** About one block: a quote older than this is replaced while the tab is open. */
const QUOTE_REFRESH_MS = 12_000;
const QUOTE_DEBOUNCE_MS = 350;
/** A quote older than this (a backgrounded tab stops refreshing) is refreshed, never traded on. */
const QUOTE_MAX_AGE_MS = 30_000;

/** The build must name the same USDfr and USDC as the pool, or the tab refuses to trade. */
const ROUTE_MATCHES_DEPLOYMENT =
  CONTRACTS.USDfr?.toLowerCase() === USDFR.toLowerCase() &&
  CONTRACTS.USDC?.toLowerCase() === USDC.toLowerCase();

/** Read only from the Buy click handler: a clock is never consulted during render. */
function quoteIsStale(updatedAt: number): boolean {
  return Date.now() - updatedAt > QUOTE_MAX_AGE_MS;
}

const BLOCKED_MESSAGE =
  "This address cannot receive USDfr: it is jurisdiction-blocked, so USDfr would refuse the pool's payment and the swap would revert. Nothing was signed or sent.";

const APPROVE_LABEL = "Approve USDC for Uniswap (once)";
const APPROVE_EXPLANATION =
  "A one-time approval lets Uniswap's Permit2 contract move your USDC when you sign a buy; each buy is limited to its own amount by your signature.";

type Prep =
  | {phase: "idle"}
  | {phase: "preparing"}
  | {phase: "permit"}
  | {phase: "notice"; message: string}
  | {phase: "error"; message: string; errorName: string | null};

export function BuyUsdfrPanel({
  chainOk,
  active,
  onShowMint,
}: {
  /** Connected on mainnet with an aligned RPC. Buying is not KYC-gated. */
  chainOk: boolean;
  /** Whether the Buy tab is showing; a hidden tab stops refreshing its quote. */
  active: boolean;
  /** Selects the Mint 1:1 tab. */
  onShowMint: () => void;
}) {
  const {address} = useAccount();
  const publicClient = usePublicClient();
  const {mutateAsync: signTypedData} = useSignTypedData();
  const flow = useWriteFlow();
  const slippageId = useId();
  const slippageHintId = useId();

  const [amount, setAmount] = useState("");
  const [slippageText, setSlippageText] = useState(formatBpsPercent(DEFAULT_SLIPPAGE_BPS).replace("%", ""));
  const [prep, setPrep] = useState<Prep>({phase: "idle"});
  const [bought, setBought] = useState(false);

  // A preparation belongs to the account that started it (the same rule as the write flow).
  const [prepOwner, setPrepOwner] = useState(address);
  if (prepOwner !== address) {
    setPrepOwner(address);
    setPrep({phase: "idle"});
    setBought(false);
  }
  const prepGeneration = useRef(0);
  const currentAddress = useRef(address);
  useEffect(() => {
    currentAddress.current = address;
    prepGeneration.current += 1;
  }, [address]);

  const {data: balance, isLoading: balanceLoading} = useReadContract({
    address: USDC,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: {enabled: Boolean(address), ...POLL},
  });
  const {data: allowance} = useReadContract({
    address: USDC,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: address ? [address, PERMIT2] : undefined,
    query: {enabled: Boolean(address), ...POLL},
  });
  const {data: slot0} = useReadContract({
    address: V4_STATE_VIEW,
    abi: STATE_VIEW_ABI,
    functionName: "getSlot0",
    args: [POOL_ID],
    query: {enabled: active, ...POLL},
  });

  let parsed: bigint | null = null;
  try {
    parsed = amount ? parseUnits(amount, USDC_DECIMALS) : null;
  } catch {
    parsed = null;
  }

  // Quote the amount once typing pauses, then keep the quote fresh while the tab is open.
  const [quotedAmount, setQuotedAmount] = useState<bigint | null>(null);
  useEffect(() => {
    const timer = window.setTimeout(() => setQuotedAmount(parsed), QUOTE_DEBOUNCE_MS);
    return () => window.clearTimeout(timer);
  }, [parsed]);
  const quote = useQuery({
    queryKey: ["usdfr-buy-quote", quotedAmount?.toString() ?? "none"],
    enabled: active && ROUTE_MATCHES_DEPLOYMENT && quotedAmount !== null && quotedAmount > 0n && Boolean(publicClient),
    refetchInterval: QUOTE_REFRESH_MS,
    retry: 1,
    queryFn: async () => {
      const amountIn = quotedAmount!;
      const result = await publicClient!.call({to: V4_QUOTER, data: encodeQuoteCall(amountIn)});
      return decodeQuoteResult(amountIn, result.data);
    },
  });
  // Only a quote for exactly the amount in the field, whose latest refresh succeeded, may be
  // shown as current or traded on.
  const quoteFailed = quote.isError && quotedAmount === parsed;
  const liveQuote =
    quote.data && !quote.isError && parsed !== null && quote.data.amountIn === parsed ? quote.data : null;

  const slippage = parseSlippagePercent(slippageText);
  const minimum = liveQuote && slippage.ok ? minAmountOut(liveQuote.amountOut, slippage.bps) : null;
  const belowFloor = liveQuote ? isBelowWarningFloor(liveQuote.amountIn, liveQuote.amountOut) : false;
  const fees = slot0 ? buySwapFeePips(slot0[3], slot0[2]) : null;

  const exceedsBalance = parsed !== null && balance !== undefined && parsed > balance;
  // Once per wallet: after the maximum approval, USDC's allowance to Permit2 covers every later buy.
  const needsApproval =
    parsed !== null && parsed > 0n && allowance !== undefined && needsPermit2Approval(allowance, parsed);
  const prepBusy = prep.phase === "preparing" || prep.phase === "permit";
  const busy = prepBusy || flow.busy;
  // Allowance and balance must have LOADED before the button can honestly say Approve or Buy,
  // and the quote on screen must be for this exact amount before either is offered.
  const canSubmit =
    chainOk &&
    ROUTE_MATCHES_DEPLOYMENT &&
    parsed !== null &&
    parsed > 0n &&
    balance !== undefined &&
    !exceedsBalance &&
    allowance !== undefined &&
    liveQuote !== null &&
    minimum !== null &&
    minimum > 0n &&
    !busy;

  const buy = async (amountIn: bigint, amountOutMinimum: bigint) => {
    if (!address || !publicClient) return;
    const owner = address;
    const generation = ++prepGeneration.current;
    const stillCurrent = () =>
      prepGeneration.current === generation &&
      currentAddress.current?.toLowerCase() === owner.toLowerCase();
    flow.reset();
    setBought(false);
    setPrep({phase: "preparing"});
    try {
      const [block, permitState, canReceive] = await Promise.all([
        publicClient.getBlock(),
        publicClient.readContract({
          address: PERMIT2,
          abi: PERMIT2_ABI,
          functionName: "allowance",
          args: [owner, USDC, UNIVERSAL_ROUTER],
        }),
        // USDfr runs this exact check when the pool pays the buyer; a blocked address learns it
        // here, before signing anything.
        publicClient.readContract({
          address: CONTRACTS.ComplianceRegistry!,
          abi: COMPLIANCE_ABI,
          functionName: "canTransfer",
          args: [USDFR, V4_POOL_MANAGER, owner],
        }),
      ]);
      if (!stillCurrent()) return;
      if (!canReceive) {
        setPrep({phase: "error", message: BLOCKED_MESSAGE, errorName: "USDfr_TransferNotAllowed"});
        return;
      }
      const deadline = swapDeadline(block.timestamp);
      const [permitAmount, permitExpiration, permitNonce] = permitState;
      let signedPermit: SignedPermit | null = null;
      if (needsPermit({amount: permitAmount, expiration: permitExpiration, nonce: permitNonce}, amountIn, deadline)) {
        const permit = buildPermitSingle({amount: amountIn, nonce: permitNonce, deadline});
        setPrep({phase: "permit"});
        const signature = await signTypedData({account: owner, ...permitTypedData(permit)});
        if (!stillCurrent()) return;
        signedPermit = {permit, signature};
      }
      const args = buildBuyExecuteArgs({amountIn, amountOutMinimum, deadline, signedPermit});
      assertBuyArgsMatch(args, {amountIn, amountOutMinimum, deadline, withPermit: signedPermit !== null});
      setPrep({phase: "idle"});
      void flow.run({
        ...buyRequest(args),
        decodeError: decodeSwapError,
        onSuccess: () => {
          setAmount("");
          setBought(true);
        },
      });
    } catch (err) {
      if (!stillCurrent()) return;
      setPrep({phase: "error", ...decodeSwapError(err)});
    }
  };

  const changeAmount = (value: string) => {
    setAmount(value);
    setBought(false);
    if (prep.phase === "notice" || prep.phase === "error") setPrep({phase: "idle"});
  };

  const act = () => {
    if (parsed === null || parsed <= 0n || !canSubmit) return;
    if (!needsApproval && quoteIsStale(quote.dataUpdatedAt)) {
      void quote.refetch();
      setPrep({
        phase: "notice",
        message: "That quote was more than 30 seconds old, so it is being refreshed. Check the new quote, then press Buy again.",
      });
      return;
    }
    if (needsApproval) {
      setPrep({phase: "idle"});
      setBought(false);
      // The maximum, once, as Uniswap's app does: each buy is still limited to its own amount by
      // the PermitSingle the buyer signs for it.
      void flow.run(permit2ApprovalRequest());
      return;
    }
    void buy(parsed, minimum!);
  };

  return (
    <>
      <p className="mt-3 text-[13px] leading-relaxed text-ink-muted">
        Swap USDC for USDfr through the USDfr/USDC Uniswap pool without leaving this page. Open to
        any address, KYC-verified or not.
      </p>
      {!ROUTE_MATCHES_DEPLOYMENT ? (
        <p role="alert" className="mt-3 text-[12.5px] leading-relaxed text-danger">
          Buying is disabled: this build&apos;s USDfr or USDC address does not match the pool&apos;s.
        </p>
      ) : null}

      <p className="mt-4 font-mono text-[11px] text-ink-faint">
        Balance:{" "}
        {balanceLoading ? (
          <span className="op-skeleton align-middle" aria-hidden>
            0,000.00 USDC
          </span>
        ) : balance !== undefined ? (
          <span className="text-ink-muted">{fmtAmount(balance, USDC_DECIMALS)} USDC</span>
        ) : (
          <span>wallet not connected</span>
        )}
      </p>

      <AmountInput
        value={amount}
        onChange={changeAmount}
        symbol="USDC"
        maxDecimals={USDC_DECIMALS}
        disabled={busy}
        invalid={exceedsBalance}
        onMax={
          balance !== undefined && balance > 0n
            ? () => changeAmount(fmtAmount(balance, USDC_DECIMALS, USDC_DECIMALS).replace(/,/g, ""))
            : undefined
        }
      />
      {exceedsBalance ? (
        <p className="mt-2 text-[12px] text-danger">This is more than the wallet&apos;s USDC balance.</p>
      ) : null}

      {parsed !== null && parsed > 0n ? (
        <>
          <dl className="mt-3 space-y-1 font-mono text-[11px] text-ink-faint">
            <QuoteRow term="You receive about">
              {liveQuote ? (
                <span className="text-[12.5px] font-semibold text-ink">
                  {fmtAmount(liveQuote.amountOut, USDFR_DECIMALS, 4)} USDfr
                </span>
              ) : quoteFailed ? (
                <span className="text-danger">no quote</span>
              ) : (
                <span className="op-skeleton align-middle" aria-hidden>
                  0,000.0000 USDfr
                </span>
              )}
            </QuoteRow>
            {liveQuote ? (
              <>
                <QuoteRow term="Minimum received">
                  {minimum !== null ? `${fmtAmount(minimum, USDFR_DECIMALS, 4)} USDfr` : "needs a valid slippage limit"}
                </QuoteRow>
                <QuoteRow term="Price">
                  {fmtAmount(priceE18(liveQuote.amountIn, liveQuote.amountOut), 18, 6)} USDfr per USDC
                </QuoteRow>
                <QuoteRow term="Difference">{describeParity(liveQuote.amountIn, liveQuote.amountOut)}</QuoteRow>
              </>
            ) : null}
            <QuoteRow term="Fees">
              {fees ? (
                formatPipsPercent(fees.total)
              ) : (
                <span className="op-skeleton align-middle" aria-hidden>
                  0.0000%
                </span>
              )}
            </QuoteRow>
          </dl>
          {fees ? (
            <p className="mt-1 text-[11px] leading-snug text-ink-faint">
              {fees.protocolFee > 0n
                ? `${formatPipsPercent(fees.lpFee)} pool fee plus a ${formatPipsPercent(fees.protocolFee)} Uniswap protocol fee, already in the quote.`
                : `The ${formatPipsPercent(fees.lpFee)} pool fee, already in the quote.`}
            </p>
          ) : null}
        </>
      ) : null}
      {quoteFailed ? (
        <p role="status" aria-live="polite" className="mt-2 text-[12px] leading-relaxed text-danger">
          {describeQuoteFailure(quote.error)}
        </p>
      ) : null}

      <div className="mt-3 flex items-center justify-between gap-3">
        <label htmlFor={slippageId} className="text-[11px] font-semibold uppercase tracking-[0.12em] text-ink-faint">
          Max slippage
        </label>
        <div
          className="op-field flex w-[5.5rem] items-center gap-1 px-2.5 py-1"
          data-invalid={slippage.ok ? undefined : "true"}
          data-disabled={busy ? "true" : undefined}
        >
          <input
            id={slippageId}
            type="text"
            inputMode="decimal"
            value={slippageText}
            disabled={busy}
            aria-describedby={slippageHintId}
            aria-invalid={slippage.ok ? undefined : true}
            onChange={(event) => {
              if (/^\d{0,2}(\.\d{0,2})?$/.test(event.target.value)) setSlippageText(event.target.value);
            }}
            className="w-full min-w-0 bg-transparent text-right font-mono text-[12.5px] text-ink outline-none disabled:cursor-not-allowed disabled:text-ink-faint"
          />
          <span className="text-[12px] text-ink-faint">%</span>
        </div>
      </div>
      <p id={slippageHintId} className={`mt-1 text-[11px] leading-snug ${slippage.ok ? "text-ink-faint" : "text-danger"}`}>
        {slippage.ok
          ? "The swap reverts if the pool would pay less than the minimum received. 0.05% to 3%."
          : slippage.message}
      </p>

      {belowFloor ? (
        <div className="mt-3 rounded-card border border-warn/40 bg-warn/10 px-4 py-3">
          <p className="text-[12.5px] leading-relaxed text-ink">
            <span className="font-medium">This quote is below 0.99 USDfr per USDC.</span>{" "}
            <span className="text-ink-muted">
              KYC-verified addresses can mint USDfr 1:1 with USDC in the{" "}
              <button type="button" onClick={onShowMint} className="u-link text-ink">
                Mint 1:1 tab
              </button>{" "}
              instead.
            </span>
          </p>
        </div>
      ) : null}

      <ActionButton
        label={needsApproval ? APPROVE_LABEL : "Buy USDfr"}
        busyLabel={
          prep.phase === "preparing"
            ? "Preparing…"
            : prep.phase === "permit"
              ? "Sign in wallet…"
              : busyLabelFor(flow.status)
        }
        busy={busy}
        disabled={!canSubmit}
        onClick={act}
      />
      {/* Shown while the approval is pending too: it says what the wallet is being asked for. */}
      {needsApproval ? (
        <p className="mt-2 text-[11.5px] leading-snug text-ink-faint">{APPROVE_EXPLANATION}</p>
      ) : null}

      {prep.phase === "preparing" ? (
        <PrepNote>Checking the swap against live chain state…</PrepNote>
      ) : prep.phase === "permit" ? (
        <PrepNote>
          Sign the Permit2 allowance in your wallet: exactly {amount || "this"} USDC for Uniswap&apos;s
          router, valid for 20 minutes. Signing costs no gas.
        </PrepNote>
      ) : prep.phase === "notice" ? (
        <PrepNote>{prep.message}</PrepNote>
      ) : prep.phase === "error" ? (
        <StatusLine status={{phase: "error", message: prep.message, errorName: prep.errorName}} />
      ) : (
        <StatusLine status={flow.status} />
      )}
      {bought && flow.status.phase === "success" ? (
        <p className="mt-1.5 text-[12.5px] leading-relaxed text-ink-muted">
          The USDfr is in your wallet.{" "}
          <a href="#stake-card" className="u-link font-medium text-accent">
            Stake it to earn the sUSDfr rate
          </a>
          .
        </p>
      ) : null}

      <p className="mt-auto border-t border-line pt-4 text-[12px] leading-snug text-ink-faint">
        Third-party pool: Uniswap&apos;s USDfr/USDC market is not Forest Road&apos;s, and its price is
        set by the market.{" "}
        <a href={USDFR_USDC_POOL.url} target="_blank" rel="noopener noreferrer" className="u-link text-ink">
          View the pool on Uniswap
        </a>
      </p>
    </>
  );
}

/** One line of the quote: a short term on the left, its value on the right. */
function QuoteRow({term, children}: {term: string; children: React.ReactNode}) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="shrink-0">{term}</dt>
      <dd className="min-w-0 text-right text-ink-muted">{children}</dd>
    </div>
  );
}

/** A pre-transaction step, announced like the write flow's own status lines. */
function PrepNote({children}: {children: React.ReactNode}) {
  return (
    <p role="status" aria-live="polite" className="mt-3 text-[12.5px] leading-relaxed text-ink-muted">
      {children}
    </p>
  );
}
