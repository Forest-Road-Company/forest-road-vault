import {act, cleanup, renderHook, waitFor} from "@testing-library/react";
import {parseAbi} from "viem";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {useWriteFlow} from "@/components/app/useWriteFlow";

const OWNER = "0x1111111111111111111111111111111111111111" as const;
const ASSET_ADDRESS = "0x2222222222222222222222222222222222222222" as const;
const HASH = `0x${"ab".repeat(32)}` as `0x${string}`;
const ABI = parseAbi(["function transfer(address,uint256) returns (bool)"]);
const INPUT = {address: ASSET_ADDRESS, abi: ABI, functionName: "transfer", args: [OWNER, 1n], keepPendingUntilReceipt: true};

const harness = vi.hoisted(() => ({
  address: "0x1111111111111111111111111111111111111111" as `0x${string}` | undefined,
  request: vi.fn(),
  simulate: vi.fn(),
  estimate: vi.fn(),
  write: vi.fn(),
  wait: vi.fn(),
  invalidate: vi.fn(),
  probe: vi.fn(),
}));

vi.mock("@/config/contracts", () => ({IS_LOCAL_FORK: false}));
vi.mock("@/lib/wagmi", () => ({EXPECTED_CHAIN: {id: 11155111}}));
vi.mock("@/lib/rpcAlignment", () => ({probeRpcAlignment: harness.probe}));
vi.mock("@tanstack/react-query", () => ({useQueryClient: () => ({invalidateQueries: harness.invalidate})}));
vi.mock("wagmi/actions", () => ({getConnection: () => ({address: harness.address})}));
vi.mock("wagmi", () => ({
  useAccount: () => ({address: harness.address}),
  useConfig: () => ({}),
  usePublicClient: () => ({
    request: harness.request,
    simulateContract: harness.simulate,
    estimateContractGas: harness.estimate,
    waitForTransactionReceipt: harness.wait,
  }),
  useWalletClient: () => ({data: {transport: {request: harness.request}}}),
  useWriteContract: () => ({writeContractAsync: harness.write}),
}));

beforeEach(() => {
  harness.address = OWNER;
  for (const call of [harness.request, harness.simulate, harness.estimate, harness.write, harness.wait, harness.invalidate, harness.probe]) {
    call.mockReset();
  }
  harness.probe.mockResolvedValue({aligned: true, blockNumber: 1n, blockHash: HASH});
  harness.simulate.mockResolvedValue({request: {address: ASSET_ADDRESS, abi: ABI, functionName: "transfer", args: [OWNER, 1n]}});
  harness.estimate.mockResolvedValue(500_000n);
  harness.write.mockResolvedValue(HASH);
  harness.invalidate.mockResolvedValue(undefined);
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe("the real write-flow hook after a Buy broadcast", () => {
  it("keeps the hash and Buy lock when receipt checks reach the 30-minute limit", async () => {
    vi.useFakeTimers({toFake: ["Date"]});
    vi.setSystemTime(0);
    const onSuccess = vi.fn();
    harness.wait.mockImplementation(async () => {
      vi.setSystemTime(30 * 60_000 + 1);
      throw new Error("receipt_rpc_unavailable");
    });
    const {result} = renderHook(() => useWriteFlow());
    await act(async () => { await result.current.run({...INPUT, onSuccess}); });

    expect(harness.write).toHaveBeenCalledTimes(1);
    expect(harness.wait).toHaveBeenCalledTimes(1);
    expect(result.current.status).toEqual({phase: "pending", hash: HASH, delayed: true, stopped: true});
    expect(result.current.busy).toBe(true);
    expect(onSuccess).not.toHaveBeenCalled();
    act(() => result.current.reset());
    expect(result.current.status.phase).toBe("pending");
  });

  it("does not report a late receipt or start another poll after its card unmounts", async () => {
    let deliver!: (receipt: {status: "success"; transactionHash: `0x${string}`}) => void;
    harness.wait.mockImplementation(() => new Promise((resolve) => { deliver = resolve; }));
    const onSuccess = vi.fn();
    const {result, unmount} = renderHook(() => useWriteFlow());
    let running!: Promise<void>;
    act(() => { running = result.current.run({...INPUT, onSuccess}); });
    await waitFor(() => expect(harness.wait).toHaveBeenCalledTimes(1));
    unmount();
    await act(async () => { deliver({status: "success", transactionHash: HASH}); await running; });

    expect(harness.wait).toHaveBeenCalledTimes(1);
    expect(harness.invalidate).not.toHaveBeenCalled();
    expect(onSuccess).not.toHaveBeenCalled();
  });

  it("lets the buyer stop delayed checking without clearing the pending hash or polling again", async () => {
    let rejectReceipt!: (error: Error) => void;
    harness.wait.mockImplementation(() => new Promise((_resolve, reject) => { rejectReceipt = reject; }));
    const {result} = renderHook(() => useWriteFlow());
    let running!: Promise<void>;
    act(() => { running = result.current.run(INPUT); });
    await waitFor(() => expect(harness.wait).toHaveBeenCalledTimes(1));
    vi.useFakeTimers();
    await act(async () => { rejectReceipt(new Error("receipt_rpc_unavailable")); });
    expect(result.current.status).toEqual({phase: "pending", hash: HASH, delayed: true});

    act(() => result.current.stopWaiting());
    expect(result.current.status).toEqual({phase: "pending", hash: HASH, delayed: true, stopped: true});
    await act(async () => { await vi.advanceTimersByTimeAsync(5_000); await running; });
    expect(harness.wait).toHaveBeenCalledTimes(1);
    expect(result.current.busy, "another Buy remains locked while the original hash is unresolved").toBe(true);
  });
});
