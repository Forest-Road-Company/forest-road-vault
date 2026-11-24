"use client";

import {useMemo} from "react";
import {useReadContract} from "wagmi";
import {CONTRACTS} from "@/config/contracts";
import {WATERFALL_ABI} from "@/lib/abi";
import {
  calculateBookYield,
  calculateProjectedSeniorIncome,
  type OutstandingLoan,
} from "@/lib/book";
import {useBookFacilities} from "@/components/app/useBookFacilities";
import {PROTOCOL_POLL} from "@/lib/polling";

const POLL = PROTOCOL_POLL;

/**
 * Client-side aggregation over enumerable facility NFTs. Shares `useBookFacilities` with
 * `useCollateralValue` so `/transparency` performs one deduplicated multicall and uses principal-only
 * `accruedDebt.principal` (fallback `deployedTo`) everywhere.
 */
export function useBookEconomics(knownFacilityCount?: bigint) {
  const {facilityCount, facilities, capped} = useBookFacilities(knownFacilityCount);
  const {data: protocolFeeBps} = useReadContract({
    address: CONTRACTS.WaterfallEngine!,
    abi: WATERFALL_ABI,
    functionName: "protocolFeeBps",
    query: POLL,
  });

  const loans = useMemo(() => {
    if (!facilities) return null;
    return facilities.map(
      (facility): OutstandingLoan => ({
        outstandingPrincipal: facility.outstandingPrincipal,
        interestRateBps: facility.interestRateBps,
        state: facility.state,
      }),
    );
  }, [facilities]);

  const metrics = useMemo(
    () => (loans === null ? null : calculateBookYield(loans)),
    [loans],
  );
  const projectedSeniorIncome =
    loans !== null && protocolFeeBps !== undefined
      ? calculateProjectedSeniorIncome(loans, BigInt(protocolFeeBps))
      : null;

  return {
    facilityCount,
    metrics,
    protocolFeeBps:
      protocolFeeBps === undefined ? undefined : BigInt(protocolFeeBps),
    projectedSeniorIncome,
    capped,
  };
}
