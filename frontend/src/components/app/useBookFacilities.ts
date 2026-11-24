"use client";

import {useMemo} from "react";
import {parseAbi} from "viem";
import {useReadContract, useReadContracts} from "wagmi";
import {CONTRACTS} from "@/config/contracts";
import {ATTESTATION_ORACLE_ABI, BRIDGE_ABI, RESERVES_ABI} from "@/lib/abi";
import {
  decodeFacilityCollateral,
  decodeFacilityEconomics,
} from "@/lib/book";
import {PROTOCOL_POLL} from "@/lib/polling";

const POLL = PROTOCOL_POLL;
export const MAX_CLIENT_FACILITIES = 1_000n;
const MULTICALL3_ADDRESS = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;
const MULTICALL3_TIMESTAMP_ABI = parseAbi([
  "function getCurrentBlockTimestamp() view returns (uint256 timestamp)",
]);

export type DecodedBookFacility = {
  tokenId: bigint;
  classId: number;
  originalPrincipal: bigint;
  ltvBps: bigint;
  interestRateBps: bigint;
  state: number;
  /** True principal outstanding (accruedDebt.principal when available, falling back to deployedTo). */
  outstandingPrincipal: bigint;
  valuation: bigint;
  valuationAsOf: bigint;
};

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

function decodeAccruedDebtPrincipal(result: unknown): bigint | null {
  if (!result || typeof result !== "object") return null;
  const named = result as {principal?: bigint | number; known?: boolean};
  const positional = result as readonly unknown[];
  const known = named.known ?? (Array.isArray(result) ? positional[8] : undefined);
  if (known !== true) return null;
  const principal = named.principal ?? (Array.isArray(result) ? positional[0] : undefined);
  if (typeof principal !== "bigint" && typeof principal !== "number") return null;
  return BigInt(principal);
}

function decodeBookFacilities(
  facilityCount: bigint | undefined,
  capped: boolean,
  data: readonly {status: "success" | "failure"; result?: unknown}[] | undefined,
): {
  facilityCount: bigint | undefined;
  blockTimestamp: bigint | null;
  facilities: DecodedBookFacility[] | null;
  capped: boolean;
} {
  if (facilityCount === undefined || capped || !data) {
    return {facilityCount, blockTimestamp: null, facilities: null, capped};
  }
  const timestampEntry = data[0];
  if (timestampEntry?.status !== "success" || typeof timestampEntry.result !== "bigint") {
    return {facilityCount, blockTimestamp: null, facilities: null, capped};
  }
  const blockTimestamp = timestampEntry.result;
  if (facilityCount === 0n) {
    return {facilityCount, blockTimestamp, facilities: [], capped};
  }

  const decoded: DecodedBookFacility[] = [];
  for (let index = 0; index < Number(facilityCount); index++) {
    const offset = 1 + index * 4;
    const facilityEntry = data[offset];
    const deployedEntry = data[offset + 1];
    const accruedEntry = data[offset + 2];
    const valuationEntry = data[offset + 3];
    if (
      facilityEntry?.status !== "success" ||
      deployedEntry?.status !== "success" ||
      valuationEntry?.status !== "success"
    ) {
      return {facilityCount, blockTimestamp, facilities: null, capped};
    }
    const economics = decodeFacilityEconomics(facilityEntry.result);
    const collateral = decodeFacilityCollateral(facilityEntry.result);
    const deployed = deployedEntry.result as bigint | undefined;
    const accruedPrincipal =
      accruedEntry?.status === "success" ? decodeAccruedDebtPrincipal(accruedEntry.result) : null;
    const valuation = decodeValuation(valuationEntry.result);
    if (!economics || !collateral || deployed === undefined || !valuation) {
      return {facilityCount, blockTimestamp, facilities: null, capped};
    }
    // Prefer ReserveManager.accruedDebt(tokenId).principal when available & known so continuous
    // interest accrual does not inflate principal-derived collateral reference or coupon weight.
    const outstandingPrincipal = accruedPrincipal !== null ? accruedPrincipal : deployed;
    decoded.push({
      tokenId: BigInt(index + 1),
      ...collateral,
      ...economics,
      outstandingPrincipal,
      valuation: valuation.value,
      valuationAsOf: valuation.asOf,
    });
  }
  return {facilityCount, blockTimestamp, facilities: decoded, capped};
}

/**
 * Shared multicall over enumerable facility NFTs. Used by both `useBookEconomics` and
 * `useCollateralValue` so React Query deduplicates all facility reads into one atomic multicall,
 * including `Multicall3.getCurrentBlockTimestamp()` (eliminating block-vs-multicall timestamp skew)
 * and `ReserveManager.accruedDebt(tokenId)` (using principal-only outstanding balance rather than
 * accrued-interest-inflated `deployedTo`).
 */
export function useBookFacilities(knownFacilityCount?: bigint) {
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
  const capped = facilityCount !== undefined && facilityCount > MAX_CLIENT_FACILITIES;

  const contracts = useMemo(() => {
    if (facilityCount === undefined || facilityCount > MAX_CLIENT_FACILITIES) return [];
    const perFacility = Array.from({length: Number(facilityCount)}, (_, index) => {
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
          address: CONTRACTS.ReserveManager!,
          abi: RESERVES_ABI,
          functionName: "accruedDebt" as const,
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
    return [
      {
        address: MULTICALL3_ADDRESS,
        abi: MULTICALL3_TIMESTAMP_ABI,
        functionName: "getCurrentBlockTimestamp" as const,
      },
      ...perFacility,
    ];
  }, [facilityCount]);

  const {data} = useReadContracts({
    contracts,
    allowFailure: true,
    query: {
      ...POLL,
      enabled: facilityCount !== undefined && facilityCount <= MAX_CLIENT_FACILITIES,
    },
  });

  return useMemo(
    () => decodeBookFacilities(facilityCount, capped, data),
    [capped, data, facilityCount],
  );
}
