import {describe, expect, it, vi} from "vitest";
import {decodeFunctionData, parseAbi, type PublicClient} from "viem";
import {MORPHO_MARKET, treasurySupplyCalls} from "./morphoMarket";
import {SAFE_MULTISEND_CALL_ONLY, simulateSafeMarketCalls} from "./morphoSafe";

const SUCCESS = `0x${"0".repeat(63)}1${"0".repeat(64)}`;
function fakeClient() {
  const methods = {getChainId: vi.fn(async () => 1), getCode: vi.fn(async () => "0x1234" as `0x${string}` | undefined),
    call: vi.fn().mockRejectedValue({cause: {cause: {data: SUCCESS}}})};
  return {methods, client: methods as unknown as PublicClient};
}
describe("actual Safe simulateAndRevert integration", () => {
  it("uses only eth_call in the connected Safe context and decodes a nested intentional revert", async () => {
    const {client, methods} = fakeClient();
    await simulateSafeMarketCalls(client, MORPHO_MARKET.treasury, treasurySupplyCalls());
    expect(methods.call).toHaveBeenCalledTimes(1);
    const request = methods.call.mock.calls[0][0];
    expect(request).toMatchObject({account: "0x0687a13c490B2573d4666fb3a7c21826a621215E", to: "0x0687a13c490B2573d4666fb3a7c21826a621215E"});
    const decoded = decodeFunctionData({abi: parseAbi(["function simulateAndRevert(address targetContract,bytes calldataPayload)"]), data: request.data});
    expect(decoded.functionName).toBe("simulateAndRevert");expect(decoded.args![0]).toBe("0x40A2aCCbd92BCA938b02010E17A5b8929b49130D");
    expect(methods.getCode).toHaveBeenCalledExactlyOnceWith({address: SAFE_MULTISEND_CALL_ONLY});
  });
  it("rejects a wrong chain before executing a call", async () => {
    const {client, methods} = fakeClient();methods.getChainId.mockResolvedValue(5);
    await expect(simulateSafeMarketCalls(client, MORPHO_MARKET.treasury, treasurySupplyCalls())).rejects.toThrow(/Ethereum mainnet/);
    expect(methods.call).not.toHaveBeenCalled();
  });
  it.each([undefined, "0x" as const])("rejects an unavailable canonical MultiSend (%s)", async code => {
    const {client, methods} = fakeClient();methods.getCode.mockResolvedValue(code);
    await expect(simulateSafeMarketCalls(client, MORPHO_MARKET.treasury, treasurySupplyCalls())).rejects.toThrow(/unavailable/);
    expect(methods.call).not.toHaveBeenCalled();
  });
  it("does not confuse a normal RPC success with intentional simulation success", async () => {
    const {client, methods} = fakeClient();methods.call.mockResolvedValue({data: SUCCESS});
    await expect(simulateSafeMarketCalls(client, MORPHO_MARKET.treasury, treasurySupplyCalls())).rejects.toThrow(/unexpected simulation result/);
  });
  it.each([{data: `0x${"0".repeat(128)}`}, {cause: {data: "0x08c379a0"}}, {message: "transport failed"}, null, {data: "not hex"}])("refuses failed or malformed simulation %j", async failure => {
    const {client, methods} = fakeClient();methods.call.mockRejectedValue(failure);
    await expect(simulateSafeMarketCalls(client, MORPHO_MARKET.treasury, treasurySupplyCalls())).rejects.toThrow(/did not simulate successfully/);
  });
});
