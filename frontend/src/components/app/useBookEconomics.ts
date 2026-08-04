"use client";

import {useMemo} from "react";
import {useReadContract, useReadContracts} from "wagmi";
import {CONTRACTS} from "@/config/contracts";
import {BRIDGE_ABI, RESERVES_ABI, WATERFALL_ABI} from "@/lib/abi";
import {
  calculateBookYield,
  calculateProjectedSeniorIncome,
  decodeFacilityEconomics,
  type OutstandingLoan,
} from "@/lib/book";

const POLL = {refetchInterval: 60_000} as const;
const MAX_CLIENT_FACILITIES = 1_000n;

/**
 * Client-side aggregation over enumerable facility NFTs. Keeping this in one
 * hook makes the app-position projection and transparency book metrics use the
 * same performing-state filter and principal weighting.
 */
export function useBookEconomics(knownFacilityCount?: bigint) {
  const {data: fetchedFacilityCount} = useReadContract({
    address: CONTRACTS.ClaimBridge!,
    abi: BRIDGE_ABI,
    functionName: "totalOriginated",
    query: {
      ...POLL,
      enabled: knownFacilityCount === undefined,
    },
  });
  const facilityCount = knownFacilityCount ?? fetchedFacilityCount;

  const facilityReads = useMemo(() => {
    if (facilityCount === undefined || facilityCount > MAX_CLIENT_FACILITIES) return [];
    return Array.from({length: Number(facilityCount)}, (_, index) => {
      const tokenId = BigInt(index + 1);
      return [
        {
          address: CONTRACTS.ClaimBridge!,
          abi: BRIDGE_ABI,
          functionName: "facility" as const,
          args: [tokenId] as const,
        },
        {
          address: CONTRACTS.ReserveManager!,
          abi: RESERVES_ABI,
          functionName: "deployedTo" as const,
          args: [tokenId] as const,
        },
      ];
    }).flat();
  }, [facilityCount]);

  const {data: facilityData} = useReadContracts({
    contracts: facilityReads,
    query: {
      ...POLL,
      enabled:
        facilityCount !== undefined && facilityCount <= MAX_CLIENT_FACILITIES,
    },
  });
  const {data: protocolFeeBps} = useReadContract({
    address: CONTRACTS.WaterfallEngine!,
    abi: WATERFALL_ABI,
    functionName: "protocolFeeBps",
    query: POLL,
  });

  const loans = useMemo(() => {
    if (facilityCount === undefined || facilityCount > MAX_CLIENT_FACILITIES) return null;
    if (facilityCount === 0n) return [] as OutstandingLoan[];
    if (!facilityData) return null;

    const decoded: OutstandingLoan[] = [];
    for (let index = 0; index < Number(facilityCount); index++) {
      const offset = index * 2;
      const facilityResult = decodeFacilityEconomics(facilityData[offset]?.result);
      const outstanding = facilityData[offset + 1]?.result as bigint | undefined;
      if (!facilityResult || outstanding === undefined) {
        return null;
      }
      decoded.push({
        outstandingPrincipal: outstanding,
        interestRateBps: facilityResult.interestRateBps,
        state: facilityResult.state,
      });
    }
    return decoded;
  }, [facilityCount, facilityData]);

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
    capped: facilityCount !== undefined && facilityCount > MAX_CLIENT_FACILITIES,
  };
}
