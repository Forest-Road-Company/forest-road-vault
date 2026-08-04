"use client";

import {useMemo} from "react";
import {useBlock, useReadContract, useReadContracts} from "wagmi";
import {CONTRACTS} from "@/config/contracts";
import {
  ATTESTATION_ORACLE_ABI,
  BRIDGE_ABI,
  REGISTRY_ABI,
  RESERVES_ABI,
} from "@/lib/abi";
import {
  calculateCollateralValueMetrics,
  decodeClassMaxMarkAge,
  decodeFacilityCollateral,
  DIGITAL_ASSETS_CLASS_ID,
  type CollateralPosition,
} from "@/lib/book";

const POLL = {refetchInterval: 60_000} as const;
const MAX_CLIENT_FACILITIES = 1_000n;

function decodeValuation(result: unknown): {value: bigint; asOf: bigint} | null {
  if (!result || typeof result !== "object") return null;
  const named = result as {value?: number | bigint; asOf?: number | bigint};
  const positional = result as readonly unknown[];
  const value = named.value ?? (Array.isArray(result) ? positional[0] : undefined);
  const asOf = named.asOf ?? (Array.isArray(result) ? positional[1] : undefined);
  if (
    (typeof value !== "number" && typeof value !== "bigint") ||
    (typeof asOf !== "number" && typeof asOf !== "bigint")
  ) {
    return null;
  }
  return {value: BigInt(value), asOf: BigInt(asOf)};
}

/**
 * Aggregates collateral separately from the protocol's accounting backing.
 * Receivables use their signed underwriting reference; MTM facilities use only
 * a currently fresh attested mark.
 */
export function useCollateralValue(knownFacilityCount?: bigint) {
  const facilityReads = useMemo(() => {
    if (
      knownFacilityCount === undefined ||
      knownFacilityCount > MAX_CLIENT_FACILITIES
    ) {
      return [];
    }
    return Array.from({length: Number(knownFacilityCount)}, (_, index) => {
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
        {
          address: CONTRACTS.AttestationOracle!,
          abi: ATTESTATION_ORACLE_ABI,
          functionName: "latestValuation" as const,
          args: [tokenId] as const,
        },
      ];
    }).flat();
  }, [knownFacilityCount]);

  const {data: facilityData} = useReadContracts({
    contracts: facilityReads,
    query: {
      ...POLL,
      enabled:
        knownFacilityCount !== undefined &&
        knownFacilityCount <= MAX_CLIENT_FACILITIES,
    },
  });
  const {data: digitalAssetsClass} = useReadContract({
    address: CONTRACTS.CollateralRegistry!,
    abi: REGISTRY_ABI,
    functionName: "classParams",
    args: [BigInt(DIGITAL_ASSETS_CLASS_ID)],
    query: POLL,
  });
  const {data: currentBlock} = useBlock({query: POLL});

  const metrics = useMemo(() => {
    if (
      knownFacilityCount === undefined ||
      knownFacilityCount > MAX_CLIENT_FACILITIES ||
      currentBlock === undefined
    ) {
      return null;
    }
    const maxMarkAge = decodeClassMaxMarkAge(digitalAssetsClass);
    if (maxMarkAge === null) return null;
    if (knownFacilityCount === 0n) {
      return calculateCollateralValueMetrics(
        [],
        currentBlock.timestamp,
        maxMarkAge,
      );
    }
    if (!facilityData) return null;

    const positions: CollateralPosition[] = [];
    for (let index = 0; index < Number(knownFacilityCount); index++) {
      const offset = index * 3;
      const facility = decodeFacilityCollateral(facilityData[offset]?.result);
      const outstanding = facilityData[offset + 1]?.result as bigint | undefined;
      const valuation = decodeValuation(facilityData[offset + 2]?.result);
      if (!facility || outstanding === undefined || !valuation) return null;
      positions.push({
        ...facility,
        outstandingPrincipal: outstanding,
        valuation: valuation.value,
        valuationAsOf: valuation.asOf,
      });
    }

    return calculateCollateralValueMetrics(
      positions,
      currentBlock.timestamp,
      maxMarkAge,
    );
  }, [
    currentBlock,
    digitalAssetsClass,
    facilityData,
    knownFacilityCount,
  ]);

  return {
    metrics,
    capped:
      knownFacilityCount !== undefined &&
      knownFacilityCount > MAX_CLIENT_FACILITIES,
  };
}
