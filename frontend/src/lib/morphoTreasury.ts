import {parseAbiItem, type Hex, type PublicClient} from "viem";
import type SafeAppsSDK from "@safe-global/safe-apps-sdk";
import {MARKET_SAFE_ABI, MORPHO_MARKET, treasurySupplyDigest} from "./morphoMarket";

const SUPPLY_EVENT = parseAbiItem("event Supply(bytes32 indexed id,address indexed caller,address indexed onBehalf,uint256 assets,uint256 shares)");
export const TREASURY_HISTORY_CHUNK = 1_000n;
export const TREASURY_PROPOSAL_KEY = `frv:morpho-seed:1:${MORPHO_MARKET.treasury.toLowerCase()}:${MORPHO_MARKET.id}`;
export const REVIEWED_TREASURY_GENERATOR = {
  commit: "be5d7bae0538e2841bdbd9466a2820e3203c359a",
  path: "contracts/script/PrepareMorphoSUSDfrTreasurySupply.s.sol",
  sha256: "b1753b188eae814d0dcc31f7016efa030f559ef1bf532baef5ba13a91617d383",
} as const;

/** Only an own, executed contribution counts. Foreign dust is deliberately ignored. */
export async function assertNoTreasurySupply(client: PublicClient, toBlock: bigint) {
  try {
    if (toBlock < MORPHO_MARKET.fromBlock) throw new Error("Missing market history");
    for (let from = MORPHO_MARKET.fromBlock; from <= toBlock; from += TREASURY_HISTORY_CHUNK) {
      const end = from + TREASURY_HISTORY_CHUNK - 1n;
      const logs = await client.getLogs({address: MORPHO_MARKET.address, event: SUPPLY_EVENT,
        args: {id: MORPHO_MARKET.id, caller: MORPHO_MARKET.treasury, onBehalf: MORPHO_MARKET.treasury},
        fromBlock: from, toBlock: end < toBlock ? end : toBlock, strict: true});
      if (logs.some(l => l.args.assets! > 0n && l.args.shares! > 0n)) {
        throw new TreasuryAlreadySuppliedError();
      }
    }
  } catch (error) {
    if (error instanceof TreasuryAlreadySuppliedError) throw error;
    throw new Error("Treasury supply history is unavailable. No proposal can be prepared; retry with verified history.");
  }
}
class TreasuryAlreadySuppliedError extends Error {
  constructor() {super("The Treasury has already supplied its seed to this market.");}
}

type ProposalStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;
export type TreasuryProposal = {version: 1; nonce: string; digest: Hex; hash: Hex | null};
const hashPattern = /^0x[0-9a-fA-F]{64}$/;
async function proposalRead<T>(request: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([request, new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error("Treasury proposal status timed out.")), 8_000);
    })]);
  } finally {clearTimeout(timer);}
}

export function readTreasuryProposal(storage: ProposalStorage): TreasuryProposal | null {
  const raw = storage.getItem(TREASURY_PROPOSAL_KEY);
  if (raw === null) return null;
  const record = JSON.parse(raw) as TreasuryProposal;
  if (!record || record.version !== 1 || typeof record.nonce !== "string" || !/^(0|[1-9]\d*)$/.test(record.nonce)
    || record.digest !== treasurySupplyDigest() || (record.hash !== null && (typeof record.hash !== "string" || !hashPattern.test(record.hash)))) {
    throw new Error("The saved Treasury proposal record could not be verified. Reconcile the Safe queue before continuing.");
  }
  return record;
}

/** Persist an intent BEFORE asking Safe; a lost reply must not enable a duplicate after reload. */
export function reserveTreasuryProposal(storage: ProposalStorage, nonce: bigint) {
  if (readTreasuryProposal(storage)) throw new Error("A Treasury seed proposal is already recorded. Reconcile the Safe queue before continuing.");
  if (nonce < 0n) throw new Error("Invalid Treasury nonce.");
  const record: TreasuryProposal = {version: 1, nonce: String(nonce), digest: treasurySupplyDigest(), hash: null};
  const raw = JSON.stringify(record);
  storage.setItem(TREASURY_PROPOSAL_KEY, raw);
  if (storage.getItem(TREASURY_PROPOSAL_KEY) !== raw) throw new Error("The Treasury proposal record could not be saved.");
  return record;
}

export function saveTreasuryProposal(storage: ProposalStorage, intent: TreasuryProposal, hash: string) {
  const record = readTreasuryProposal(storage);
  if (!record || record.hash || record.nonce !== intent.nonce || !hashPattern.test(hash)) {
    throw new Error("The Treasury proposal outcome is uncertain. Reconcile the Safe queue; do not create another proposal.");
  }
  const saved = {...record, hash: hash as Hex};
  const raw = JSON.stringify(saved);
  storage.setItem(TREASURY_PROPOSAL_KEY, raw);
  if (storage.getItem(TREASURY_PROPOSAL_KEY) !== raw) throw new Error("The Treasury proposal reference could not be saved. Check the Safe queue.");
  return saved;
}

/** Storage is only a same-browser aid. The signers must reconcile the complete Safe queue. */
export async function treasuryProposalState(storage: ProposalStorage, sdk: SafeAppsSDK, client: PublicClient) {
  const record = readTreasuryProposal(storage);
  if (!record) return {record, status: "none", canClear: false};
  if (!record.hash) return {record, status: "outcome unknown — reconcile the Safe queue", canClear: false};
  try {
    const details = await proposalRead(sdk.txs.getBySafeTxHash(record.hash));
    const execution = details.detailedExecutionInfo;
    if (details.safeAddress.toLowerCase() !== MORPHO_MARKET.treasury.toLowerCase() || !execution
      || execution.type !== "MULTISIG" || execution.safeTxHash.toLowerCase() !== record.hash.toLowerCase()
      || !Number.isSafeInteger(execution.nonce) || execution.nonce < 0) throw new Error("Unverified Safe proposal");
    // A cancelled/failed transaction is only safely obsolete once its nonce was consumed.
    const terminal = details.txStatus === "CANCELLED" || details.txStatus === "FAILED";
    const nonce = terminal ? await proposalRead(client.readContract({address: MORPHO_MARKET.treasury, abi: MARKET_SAFE_ABI, functionName: "nonce"})) : null;
    return {record, status: details.txStatus, canClear: terminal && nonce !== null && nonce > BigInt(execution.nonce)};
  } catch {
    return {record, status: "status unavailable — check the Safe queue", canClear: false};
  }
}

/** Recheck status live; never discard a pending or uncertain proposal on a stale UI result. */
export async function clearResolvedTreasuryProposal(storage: ProposalStorage, sdk: SafeAppsSDK, client: PublicClient) {
  const state = await treasuryProposalState(storage, sdk, client);
  if (!state.record || !state.canClear) throw new Error("The Treasury proposal is not confirmed obsolete. Check the Safe queue.");
  if (JSON.stringify(readTreasuryProposal(storage)) !== JSON.stringify(state.record)) throw new Error("The saved Treasury proposal changed. Refresh before continuing.");
  storage.removeItem(TREASURY_PROPOSAL_KEY);
  if (storage.getItem(TREASURY_PROPOSAL_KEY) !== null) throw new Error("The obsolete Treasury proposal record could not be cleared.");
}
