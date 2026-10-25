import {concatHex, encodeFunctionData, parseAbi, toHex, type Address, type Hex, type PublicClient} from "viem";
import type {MarketCall} from "./morphoMarket";

/** Canonical Safe v1.3 CALL-only MultiSend, also usable by later Safes. */
export const SAFE_MULTISEND_CALL_ONLY = "0x40A2aCCbd92BCA938b02010E17A5b8929b49130D";
const multisendAbi = parseAbi(["function multiSend(bytes transactions)"]);
const simulationAbi = parseAbi(["function simulateAndRevert(address targetContract,bytes calldataPayload)"]);

export function encodeSafeCalls(calls: readonly MarketCall[]): Hex {
  if (!calls.length || calls.some(c => c.value !== "0")) throw new Error("Only zero-ETH market calls are supported.");
  return encodeFunctionData({abi: multisendAbi, functionName: "multiSend", args: [concatHex(calls.map(c =>
    concatHex(["0x00", c.to, toHex(0n, {size: 32}), toHex(BigInt((c.data.length - 2) / 2), {size: 32}), c.data])))]});
}

function revertData(error: unknown): Hex | undefined {
  let current = error;
  for (let depth = 0; depth < 12 && current && typeof current === "object"; depth++) {
    const row = current as {data?: unknown; cause?: unknown};
    if (typeof row.data === "string" && /^0x[\da-f]+$/i.test(row.data)) return row.data as Hex;
    current = row.cause;
  }
}

/** Safe deliberately reverts with (success word, byte length, raw returndata), not ABI bytes. */
export function assertSafeSimulationResult(data: Hex | undefined) {
  if (!data || data.length < 130 || (data.length - 2) % 2 !== 0
    || BigInt(`0x${data.slice(2, 66)}`) !== 1n
    || BigInt(`0x${data.slice(66, 130)}`) !== BigInt((data.length - 130) / 2)) {
    throw new Error("The complete Safe batch did not simulate successfully. No proposal was submitted.");
  }
}

/** Executes the ordered calls only inside eth_call; simulateAndRevert rolls all state back. */
export async function simulateSafeMarketCalls(client: PublicClient, safe: Address, calls: readonly MarketCall[]) {
  if (await client.getChainId() !== 1) throw new Error("Switch to Ethereum mainnet.");
  const code = await client.getCode({address: SAFE_MULTISEND_CALL_ONLY});
  if (!code || code === "0x") throw new Error("The canonical Safe batch contract is unavailable.");
  const data = encodeFunctionData({abi: simulationAbi, functionName: "simulateAndRevert",
    args: [SAFE_MULTISEND_CALL_ONLY, encodeSafeCalls(calls)]});
  try {
    await client.call({account: safe, to: safe, data});
  } catch (error) {
    assertSafeSimulationResult(revertData(error));
    return;
  }
  throw new Error("The Safe returned an unexpected simulation result. No proposal was submitted.");
}
