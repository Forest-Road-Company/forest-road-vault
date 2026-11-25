"use client";

import type {Address} from "viem";
import {useReadContract, useStorageAt} from "wagmi";
import {CHAIN_ID} from "@/config/contracts";
import {VAULT_STAGE2_ABI} from "@/lib/abi";
import {
  ERC1967_IMPLEMENTATION_SLOT,
  classifyExitFreeze,
  needsImplementationProbe,
  type ExitFreezeRead,
} from "@/lib/exitFreeze";

/**
 * The vault's LMV-09 exit-freeze state (audit JO-04). The implementation slot is read only after the
 * exposure read has failed with an empty revert on a vault that has a reviewed pre-freeze
 * implementation, so the released vault costs no extra read.
 */
export function useVaultExitFreeze(vault: Address, poll: {readonly refetchInterval: number}): ExitFreezeRead {
  const exposure = useReadContract({
    address: vault, abi: VAULT_STAGE2_ABI, functionName: "unresolvedPastDueExposure", query: poll,
  });
  // TanStack retains cached data and leaves error null while retrying a refetch. The
  // first failed attempt already makes that cached answer unsuitable for a clear status.
  const exposureError = exposure.failureReason ?? exposure.error;
  const probe = needsImplementationProbe(CHAIN_ID, vault, exposure.data, exposureError);
  const implementation = useStorageAt({
    address: vault, slot: ERC1967_IMPLEMENTATION_SLOT, query: {...poll, enabled: probe},
  });
  return classifyExitFreeze({
    chainId: CHAIN_ID,
    vault,
    data: exposure.data,
    error: exposureError,
    implementationSlot: probe ? implementation.data : undefined,
    implementationError: probe ? (implementation.failureReason ?? implementation.error) : undefined,
  });
}
