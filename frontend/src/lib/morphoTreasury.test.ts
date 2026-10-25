import {describe, expect, it, vi} from "vitest";
import type SafeAppsSDK from "@safe-global/safe-apps-sdk";
import type {PublicClient} from "viem";
import {MORPHO_MARKET} from "./morphoMarket";
import {assertNoTreasurySupply, clearResolvedTreasuryProposal, readTreasuryProposal, reserveTreasuryProposal,
  REVIEWED_TREASURY_GENERATOR, saveTreasuryProposal, treasuryProposalState, TREASURY_PROPOSAL_KEY} from "./morphoTreasury";

const HASH = `0x${"ab".repeat(32)}` as const;
function storage() {
  const values = new Map<string, string>();
  return {getItem: vi.fn((key: string) => values.get(key) ?? null), setItem: vi.fn((key: string, value: string) => {values.set(key, value);}),
    removeItem: vi.fn((key: string) => {values.delete(key);})};
}
function gateway(status = "AWAITING_CONFIRMATIONS", liveNonce = 15n, proposalNonce = 15) {
  const details: {safeAddress: string; txStatus: string; detailedExecutionInfo: {type: string; safeTxHash: string; nonce: number}} =
    {safeAddress: MORPHO_MARKET.treasury, txStatus: status, detailedExecutionInfo: {type: "MULTISIG", safeTxHash: HASH, nonce: proposalNonce}};
  const lookup = vi.fn(async () => details), nonce = vi.fn(async () => liveNonce);
  return {sdk: {txs: {getBySafeTxHash: lookup}} as unknown as SafeAppsSDK, client: {readContract: nonce} as unknown as PublicClient,
    details, lookup, nonce};
}

describe("chunked Treasury contribution history", () => {
  it("reads contiguous non-overlapping 1000-block chunks with all filters and a bounded tail", async () => {
    const getLogs = vi.fn<(request: Record<string, unknown>) => Promise<unknown[]>>().mockResolvedValue([]);
    await assertNoTreasurySupply({getLogs} as unknown as PublicClient, 26_234_246n);
    expect(getLogs).toHaveBeenCalledTimes(3);
    expect(getLogs.mock.calls.map(call => (call as unknown as [{fromBlock: bigint; toBlock: bigint}])[0]).map(({fromBlock, toBlock}) => [fromBlock, toBlock]))
      .toEqual([[26_232_245n, 26_233_244n], [26_233_245n, 26_234_244n], [26_234_245n, 26_234_246n]]);
    expect(getLogs.mock.calls[0][0]).toMatchObject({address: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb", strict: true,
      args: {id: "0xf25b12a81e96dfcc882038cd53ec32a6d74ac46186c867ade041d1cf34e2e897",
        caller: "0x0687a13c490B2573d4666fb3a7c21826a621215E", onBehalf: "0x0687a13c490B2573d4666fb3a7c21826a621215E"}});
  });
  it("stops at the first own executed contribution, including after withdrawal of its shares", async () => {
    const getLogs = vi.fn().mockResolvedValueOnce([]).mockResolvedValueOnce([{args: {assets: 50_000_000_000n, shares: 1n}}]);
    await expect(assertNoTreasurySupply({getLogs} as unknown as PublicClient, 26_234_246n)).rejects.toThrow(/already supplied/);
    expect(getLogs).toHaveBeenCalledTimes(2);
  });
  it("does not mistake zero-asset or zero-share logs for a contribution", async () => {
    const getLogs = vi.fn(async () => [{args: {assets: 0n, shares: 1n}}, {args: {assets: 1n, shares: 0n}}]);
    await expect(assertNoTreasurySupply({getLogs} as unknown as PublicClient, MORPHO_MARKET.fromBlock)).resolves.toBeUndefined();
  });
  it("distinguishes unavailable history from an already completed supply", async () => {
    const getLogs = vi.fn().mockResolvedValueOnce([]).mockRejectedValueOnce(new Error("provider log limit"));
    await expect(assertNoTreasurySupply({getLogs} as unknown as PublicClient, 26_234_246n)).rejects.toThrow(/history is unavailable/);
    await expect(assertNoTreasurySupply({getLogs} as unknown as PublicClient, MORPHO_MARKET.fromBlock - 1n)).rejects.toThrow(/history is unavailable/);
  });
});

describe("persistent Treasury proposal protection", () => {
  it("persists the exact intent before sending, then the Safe hash, and refuses a second intent", () => {
    const s = storage();expect(readTreasuryProposal(s)).toBeNull();
    const intent = reserveTreasuryProposal(s, 15n);
    expect(readTreasuryProposal(s)).toEqual({version: 1, nonce: "15", digest: "0x5495cf4fc2607ad3327b3d7df4eaf9b8d53f3c4fba9c943bf7160ea5aba3f11b", hash: null});
    expect(() => reserveTreasuryProposal(s, 15n)).toThrow(/already recorded/);
    saveTreasuryProposal(s, intent, HASH);expect(readTreasuryProposal(s)!.hash).toBe(HASH);
    expect(() => reserveTreasuryProposal(s, 16n)).toThrow(/already recorded/);
  });
  it("fails closed on a write failure or a write that does not persist", () => {
    const s = storage();s.setItem.mockImplementation(() => {throw new Error("storage full");});
    expect(() => reserveTreasuryProposal(s, 15n)).toThrow("storage full");
    s.setItem.mockImplementation(() => {});expect(() => reserveTreasuryProposal(s, 15n)).toThrow(/could not be saved/);
  });
  it.each(["not JSON", "null", '{"version":2}', '{"version":1,"nonce":"-1"}'])("refuses a corrupt saved record %s", raw => {
    const s = storage();s.setItem(TREASURY_PROPOSAL_KEY, raw);expect(() => readTreasuryProposal(s)).toThrow();
  });
  it.each(["digest", "hash", "nonce"])("refuses changed %s in a saved record", key => {
    const s = storage(), intent = reserveTreasuryProposal(s, 15n);
    s.setItem(TREASURY_PROPOSAL_KEY, JSON.stringify({...intent, [key]: "invalid"}));expect(() => readTreasuryProposal(s)).toThrow(/could not be verified/);
  });
  it("never replaces an existing hash or loses an intent on an invalid reply", () => {
    const s = storage(), intent = reserveTreasuryProposal(s, 15n);
    expect(() => saveTreasuryProposal(s, intent, "0x1234")).toThrow(/uncertain/);expect(readTreasuryProposal(s)!.hash).toBeNull();
    saveTreasuryProposal(s, intent, HASH);expect(() => saveTreasuryProposal(s, intent, HASH)).toThrow(/uncertain/);
    expect(() => reserveTreasuryProposal(storage(), -1n)).toThrow(/Invalid Treasury nonce/);
  });
  it("refuses a returned hash if the storage write silently fails", () => {
    const s=storage(),intent=reserveTreasuryProposal(s,15n);s.setItem.mockImplementation(()=>{});
    expect(()=>saveTreasuryProposal(s,intent,HASH)).toThrow(/reference could not be saved/);
    expect(readTreasuryProposal(s)!.hash).toBeNull();
  });
  it("keeps both missing replies and unavailable status locked", async () => {
    const s = storage(), g = gateway(), intent = reserveTreasuryProposal(s, 15n);
    expect(await treasuryProposalState(s, g.sdk, g.client)).toMatchObject({record: intent, canClear: false, status: expect.stringMatching(/outcome unknown/)});
    expect(g.lookup).not.toHaveBeenCalled();saveTreasuryProposal(s, intent, HASH);
    g.lookup.mockRejectedValue(new Error("offline"));expect(await treasuryProposalState(s, g.sdk, g.client)).toMatchObject({canClear: false, status: expect.stringMatching(/unavailable/)});
    expect(readTreasuryProposal(s)!.hash).toBe(HASH);
  });
  it("requires no gateway call when no proposal exists", async () => {
    const s = storage(), g = gateway();expect(await treasuryProposalState(s, g.sdk, g.client)).toEqual({record: null, status: "none", canClear: false});
    expect(g.lookup).not.toHaveBeenCalled();
  });
  it.each(["gateway", "nonce"])("bounds a hanging %s lookup and retains its pending hash", async source => {
    vi.useFakeTimers();
    try {
      const s=storage(),g=gateway("FAILED",16n),intent=reserveTreasuryProposal(s,15n);saveTreasuryProposal(s,intent,HASH);
      if(source==="gateway")g.lookup.mockImplementation(()=>new Promise(()=>{}));
      else g.nonce.mockImplementation(()=>new Promise(()=>{}));
      const result=treasuryProposalState(s,g.sdk,g.client);
      await vi.advanceTimersByTimeAsync(8_000);
      expect(await result).toMatchObject({canClear:false,status:expect.stringMatching(/unavailable/),record:{hash:HASH}});
      expect(readTreasuryProposal(s)!.hash).toBe(HASH);
    } finally {vi.useRealTimers();}
  });
  it.each(["AWAITING_CONFIRMATIONS", "AWAITING_EXECUTION", "SUCCESS", "UNKNOWN"])("never clears %s", async status => {
    const s = storage(), g = gateway(status, 16n), intent = reserveTreasuryProposal(s, 15n);saveTreasuryProposal(s, intent, HASH);
    expect(await treasuryProposalState(s, g.sdk, g.client)).toMatchObject({canClear: false, status});
    expect(g.lookup).toHaveBeenCalledWith(HASH);await expect(clearResolvedTreasuryProposal(s, g.sdk, g.client)).rejects.toThrow(/not confirmed obsolete/);
    expect(readTreasuryProposal(s)!.hash).toBe(HASH);
  });
  it.each(["CANCELLED", "FAILED"])("clears %s only after its actual proposal nonce is consumed", async status => {
    const s = storage(), g = gateway(status, 17n, 16), intent = reserveTreasuryProposal(s, 15n);saveTreasuryProposal(s, intent, HASH);
    expect(await treasuryProposalState(s, g.sdk, g.client)).toMatchObject({canClear: true});
    await clearResolvedTreasuryProposal(s, g.sdk, g.client);expect(readTreasuryProposal(s)).toBeNull();
  });
  it("does not confuse the proposal nonce with the earlier snapshot nonce", async () => {
    const s = storage(), g = gateway("CANCELLED", 16n, 16), intent = reserveTreasuryProposal(s, 15n);saveTreasuryProposal(s, intent, HASH);
    expect(await treasuryProposalState(s, g.sdk, g.client)).toMatchObject({canClear: false});
    await expect(clearResolvedTreasuryProposal(s, g.sdk, g.client)).rejects.toThrow(/not confirmed obsolete/);
  });
  it("does not clear a record that changed during a gateway lookup", async () => {
    const s=storage(),g=gateway("CANCELLED",16n),intent=reserveTreasuryProposal(s,15n);saveTreasuryProposal(s,intent,HASH);
    g.lookup.mockImplementation(async()=>{s.setItem(TREASURY_PROPOSAL_KEY,JSON.stringify({...readTreasuryProposal(s),nonce:"16"}));return g.details;});
    await expect(clearResolvedTreasuryProposal(s,g.sdk,g.client)).rejects.toThrow(/saved Treasury proposal changed/);expect(s.removeItem).not.toHaveBeenCalled();
  });
  it("fails closed if an obsolete record cannot actually be removed", async () => {
    const s=storage(),g=gateway("FAILED",16n),intent=reserveTreasuryProposal(s,15n);saveTreasuryProposal(s,intent,HASH);
    s.removeItem.mockImplementation(()=>{});
    await expect(clearResolvedTreasuryProposal(s,g.sdk,g.client)).rejects.toThrow(/could not be cleared/);expect(readTreasuryProposal(s)!.hash).toBe(HASH);
  });
  it.each(["safe", "hash", "nonce", "type"])("does not trust a mismatched gateway %s", async drift => {
    const s = storage(), g = gateway("CANCELLED", 16n), intent = reserveTreasuryProposal(s, 15n);saveTreasuryProposal(s, intent, HASH);
    if (drift === "safe") g.details.safeAddress = "0x1111111111111111111111111111111111111111";
    if (drift === "hash") g.details.detailedExecutionInfo.safeTxHash = `0x${"cd".repeat(32)}`;
    if (drift === "nonce") g.details.detailedExecutionInfo.nonce = -1;
    if (drift === "type") g.details.detailedExecutionInfo.type = "MODULE";
    expect(await treasuryProposalState(s, g.sdk, g.client)).toMatchObject({canClear: false, status: expect.stringMatching(/unavailable/)});
  });
  it("pins the reviewed generator separately from main's retired 250k version", () => {
    expect(REVIEWED_TREASURY_GENERATOR).toEqual({commit: "be5d7bae0538e2841bdbd9466a2820e3203c359a", path: "contracts/script/PrepareMorphoSUSDfrTreasurySupply.s.sol",
      sha256: "b1753b188eae814d0dcc31f7016efa030f559ef1bf532baef5ba13a91617d383"});
  });
});
