"use client";

import {useMemo} from "react";
import {useReadContract} from "wagmi";
import {CONTRACTS} from "@/config/contracts";
import {REGISTRY_ABI} from "@/lib/abi";
import {
  calculateCollateralValueMetrics,
  decodeClassMaxMarkAge,
  DIGITAL_ASSETS_CLASS_ID,
  type CollateralPosition,
} from "@/lib/book";
import {useBookFacilities} from "@/components/app/useBookFacilities";
import {PROTOCOL_POLL} from "@/lib/polling";

const POLL = PROTOCOL_POLL;

/**
 * Aggregates collateral separately from the protocol's accounting backing.
 * Receivables use their signed underwriting reference derived from principal-only
 * `accruedDebt.principal` (fallback `deployedTo`); MTM facilities use their latest attested mark
 * evaluated against the exact block timestamp from the same multicall.
 */
export function useCollateralValue(knownFacilityCount?: bigint) {
  const {blockTimestamp, facilities, capped} = useBookFacilities(knownFacilityCount);
  const {data: digitalAssetsClass} = useReadContract({
    address: CONTRACTS.CollateralRegistry!,
    abi: REGISTRY_ABI,
    functionName: "classParams",
    args: [BigInt(DIGITAL_ASSETS_CLASS_ID)],
    query: POLL,
  });

  const metrics = useMemo(() => {
    if (blockTimestamp === null || !facilities) return null;
    const maxMarkAge = decodeClassMaxMarkAge(digitalAssetsClass);
    if (maxMarkAge === null) return null;

    const positions: CollateralPosition[] = facilities.map((facility) => ({
      classId: facility.classId,
      originalPrincipal: facility.originalPrincipal,
      ltvBps: facility.ltvBps,
      outstandingPrincipal: facility.outstandingPrincipal,
      valuation: facility.valuation,
      valuationAsOf: facility.valuationAsOf,
    }));

    return calculateCollateralValueMetrics(positions, blockTimestamp, maxMarkAge);
  }, [blockTimestamp, digitalAssetsClass, facilities]);

  return {metrics, capped};
}
