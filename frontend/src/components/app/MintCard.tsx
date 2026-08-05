"use client";

/** Deposit USDC and mint USDfr 1:1 through the USDC-only controller. */

import {useState} from "react";
import {parseUnits} from "viem";
import {useAccount, useReadContract} from "wagmi";
import {CONTRACTS, IS_TESTNET, STABLE_SYMBOL} from "@/config/contracts";
import {CONTROLLER_ABI, ERC20_ABI, TEST_STABLE_ABI} from "@/lib/abi";
import {fmtAmount} from "@/lib/format";
import {useWriteFlow} from "@/components/app/useWriteFlow";
import {ActionButton, AmountInput, StatusLine, busyLabelFor} from "@/components/app/WriteBits";

const STABLE_DECIMALS = 6;
const FAUCET_AMOUNT = parseUnits("10000", STABLE_DECIMALS);
const POLL = {refetchInterval: 30_000} as const;

export function MintCard({writesEnabled, chainOk}: {writesEnabled: boolean; chainOk: boolean}) {
  const {address} = useAccount();
  const [amount, setAmount] = useState("");
  const flow = useWriteFlow();
  const faucet = useWriteFlow();

  const stable = CONTRACTS.USDC!;
  const controller = CONTRACTS.MintRedeemController!;

  const {data: balance} = useReadContract({
    address: stable,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: {enabled: Boolean(address), ...POLL},
  });
  const {data: allowance} = useReadContract({
    address: stable,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: address ? [address, controller] : undefined,
    query: {enabled: Boolean(address), ...POLL},
  });

  let parsed: bigint | null = null;
  try {
    parsed = amount ? parseUnits(amount, STABLE_DECIMALS) : null;
  } catch {
    parsed = null;
  }
  const needsApproval =
    parsed !== null && parsed > 0n && allowance !== undefined && allowance < parsed;
  // allowance must have LOADED before we can honestly label the button
  // "Approve" vs "Mint" — until then the action stays disabled.
  const canSubmit =
    writesEnabled && parsed !== null && parsed > 0n && allowance !== undefined && !flow.busy;

  const act = () => {
    if (parsed === null) return;
    if (needsApproval) {
      flow.run({
        address: stable,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [controller, parsed],
      });
    } else {
      flow.run({
        address: controller,
        abi: CONTROLLER_ABI,
        functionName: "mint",
        args: [parsed],
        onSuccess: () => setAmount(""),
      });
    }
  };

  return (
    <div className="panel flex h-full flex-col p-6">
      <div className="flex items-baseline justify-between">
        <h3 className="font-grotesk text-[16px] font-semibold tracking-tight">Deposit &amp; mint</h3>
        <p className="font-mono text-[10.5px] uppercase tracking-[0.14em] text-ink-faint">
          {STABLE_SYMBOL} → USDfr
        </p>
      </div>
      <p className="mt-2 text-[13px] leading-relaxed text-ink-muted">
        Deposit {STABLE_SYMBOL}, mint USDfr 1:1. KYC-verified addresses only.
      </p>

      <p className="mt-4 font-mono text-[11px] text-ink-faint">
        Balance:{" "}
        <span className="text-ink-muted">
          {balance !== undefined ? fmtAmount(balance, STABLE_DECIMALS) : "—"} {STABLE_SYMBOL}
        </span>
      </p>

      <AmountInput
        value={amount}
        onChange={setAmount}
        symbol={STABLE_SYMBOL}
        maxDecimals={STABLE_DECIMALS}
        disabled={!writesEnabled || flow.busy}
        onMax={
          balance !== undefined && balance > 0n
            ? () => setAmount(fmtAmount(balance, STABLE_DECIMALS, STABLE_DECIMALS).replace(/,/g, ""))
            : undefined
        }
      />

      <ActionButton
        label={needsApproval ? `Approve ${STABLE_SYMBOL}` : "Mint USDfr"}
        busyLabel={busyLabelFor(flow.status)}
        busy={flow.busy}
        disabled={!canSubmit}
        onClick={act}
      />
      <StatusLine status={flow.status} />

      {IS_TESTNET ? (
        <div className="mt-auto border-t border-line pt-4">
          <div className="flex items-center justify-between gap-3">
            <p className="text-[12px] leading-snug text-ink-faint">
              Need test funds? The testnet mock stable has an open faucet.
            </p>
            <button
              onClick={() =>
                address &&
                faucet.run({
                  address: stable,
                  abi: TEST_STABLE_ABI,
                  functionName: "mint",
                  args: [address, FAUCET_AMOUNT],
                })
              }
              disabled={!chainOk || !address || faucet.busy}
              className="shrink-0 rounded-pill border border-line-strong px-3.5 py-1.5 font-mono text-[10.5px] uppercase tracking-[0.12em] text-ink-muted transition-colors hover:border-moss/60 hover:text-moss disabled:opacity-50"
            >
              {faucet.busy ? "Minting…" : "Get 10,000 tUSDC"}
            </button>
          </div>
          <StatusLine status={faucet.status} />
        </div>
      ) : (
        <p className="mt-auto border-t border-line pt-4 text-[12px] leading-snug text-ink-faint">
          Mainnet uses canonical Ethereum USDC. There is no faucet or alternate reserve asset.
        </p>
      )}
    </div>
  );
}
