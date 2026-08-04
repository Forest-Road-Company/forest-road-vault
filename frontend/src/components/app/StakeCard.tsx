"use client";

/**
 * Stake: USDfr → sUSDfr via the ERC-4626 vault's `deposit`. Shows the live
 * exchange rate and the exact share preview (`previewDeposit`) before signing.
 * Same two-step allowance UX as mint.
 */

import {useState} from "react";
import {parseUnits, zeroAddress} from "viem";
import {useAccount, useReadContract, useReadContracts} from "wagmi";
import {
  CONTRACTS,
  IS_TESTNET,
  SUPPORTS_VAULT_FEE_ACCOUNTING,
} from "@/config/contracts";
import {ERC20_ABI, IMPAIRMENT_SOURCE_ABI, SHARE_DECIMALS, VAULT_ABI} from "@/lib/abi";
import {fmtAmount} from "@/lib/format";
import {formatBps} from "@/lib/yield";
import {useWriteFlow} from "@/components/app/useWriteFlow";
import {ActionButton, AmountInput, StatusLine, busyLabelFor} from "@/components/app/WriteBits";

const POLL = {refetchInterval: 30_000} as const;

export function StakeCard({writesEnabled}: {writesEnabled: boolean}) {
  const {address} = useAccount();
  const [amount, setAmount] = useState("");
  const flow = useWriteFlow();

  const usdfr = CONTRACTS.USDfr!;
  const vault = CONTRACTS.sUSDfr!;

  const {data: balance} = useReadContract({
    address: usdfr,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: {enabled: Boolean(address), ...POLL},
  });
  const {data: allowance} = useReadContract({
    address: usdfr,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: address ? [address, vault] : undefined,
    query: {enabled: Boolean(address), ...POLL},
  });
  const {data: rate} = useReadContract({
    address: vault,
    abi: VAULT_ABI,
    functionName: "currentExchangeRate",
    query: POLL,
  });
  const {data: feeData} = useReadContracts({
    query: {enabled: SUPPORTS_VAULT_FEE_ACCOUNTING, ...POLL},
    contracts: [
      {address: vault, abi: VAULT_ABI, functionName: "performanceFeeBps"},
      {address: vault, abi: VAULT_ABI, functionName: "maxPerformanceFeeBps"},
      {address: vault, abi: VAULT_ABI, functionName: "managementFeeBps"},
      {address: vault, abi: VAULT_ABI, functionName: "highWaterMark"},
      {address: vault, abi: VAULT_ABI, functionName: "feeExchangeRate"},
      {address: vault, abi: VAULT_ABI, functionName: "maxManagementFeeBps"},
      // Needed to reconstruct the ASSET-denominated hurdle. The gross mark alone does not
      // establish exposure: the deferred fee is zero while the hurdle still sits above
      // realized assets, however large the mark is (audit R15-01).
      {address: vault, abi: VAULT_ABI, functionName: "totalAssets"},
      {address: vault, abi: VAULT_ABI, functionName: "totalSupply"},
    ],
  });
  const performanceFeeBps = feeData?.[0]?.result as number | undefined;
  const maxPerformanceFeeBps = feeData?.[1]?.result as number | undefined;
  const managementFeeBps = feeData?.[2]?.result as number | undefined;
  const highWaterMark = feeData?.[3]?.result as bigint | undefined;
  const feeExchangeRate = feeData?.[4]?.result as bigint | undefined;
  const maxManagementFeeBps = feeData?.[5]?.result as number | undefined;
  const vaultTotalAssets = feeData?.[6]?.result as bigint | undefined;
  const vaultTotalSupply = feeData?.[7]?.result as bigint | undefined;

  let parsed: bigint | null = null;
  try {
    parsed = amount ? parseUnits(amount, 18) : null;
  } catch {
    parsed = null;
  }

  const {data: previewShares} = useReadContract({
    address: vault,
    abi: VAULT_ABI,
    functionName: "previewDeposit",
    args: parsed !== null && parsed > 0n ? [parsed] : undefined,
    query: {enabled: parsed !== null && parsed > 0n, ...POLL},
  });
  const {data: previewExitAssets} = useReadContract({
    address: vault,
    abi: VAULT_ABI,
    functionName: "previewRedeem",
    args: previewShares !== undefined && previewShares > 0n ? [previewShares] : undefined,
    query: {enabled: previewShares !== undefined && previewShares > 0n, ...POLL},
  });
  const {data: impairmentSource} = useReadContract({
    address: vault,
    abi: VAULT_ABI,
    functionName: "impairmentSource",
    query: POLL,
  });
  const hasImpairmentSource =
    impairmentSource !== undefined && impairmentSource !== zeroAddress;
  const {data: pendingSeniorImpairment} = useReadContract({
    address: impairmentSource ?? zeroAddress,
    abi: IMPAIRMENT_SOURCE_ABI,
    functionName: "pendingSeniorImpairment",
    query: {enabled: hasImpairmentSource, ...POLL},
  });
  // The GROSS mark (ADR-0031), which sizes the deferred performance fee. Distinct from the
  // netted figure above: junior capital can take the netted mark to zero while the gross
  // mark — and therefore the deferred fee a new depositor buys into — is still large.
  const {data: performanceFeeImpairment} = useReadContract({
    address: impairmentSource ?? zeroAddress,
    abi: IMPAIRMENT_SOURCE_ABI,
    functionName: "performanceFeeImpairment",
    query: {enabled: hasImpairmentSource, ...POLL},
  });
  // Do not infer impairment from `previewExitAssets < parsed`: the two previews are
  // independent RPC reads, and repayments or impairment changes can move NAV between
  // blocks. The source's absolute senior mark is the canonical signal.
  const exitImpaired = hasImpairmentSource && (pendingSeniorImpairment ?? 0n) > 0n;
  // AUDIT R14-03. The deferred fee that crystallizes when a mark cures is
  // `performanceFeeBps * max(0, grossMark - feeFreeRunway)`, where the runway is the gap
  // between the hurdle and the performance base. It is LARGEST when that gap is zero and
  // zero once the gap exceeds the gross mark — so keying the warning on the gap alone was
  // inverse to the exposure it advertises, and silent in exactly the maximal-deferral state
  // that per-repayment crystallization now makes the steady state. Key it on the gross mark
  // instead, which is the quantity actually at stake.
  // AUDIT R15-01. Two terms, not one. The deferred fee that crystallizes on a cure is
  // `performanceFeeBps * min(grossMark, max(0, totalAssets + 1 - hurdleAssets))`, so it is
  // zero both when there is no mark AND when the hurdle still sits above realized assets.
  // Keying on the gross mark alone fired at full strength at zero exposure — most visibly
  // right after `markPastDue`, which checkpoints before recording the mark. The hurdle is
  // asset-denominated: `ceil(highWaterMark * (totalSupply + 1e6) / 10**decimals())`, mirroring
  // `_highWaterMarkAssets`. `currentExchangeRate() > highWaterMark` is NOT a safe substitute —
  // it divides by the fee-adjusted supply, so simulated management shares would depress it
  // below the hurdle while realized assets are still above it.
  const SHARE_UNIT = 10n ** 24n; // sUSDfr decimals() = 18 underlying + 6 offset
  const hurdleAssets =
    highWaterMark !== undefined && vaultTotalSupply !== undefined
      ? (highWaterMark * (vaultTotalSupply + 10n ** 6n) + SHARE_UNIT - 1n) / SHARE_UNIT
      : undefined;
  const aboveHurdle =
    vaultTotalAssets !== undefined && hurdleAssets !== undefined
      ? vaultTotalAssets + 1n > hurdleAssets
        ? vaultTotalAssets + 1n - hurdleAssets
        : 0n
      : 0n;
  const grossMark = hasImpairmentSource ? (performanceFeeImpairment ?? 0n) : 0n;
  const chargeableDeferral = grossMark < aboveHurdle ? grossMark : aboveHurdle;
  const deferredPerformanceFeeExposure =
    SUPPORTS_VAULT_FEE_ACCOUNTING && (performanceFeeBps ?? 0) > 0 && chargeableDeferral > 0n;
  // The banner's comparison clause asserts an ordering the gate above does not establish.
  // Render it only when it is actually true, with more than the one-wei Ceil/Floor dust gap
  // that separates the stored hurdle from the reported rate after every checkpoint.
  const performanceNavBelowHurdle =
    feeExchangeRate !== undefined && highWaterMark !== undefined && highWaterMark > feeExchangeRate + 1n;

  const needsApproval =
    parsed !== null && parsed > 0n && allowance !== undefined && allowance < parsed;
  // allowance must have LOADED before the Approve/Stake label can be honest.
  const canSubmit =
    writesEnabled && parsed !== null && parsed > 0n && allowance !== undefined && !flow.busy;

  const act = () => {
    if (parsed === null || !address) return;
    if (needsApproval) {
      flow.run({address: usdfr, abi: ERC20_ABI, functionName: "approve", args: [vault, parsed]});
    } else {
      flow.run({
        address: vault,
        abi: VAULT_ABI,
        functionName: "deposit",
        args: [parsed, address],
        onSuccess: () => setAmount(""),
      });
    }
  };

  return (
    <div className="panel flex h-full flex-col p-6">
      <div className="flex items-baseline justify-between">
        <h3 className="font-grotesk text-[16px] font-semibold tracking-tight">Stake</h3>
        <p className="font-mono text-[10.5px] uppercase tracking-[0.14em] text-ink-faint">
          USDfr → sUSDfr
        </p>
      </div>
      <p className="mt-2 text-[13px] leading-relaxed text-ink-muted">
        Stake into the sUSDfr vault at the current exchange rate. Yield is the book&apos;s
        actual performance — variable, never fixed. The displayed rate and share quote
        {SUPPORTS_VAULT_FEE_ACCOUNTING
          ? "simulate all fees due at this block."
          : "reflect this legacy Sepolia deployment, which predates vault-level fees."}
      </p>

      <p className="mt-4 font-mono text-[11px] text-ink-faint">
        Balance:{" "}
        <span className="text-ink-muted">
          {balance !== undefined ? fmtAmount(balance, 18) : "—"} USDfr
        </span>
        <span className="ml-3">
          Rate:{" "}
          <span className="text-ink-muted">
            {rate !== undefined ? `1 sUSDfr = ${fmtAmount(rate, 18, 4)} USDfr` : "—"}
          </span>
        </span>
      </p>

      <AmountInput
        value={amount}
        onChange={setAmount}
        symbol="USDfr"
        maxDecimals={18}
        disabled={!writesEnabled || flow.busy}
        onMax={
          balance !== undefined && balance > 0n
            ? () => setAmount(fmtAmount(balance, 18, 18).replace(/,/g, ""))
            : undefined
        }
      />

      {previewShares !== undefined && parsed !== null && parsed > 0n ? (
        <p className="mt-2 font-mono text-[11px] text-ink-faint">
          You receive ≈ <span className="text-ink-muted">{fmtAmount(previewShares, SHARE_DECIMALS, 4)} sUSDfr</span>
        </p>
      ) : null}

      {exitImpaired && parsed !== null && previewExitAssets !== undefined ? (
        <div className="mt-3 rounded-card border border-warn/40 bg-warn/10 px-4 py-3">
          <p className="text-[12.5px] leading-relaxed text-ink">
            <span className="font-medium">Queued exit NAV is currently impaired.</span>{" "}
            <span className="text-ink-muted">
              This deposit mints at realized NAV, but the shares would currently queue-exit for
              about {fmtAmount(previewExitAssets, 18, 4)} USDfr, not {fmtAmount(parsed, 18, 4)}
              {" "}USDfr. The exit estimate reflects the current conservative default mark and
              can change before settlement.{" "}
              {IS_TESTNET
                ? "A separately funded testnet top-up tool may be exercised, but no top-up or airdrop is promised, automatic, or included in this value."
                : "Mainnet v1 has no recovery top-up distributor; no top-up or airdrop is promised or included in this value."}
            </span>
          </p>
        </div>
      ) : null}

      {deferredPerformanceFeeExposure ? (
        <div className="mt-3 rounded-card border border-warn/40 bg-warn/10 px-4 py-3">
          <p className="text-[12.5px] leading-relaxed text-ink">
            <span className="font-medium">Global performance-fee exposure is deferred.</span>{" "}
            <span className="text-ink-muted">
              {performanceNavBelowHurdle ? (
                <>
                  Performance NAV is currently below the protocol-wide high-water mark
                  ({fmtAmount(feeExchangeRate, 18, 4)} vs {fmtAmount(highWaterMark, 18, 4)}
                  {" "}USDfr per share).{" "}
                </>
              ) : null}
              About {fmtAmount(chargeableDeferral, 18, 2)} USDfr of gains sit below the global
              hurdle and have not been charged yet. A new depositor joins that shared accounting
              pool and may bear the configured performance fee when those deferred pre-entry
              gains are later recognized above the hurdle. This is not a personal entry-price or
              per-investor high-water mark, and the exposure can exist even when queued-exit
              impairment is currently zero.
            </span>
          </p>
        </div>
      ) : null}

      <ActionButton
        label={needsApproval ? "Approve USDfr" : "Stake"}
        busyLabel={busyLabelFor(flow.status)}
        busy={flow.busy}
        disabled={!canSubmit}
        onClick={act}
      />
      <StatusLine status={flow.status} />

      <p className="mt-auto border-t border-line pt-4 text-[12px] leading-snug text-ink-faint">
        Exits are not instant: unstaking goes through the epoch-based redemption queue
        (see Redeem).{" "}
        {SUPPORTS_VAULT_FEE_ACCOUNTING ? (
          <>
            The vault charges{" "}
            {performanceFeeBps !== undefined
              ? formatBps(BigInt(performanceFeeBps))
              : "—"}{" "}
            on profit above one global high-water mark
            {maxPerformanceFeeBps !== undefined
              ? ` (capped at ${formatBps(BigInt(maxPerformanceFeeBps))})`
              : ""}
            . Management is currently{" "}
            {managementFeeBps !== undefined
              ? formatBps(BigInt(managementFeeBps))
              : "—"}
            {maxManagementFeeBps !== undefined
              ? ` annual (capped at ${formatBps(BigInt(maxManagementFeeBps))})`
              : ""}
            .
          </>
        ) : (
          "The configured legacy Sepolia vault predates ADR-0031; performance and management fee reads are disabled."
        )}
      </p>
    </div>
  );
}
