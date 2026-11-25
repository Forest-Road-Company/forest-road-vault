import React from "react";
import {act, renderHook, waitFor} from "@testing-library/react";
import {QueryClient, QueryClientProvider} from "@tanstack/react-query";
import {BaseError, RawContractError} from "viem";
import {describe, expect, it, vi} from "vitest";

const state = vi.hoisted(() => ({exposure: 0n, missing: false, failExposure: false, failSlot: false,
  exposureQuery: null as unknown, slotQuery: null as unknown}));
vi.mock("@/config/contracts", () => ({CHAIN_ID: 1}));
vi.mock("wagmi", async () => {
  const {useQuery} = await import("@tanstack/react-query");
  return {
    useReadContract({query}: {query: {refetchInterval: number}}) {
      const result = useQuery({queryKey: ["exposure"], queryFn: async () => {
        if (state.failExposure) throw new Error("read unavailable");
        if (state.missing) throw new BaseError("missing selector", {cause: new RawContractError({data: "0x"})});
        return state.exposure;
      }, ...query});
      state.exposureQuery = result;
      return result;
    },
    useStorageAt({query}: {query: {refetchInterval: number; enabled: boolean}}) {
      const result = useQuery({queryKey: ["slot"], queryFn: async () => {
        if (state.failSlot) throw new Error("storage unavailable");
        return "0x0000000000000000000000000b78342501d67ec03af1d8e0a60c900bb227d38b";
      }, ...query});
      state.slotQuery = result;
      return result;
    },
  };
});
import {useVaultExitFreeze} from "./useVaultExitFreeze";

function mount() {
  // Keep a retry pending for a minute: error remains null, failureReason already records
  // the first failed attempt. A test cannot pass by waiting for all retries to finish.
  const client = new QueryClient({defaultOptions: {queries: {retry: 3, retryDelay: 60_000}}});
  const wrapper = ({children}: {children: React.ReactNode}) =>
    <QueryClientProvider client={client}>{children}</QueryClientProvider>;
  const hook = renderHook(() => useVaultExitFreeze("0xAF559d1D59B33ca4b950AB2091372Af8a773E234",
    {refetchInterval: 600_000}), {wrapper});
  return {hook, client, close: () => {hook.unmount(); client.clear();}};
}

describe("MV-02: cached freeze status during a real TanStack retry", () => {
  it.each([0n, 100n])("demotes cached exposure %s on the first failed attempt, before error is set", async (exposure) => {
    Object.assign(state, {exposure, missing: false, failExposure: false, failSlot: false});
    const s = mount();
    try {
      await waitFor(() => expect(s.hook.result.current).toEqual({kind: "vault", exposure}));
      state.failExposure = true;
      act(() => {void s.client.refetchQueries({queryKey: ["exposure"]});});
      await waitFor(() => expect(s.hook.result.current).toEqual({kind: "unavailable"}));
      expect(state.exposureQuery).toMatchObject({data: exposure, error: null, failureCount: 1, fetchStatus: "fetching"});
    } finally {s.close();}
  });

  it("demotes a cached legacy implementation on the first failed storage attempt", async () => {
    Object.assign(state, {exposure: 0n, missing: true, failExposure: false, failSlot: false});
    const s = mount();
    try {
      await waitFor(() => expect(s.hook.result.current).toEqual({kind: "legacy-vault"}));
      state.failSlot = true;
      act(() => {void s.client.refetchQueries({queryKey: ["slot"]});});
      await waitFor(() => expect(s.hook.result.current).toEqual({kind: "unavailable"}));
      expect(state.slotQuery).toMatchObject({error: null, failureCount: 1, fetchStatus: "fetching"});
    } finally {s.close();}
  });
});
