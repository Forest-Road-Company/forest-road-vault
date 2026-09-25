"use client";

import {useEffect, useState} from "react";
import {parseUnits, zeroAddress} from "viem";
import {useAccount, useReadContracts} from "wagmi";
import {CONTRACTS, EXPLORER_BASE_URL, IS_TESTNET, NETWORK_NAME} from "@/config/contracts";
import {CURATOR_ABI, ERC20_ABI, REGISTRY_ABI} from "@/lib/abi";
import {classNotice, needsAllowance, withdrawableNow, type ClassView} from "@/lib/curatorModuleView";
import {fmtAmount, shortAddress} from "@/lib/format";
import {VERTICALS} from "@/lib/verticals";
import {EXPECTED_CHAIN} from "@/lib/wagmi";
import {ConnectControl} from "@/components/app/ConnectControl";
import {NetworkBanner} from "@/components/app/NetworkBanner";
import {useWriteFlow} from "@/components/app/useWriteFlow";
import {ActionButton, AmountInput, StatusLine, busyLabelFor} from "@/components/app/WriteBits";

/**
 * The Ethereum curator's surface on /curators: first-loss capital posted per collateral class
 * into the live CuratorModule.
 *
 * What it shows is what the module holds: per class, this wallet's posting as the module values
 * it, the whole class pool, what live facilities require the pool to hold, and what is
 * withdrawable now (the posting, capped by the class headroom, nothing while a default is
 * unresolved). Writes go through the app's single write path (simulate, size, sign, receipt,
 * re-read), so every refusal arrives as the module's own error in plain words.
 * Approval controls new postings only. If governance revokes a class after capital was posted,
 * the position remains visible and withdrawable under the contract's ordinary safety checks.
 *
 * Nothing here states a rate or a yield: curator capital on Ethereum is the first-loss layer of
 * a variable pass-through, and the terms of a curator's participation are in the agreement they
 * signed off chain. Approval per class is set by governance after that agreement; this page can
 * only read it.
 */

const CLASS_IDS = [1n, 2n, 3n, 4n, 5n] as const;
const POLL = {refetchInterval: 30_000} as const;
const USDFR_DECIMALS = 18;

export function EthereumCuratorPanel() {
  const curatorModule = CONTRACTS.CuratorModule;
  const usdfr = CONTRACTS.USDfr;
  const registry = CONTRACTS.CollateralRegistry;
  const {address, isConnected, chainId} = useAccount();
  const rightNetwork = chainId === EXPECTED_CHAIN.id;
  const flow = useWriteFlow();
  const [amountState, setAmountState] = useState<{owner: string | undefined; value: string}>({
    owner: address,
    value: "",
  });
  const amount = amountState.owner === address ? amountState.value : "";
  const setAmount = (value: string) => setAmountState({owner: address, value});
  const [selection, setSelection] = useState<{owner: string | undefined; classId: bigint | null}>({
    owner: address,
    classId: null,
  });
  const selected = selection.owner === address ? selection.classId : null;
  const setSelected = (classId: bigint | null) => setSelection({owner: address, classId});
  // wagmi resolves the persisted connection after mount; rendering the connect row only then
  // keeps the server and client markup identical.
  const [mounted, setMounted] = useState(false);
  useEffect(() => {
    const t = setTimeout(() => setMounted(true), 0);
    return () => clearTimeout(t);
  }, []);

  // ── module reads (no wallet needed) ──────────────────────────────────────────────────────────────────────────
  const classReads = useReadContracts({
    query: {enabled: Boolean(curatorModule), ...POLL},
    contracts: [
      {address: curatorModule!, abi: CURATOR_ABI, functionName: "paused"},
      {address: curatorModule!, abi: CURATOR_ABI, functionName: "custodyFreezeActive"},
      ...CLASS_IDS.flatMap((classId) => [
        {address: curatorModule!, abi: CURATOR_ABI, functionName: "poolBalance", args: [classId]},
        {address: curatorModule!, abi: CURATOR_ABI, functionName: "firstLossTarget", args: [classId]},
        {address: curatorModule!, abi: CURATOR_ABI, functionName: "requiredFirstLoss", args: [classId]},
        {address: curatorModule!, abi: CURATOR_ABI, functionName: "headroom", args: [classId]},
        {address: curatorModule!, abi: CURATOR_ABI, functionName: "unresolvedDefaults", args: [classId]},
      ]),
    ],
  });
  const nameReads = useReadContracts({
    query: {enabled: Boolean(registry), staleTime: 3_600_000},
    contracts: CLASS_IDS.map((classId) => ({address: registry!, abi: REGISTRY_ABI, functionName: "classParams", args: [classId]})),
  });

  // ── wallet reads ────────────────────────────────────────────────────────
  // One ABI per hook keeps the multicall tuple types exact; a disconnected wallet reads
  // nothing (the zero address is a placeholder the `enabled` flag never lets through).
  const owner = address ?? zeroAddress;
  const walletEnabled = Boolean(curatorModule && usdfr && address && rightNetwork);
  const tokenReads = useReadContracts({
    query: {enabled: walletEnabled, ...POLL},
    contracts: [
      {address: usdfr!, abi: ERC20_ABI, functionName: "balanceOf", args: [owner]},
      {address: usdfr!, abi: ERC20_ABI, functionName: "allowance", args: [owner, curatorModule!]},
    ],
  });
  const stakeReads = useReadContracts({
    query: {enabled: walletEnabled, ...POLL},
    contracts: CLASS_IDS.flatMap((classId) => [
      {address: curatorModule!, abi: CURATOR_ABI, functionName: "isApprovedCurator", args: [classId, owner]},
      {address: curatorModule!, abi: CURATOR_ABI, functionName: "postedOf", args: [classId, owner]},
    ]),
  });

  const big = (v: unknown): bigint => (typeof v === "bigint" ? v : 0n);
  const paused = classReads.data?.[0]?.result === true;
  const custodyFrozen = classReads.data?.[1]?.result === true;
  const balance = tokenReads.data?.[0]?.result as bigint | undefined;
  const allowance = tokenReads.data?.[1]?.result as bigint | undefined;
  const views: ClassView[] = CLASS_IDS.map((classId, i) => {
    const c = 2 + i * 5;
    const w = i * 2;
    const params = nameReads.data?.[i]?.result as {name?: string} | undefined;
    return {
      classId,
      name: params?.name || VERTICALS[i]?.name || `Class ${classId.toString()}`,
      approved: stakeReads.data?.[w]?.result === true,
      posted: big(stakeReads.data?.[w + 1]?.result),
      pool: big(classReads.data?.[c]?.result),
      required: big(classReads.data?.[c + 2]?.result),
      headroom: big(classReads.data?.[c + 3]?.result),
      unresolvedDefaults: big(classReads.data?.[c + 4]?.result),
    };
  });
  // Revocation blocks new postings in the contract, but deliberately preserves an existing
  // stake's loss participation and withdrawal rights. Keep those positions on the page.
  const positionViews = views.filter((v) => v.approved || v.posted > 0n);
  // Every wallet read landed, or the verdict "not approved" is not one this page may give.
  const walletReadsSettled =
    stakeReads.data !== undefined && stakeReads.data.every((r) => r.status === "success");
  const classReadsSettled =
    classReads.data !== undefined && classReads.data.every((r) => r.status === "success");
  const defaultClass = positionViews.find((v) => v.approved)?.classId ?? positionViews[0]?.classId ?? null;
  useEffect(() => {
    if (defaultClass === null) return;
    const timer = setTimeout(() => {
      setSelection((prior) => {
        // Bind the first displayed class to this wallet. If that class later disappears, retain
        // its id so writes fail closed instead of following a newly computed default.
        if (prior.owner === address && prior.classId !== null) return prior;
        return {owner: address, classId: defaultClass};
      });
    }, 0);
    return () => clearTimeout(timer);
  }, [address, defaultClass]);
  if (!curatorModule || !usdfr) return null;
  // The first available row is the initial view only. Once the user chooses a class, retain that
  // exact selection; if it disappears, no write may silently retarget the default.
  const effectiveSelected = selected ?? defaultClass;
  const current = effectiveSelected === null
    ? null
    : positionViews.find((v) => v.classId === effectiveSelected) ?? null;
  const selectedClassDisappeared = selected !== null && current === null && positionViews.length > 0;

  let parsed: bigint | null = null;
  try {
    parsed = amount ? parseUnits(amount, USDFR_DECIMALS) : null;
  } catch {
    parsed = null;
  }
  const exitsBlocked = paused || custodyFrozen;
  const withdrawable = current ? withdrawableNow(current, exitsBlocked) : 0n;
  const approvalNeeded = needsAllowance(parsed, allowance);
  const canWrite = isConnected && rightNetwork && current !== null && !flow.busy && !paused;
  const canPost =
    canWrite
    && current?.approved === true
    && parsed !== null
    && parsed > 0n
    && (approvalNeeded || (balance !== undefined && parsed <= balance));
  const canWithdraw = canWrite && !custodyFrozen && parsed !== null && parsed > 0n && parsed <= withdrawable;
  const canSettlePriorPosition = isConnected && rightNetwork && !flow.busy;
  const recoveryClass = selected ?? CLASS_IDS[0];
  const explorer = (a: string) => (EXPLORER_BASE_URL ? `${EXPLORER_BASE_URL}/address/${a}` : null);

  const post = () => {
    if (!current?.approved || parsed === null || !address) return;
    if (approvalNeeded) {
      flow.run({address: usdfr, abi: ERC20_ABI, functionName: "approve", args: [curatorModule, parsed]});
    } else {
      flow.run({address: curatorModule, abi: CURATOR_ABI, functionName: "postFirstLoss", args: [current.classId, parsed], onSuccess: () => setAmount("")});
    }
  };
  const withdraw = () => {
    if (!current || parsed === null) return;
    flow.run({address: curatorModule, abi: CURATOR_ABI, functionName: "withdrawFirstLoss", args: [current.classId, parsed], onSuccess: () => setAmount("")});
  };
  const settleClosedRound = (classId: bigint) => {
    if (!address) return;
    flow.run({
      address: curatorModule,
      abi: CURATOR_ABI,
      functionName: "claimClosedRound",
      args: [classId, address],
      onSuccess: () => {
        setSelected(classId);
        void stakeReads.refetch();
      },
    });
  };

  const banner = IS_TESTNET ? (
    <p className="mb-5 rounded-md border border-line bg-surface px-4 py-2.5 text-[12.5px] text-ink-muted">
      <span className="font-semibold text-ink">{NETWORK_NAME} build.</span> This surface is wired to the
      CuratorModule on {NETWORK_NAME}. Nothing here has value.
    </p>
  ) : null;

  const row = (label: string, value: string) => (
    <div className="flex items-baseline justify-between gap-4 border-b border-line py-2 text-[13.5px]">
      <span className="text-ink-muted">{label}</span>
      <span className="font-mono text-ink">{value}</span>
    </div>
  );

  if (!mounted) {
    return (
      <div className="operate">
        {banner}
        <p className="text-[13px] text-ink-faint">Looking for wallets…</p>
      </div>
    );
  }

  if (!isConnected || !address) {
    return (
      <div className="operate">
        {banner}
        <p className="text-[14.5px] leading-relaxed text-ink-muted">
          Connect an Ethereum wallet to see the classes it is approved for and, if any, what it has
          posted.
        </p>
        <div className="mt-4">
          <ConnectControl />
        </div>
      </div>
    );
  }

  const header = (
    <div className="flex flex-wrap items-center justify-between gap-3">
      <ConnectControl />
      <span className="text-[11px] font-semibold uppercase tracking-[0.14em] text-ink-faint">{NETWORK_NAME}</span>
    </div>
  );

  if (!rightNetwork) {
    return (
      <div className="operate">
        {banner}
        {header}
        <NetworkBanner />
      </div>
    );
  }

  if (!walletReadsSettled || !classReadsSettled) {
    const failed =
      stakeReads.isError
      || classReads.isError
      || (stakeReads.data !== undefined && stakeReads.data.some((r) => r.status === "failure"))
      || (classReads.data !== undefined && classReads.data.some((r) => r.status === "failure"));
    return (
      <div className="operate">
        {banner}
        {header}
        {failed ? (
          <div className="mt-4">
            <p role="alert" className="text-[14px] text-danger">
              The module could not be read. Nothing is shown rather than a guess.
            </p>
            <button
              type="button"
              onClick={() => {
                void stakeReads.refetch();
                void tokenReads.refetch();
                void classReads.refetch();
              }}
              className="op-action mt-3 px-5 py-2.5 text-[13px]"
            >
              Retry
            </button>
          </div>
        ) : (
          <p className="mt-4 text-[14px] text-ink-faint">Reading the module…</p>
        )}
      </div>
    );
  }

  if (positionViews.length === 0) {
    return (
      <div className="operate">
        {banner}
        {header}
        <p className="mt-4 text-[14.5px] leading-relaxed text-ink-muted">
          This wallet is not approved as a curator in any collateral class. Approval is set by
          governance after eligibility checks and a signed agreement; register interest below and
          Forest Road will be in touch. There is nothing to post from this page until then.
        </p>
        <p className="mt-3 text-[12.5px] leading-relaxed text-ink-faint">
          Forest Road&apos;s position belongs to the AnchorCurator Safe. A Safe owner&apos;s personal
          wallet does not display or control that position; open this surface through the Safe or
          submit the calls from its transaction builder.
        </p>
        <div className="mt-5 border-t border-line pt-5">
          <p className="text-[13px] font-semibold text-ink">Previously posted capital?</p>
          <p className="mt-1.5 text-[12.5px] leading-relaxed text-ink-muted">
            A position carried through several closed pool rounds can quote as zero until its old
            shares are settled forward. Choose its class and settle it here. This moves no funds;
            repeat only if the position crossed more rounds than one transaction can process.
          </p>
          <label className="mt-3 block text-[13px] text-ink-muted">
            Prior position class
            <select
              value={recoveryClass.toString()}
              onChange={(e) => setSelected(BigInt(e.target.value))}
              disabled={flow.busy}
              className="op-field mt-1.5 block w-full px-4 py-2.5 text-[14px] text-ink"
            >
              {views.map((v) => (
                <option key={v.classId.toString()} value={v.classId.toString()}>
                  {v.name}
                </option>
              ))}
            </select>
          </label>
          <ActionButton
            label="Settle prior position"
            busyLabel={busyLabelFor(flow.status)}
            busy={flow.busy}
            disabled={!canSettlePriorPosition}
            onClick={() => settleClosedRound(recoveryClass)}
          />
          <StatusLine status={flow.status} />
        </div>
      </div>
    );
  }

  return (
    <div className="operate">
      {banner}
      {header}

      {paused ? (
        <p role="alert" className="mt-4 rounded-md border border-warn/40 bg-warn/10 px-4 py-2.5 text-[13px] text-ink">
          The CuratorModule is paused by the guardian. Postings and withdrawals resume when it is unpaused.
        </p>
      ) : null}
      {custodyFrozen ? (
        <p role="alert" className="mt-4 rounded-md border border-warn/40 bg-warn/10 px-4 py-2.5 text-[13px] text-ink">
          A reserve custody loss is being recognised. Curator withdrawals are frozen until the write-down completes; postings are unaffected.
        </p>
      ) : null}

      {/* ── approved classes and surviving revoked positions ───────────── */}
      <div className="mt-6 overflow-x-auto">
        <table className="w-full text-[13px]">
          <thead>
            <tr className="text-left text-ink-faint">
              <th className="py-1.5 font-medium">Class</th>
              <th className="py-1.5 font-medium">Your posting</th>
              <th className="py-1.5 font-medium">Class pool</th>
              <th className="py-1.5 font-medium">Required by live facilities</th>
              <th className="py-1.5 font-medium">Withdrawable now</th>
            </tr>
          </thead>
          <tbody>
            {positionViews.map((v) => (
              <tr key={v.classId.toString()} className="border-t border-line">
                <td className="py-2 text-ink">
                  {v.name}
                  {!v.approved ? <span className="ml-1 text-ink-faint">(approval withdrawn)</span> : null}
                </td>
                <td className="py-2 font-mono">{fmtAmount(v.posted, USDFR_DECIMALS)} USDfr</td>
                <td className="py-2 font-mono">{fmtAmount(v.pool, USDFR_DECIMALS)} USDfr</td>
                <td className="py-2 font-mono">{fmtAmount(v.required, USDFR_DECIMALS)} USDfr</td>
                <td className="py-2 font-mono">{fmtAmount(withdrawableNow(v, exitsBlocked), USDFR_DECIMALS)} USDfr</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="mt-2 text-[12px] leading-relaxed text-ink-faint">
        Your posting is your share of the class pool as the module values it now; it falls when the
        pool absorbs a loss. Withdrawable is your posting capped by the capital the class holds above
        what its live facilities require, and nothing while a facility in the class is in default.
      </p>

      {/* ── post or withdraw ───────────────────────────────────────────── */}
      <div className="mt-8">
        <p className="text-[12px] font-semibold uppercase tracking-[0.12em] text-ink-muted">Post or withdraw</p>
        {positionViews.length > 1 || !current ? (
          <label className="mt-3 block text-[13px] text-ink-muted">
            Class
            <select
              value={current?.classId.toString() ?? ""}
              onChange={(e) => {
                if (e.target.value) {
                  setSelected(BigInt(e.target.value));
                  setAmount("");
                }
              }}
              disabled={flow.busy}
              className="op-field mt-1.5 block w-full px-4 py-2.5 text-[14px] text-ink"
            >
              {!current ? <option value="">Choose a class</option> : null}
              {positionViews.map((v) => (
                <option key={v.classId.toString()} value={v.classId.toString()}>
                  {v.name}{v.approved ? "" : " (approval withdrawn)"}
                </option>
              ))}
            </select>
          </label>
        ) : (
          <p className="mt-3 text-[13px] text-ink-muted">
            Class <span className="text-ink">{current?.name}</span>
          </p>
        )}
        {selectedClassDisappeared ? (
          <p role="alert" className="mt-3 text-[12.5px] leading-relaxed text-danger">
            The selected class is no longer available to this wallet. Choose a current class before
            posting or withdrawing.
          </p>
        ) : null}
        {current ? (
          <div className="mt-3">
            {row("Your posting", `${fmtAmount(current.posted, USDFR_DECIMALS)} USDfr`)}
            {row("Withdrawable now", `${fmtAmount(withdrawable, USDFR_DECIMALS)} USDfr`)}
            {row("Wallet balance", balance !== undefined ? `${fmtAmount(balance, USDFR_DECIMALS)} USDfr` : "unavailable")}
          </div>
        ) : null}
        {current ? (() => {
          const notice = classNotice(current);
          return notice ? <p className="mt-3 text-[12.5px] leading-relaxed text-ink-muted">{notice}</p> : null;
        })() : null}
        {current && !current.approved ? (
          <p className="mt-3 text-[12.5px] leading-relaxed text-ink-muted">
            Approval for new postings in this class has been withdrawn. Your existing capital and
            withdrawal rights are unchanged and remain subject to the class&apos;s ordinary safeguards.
          </p>
        ) : null}

        <AmountInput
          value={amount}
          onChange={setAmount}
          symbol="USDfr"
          maxDecimals={USDFR_DECIMALS}
          disabled={flow.busy || paused}
          invalid={parsed === null && amount !== ""}
          onMax={
            balance !== undefined && balance > 0n
              ? () => setAmount(fmtAmount(balance, USDFR_DECIMALS, USDFR_DECIMALS).replace(/,/g, ""))
              : undefined
          }
        />
        <div className="grid gap-3 sm:grid-cols-2">
          <ActionButton
            label={!current?.approved ? "Posting unavailable" : approvalNeeded ? "Approve USDfr" : "Post first-loss capital"}
            busyLabel={busyLabelFor(flow.status)}
            busy={flow.busy}
            disabled={!canPost}
            onClick={post}
          />
          <ActionButton
            label="Withdraw"
            busyLabel={busyLabelFor(flow.status)}
            busy={flow.busy}
            disabled={!canWithdraw}
            onClick={withdraw}
          />
        </div>
        {parsed !== null && parsed > withdrawable && parsed > 0n && current ? (
          <p className="mt-2 text-[12px] text-ink-faint">
            Withdraw is limited to {fmtAmount(withdrawable, USDFR_DECIMALS)} USDfr in this class right now.
          </p>
        ) : null}
        <StatusLine status={flow.status} />
        {current && flow.status.phase === "error" && flow.status.errorName === "Curator_UnsettledClosedRound" ? (
          <button
            type="button"
            onClick={() => settleClosedRound(current.classId)}
            disabled={flow.busy}
            className="op-action mt-3 px-5 py-2.5 text-[13px]"
          >
            Settle the closed round
          </button>
        ) : null}
        <p className="mt-4 text-[12px] leading-relaxed text-ink-faint">
          Posting moves USDfr from this wallet into the class pool, where it absorbs realised losses
          on facilities in the class before any other capital does. Withdrawal returns pool capital
          the class does not currently require. The agreement you signed governs; this page shows the
          ledger it settles on.
        </p>
      </div>

      <p className="mt-6 text-[12px] leading-relaxed text-ink-faint">
        CuratorModule{" "}
        {explorer(curatorModule) ? (
          <a href={explorer(curatorModule)!} target="_blank" rel="noreferrer" className="text-accent underline-offset-4 hover:underline">
            {shortAddress(curatorModule)}
          </a>
        ) : (
          <span className="font-mono">{shortAddress(curatorModule)}</span>
        )}{" "}
        on {NETWORK_NAME}.
      </p>
    </div>
  );
}
