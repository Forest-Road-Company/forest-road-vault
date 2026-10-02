import {
  createPublicClient,
  decodeEventLog,
  encodeEventTopics,
  getAddress,
  http,
  isAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import {CONTRACTS, IS_MAINNET, PROTOCOL_DEPLOYMENT_BLOCK} from "@/config/contracts";
import {ERC20_ABI, ORACLE_WIRING_ABI, OWNER_STATUS_ABI, POINTS_ABI, POINTS_HISTORY_ABI, VAULT_POINTS_ABI} from "@/lib/abi";
import {EXPECTED_CHAIN} from "@/lib/chain";
import {
  MorphoPointsIntegrityError,
  replayCollateralPoints,
  type CollateralEvent,
  type OwnerPoints,
  type RateEpoch,
} from "@/lib/morphoPoints";
import {archiveRpcUrl} from "@/lib/transparencyHistory.server";

export {MorphoPointsIntegrityError};

/** A state that is expected to clear on its own (catching up, market not yet final). Safe to log. */
export class MorphoPointsNotReadyError extends Error {
  override name = "MorphoPointsNotReadyError";
}

/** Morpho Blue on Ethereum mainnet. */
export const MORPHO_BLUE: Address = "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb";
/** The only market parameters this credit applies to, beside the two tokens and the oracle. */
export const ADAPTIVE_CURVE_IRM: Address = "0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC";
export const MARKET_LLTV = 860_000_000_000_000_000n;
/**
 * The PointsModule implementation this mirror was verified against (`impl_points` in
 * contracts/deployments/1-production-v2.json). An upgrade can change the formula, so the loader
 * refuses to answer until the mirror has been re-verified against the new implementation.
 */
export const POINTS_MODULE_IMPLEMENTATION: Address = "0x63AA0ae03DDc7f938B7C5a22878bd02898c7E801";
const IMPLEMENTATION_SLOT: Hex = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const ONE_SHARE = 10n ** 24n;
export const BLOCK_CHUNK = 9_000n;
export const MAX_CHUNKS_PER_REQUEST = 400;
const HEADER_CONCURRENCY = 8;
const RECONCILE_BATCH = 200;
/** Batches of one reconcile in flight at once, so a large book does not wait on each in turn. */
const RECONCILE_CONCURRENCY = 4;
/**
 * Calldata one multicall may carry. viem splits at 1,024 bytes by default, which turns one
 * 200-owner batch (68 bytes a position read) into 14 archive calls; this keeps it to one.
 */
const RECONCILE_CALLDATA_BYTES = 16_384;
/**
 * How long one request may spend extending the history before it stops with "not ready",
 * keeping every chunk it committed, so a large cold build converges across requests instead of
 * running past the function's limit. It runs from the request's arrival (MORPHO-71) and is checked
 * only between chunks, and a build always runs the first chunk of each scan so every request makes
 * progress (MORPHO-10). So a request can take this long, plus what the build it waited behind ran
 * past its own deadline (at most one chunk of each scan, rate epochs and collateral), plus its own
 * first chunk of each scan, plus a few single reads (the wiring checks, the epoch count and the
 * wallet's own); each further build queued ahead of it, one per newer finalized head, adds its
 * first chunks (Corrovera M1001-m4-07). A collateral chunk reads one position for each owner it
 * touched or holds non-zero, and for a sixteenth of the owners held at zero
 * (`ZERO_HELD_GRID_CHUNKS`). A build that scans no chunk up to its head (a finalized head at or
 * below what a stopped build committed) reads every known owner's position at that head instead.
 */
export const REQUEST_BUDGET_MS = 20_000;
/**
 * Every known owner the replay holds at zero is reconciled once every this many chunks. Chunk n,
 * counted from 1, ends at the market's first block plus n * `BLOCK_CHUNK` - 1, and an owner is
 * checked at the end of each chunk n congruent to its index modulo this (its place, from 0, in the
 * order the history first saw it): the first owner at every 16th chunk's end, the second at the end
 * of chunks 1, 17, 33 and so on. An omitted supply and withdrawal of a known owner held at zero is
 * caught when one of its check blocks falls between them, which one always does when they are 16
 * chunks (144,000 blocks, about 20 days) or more apart; a shorter one can under-count the owner and
 * never over-counts (Corrovera MORPHO-55; the residual sits with MORPHO-12's). Spread this way,
 * each chunk reads a sixteenth of the owners held at zero, where every 16th chunk used to read
 * every owner ever seen (M1001-m4-07).
 */
export const ZERO_HELD_GRID_CHUNKS = 16n;
const REBUILD_BACKOFF_MS = 60_000;
/**
 * An `eth_getLogs` answer this long may have been cut short by a provider's result cap, so its
 * range is split and read again. Far above what one 9,000-block range of this market holds.
 */
export const LOG_RESULT_LIMIT = 1_000;

/** Morpho Blue's collateral events and the two views the loader checks against. */
export const MORPHO_COLLATERAL_ABI = [
  {
    type: "event",
    name: "SupplyCollateral",
    anonymous: false,
    inputs: [
      {name: "id", type: "bytes32", indexed: true},
      {name: "caller", type: "address", indexed: true},
      {name: "onBehalf", type: "address", indexed: true},
      {name: "assets", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "WithdrawCollateral",
    anonymous: false,
    inputs: [
      {name: "id", type: "bytes32", indexed: true},
      {name: "caller", type: "address", indexed: false},
      {name: "onBehalf", type: "address", indexed: true},
      {name: "receiver", type: "address", indexed: true},
      {name: "assets", type: "uint256", indexed: false},
    ],
  },
  {
    type: "event",
    name: "Liquidate",
    anonymous: false,
    inputs: [
      {name: "id", type: "bytes32", indexed: true},
      {name: "caller", type: "address", indexed: true},
      {name: "borrower", type: "address", indexed: true},
      {name: "repaidAssets", type: "uint256", indexed: false},
      {name: "repaidShares", type: "uint256", indexed: false},
      {name: "seizedAssets", type: "uint256", indexed: false},
      {name: "badDebtAssets", type: "uint256", indexed: false},
      {name: "badDebtShares", type: "uint256", indexed: false},
    ],
  },
  {
    type: "function",
    name: "idToMarketParams",
    stateMutability: "view",
    inputs: [{name: "id", type: "bytes32"}],
    outputs: [
      {name: "loanToken", type: "address"},
      {name: "collateralToken", type: "address"},
      {name: "oracle", type: "address"},
      {name: "irm", type: "address"},
      {name: "lltv", type: "uint256"},
    ],
  },
  {
    type: "function",
    name: "position",
    stateMutability: "view",
    inputs: [
      {name: "id", type: "bytes32"},
      {name: "user", type: "address"},
    ],
    outputs: [
      {name: "supplyShares", type: "uint256"},
      {name: "borrowShares", type: "uint128"},
      {name: "collateral", type: "uint128"},
    ],
  },
] as const;

/** topic0 of each collateral event, verified against Morpho Blue mainnet logs on 28 Sep 2026. */
export const MORPHO_COLLATERAL_TOPICS = {
  SupplyCollateral: "0xa3b9472a1399e17e123f3c2e6586c23e504184d504de59cdaa2b375e880c6184",
  WithdrawCollateral: "0xe80ebd7cc9223d7382aab2e0d1d6155c65651f83d53c8b9b06901d167e321142",
  Liquidate: "0xa4946ede45d0c6f06a0f5ce92c9ad3b4751452d2fe0e25010783bcab57a67e41",
} as const;
export const RATE_EPOCH_TOPIC = encodeEventTopics({abi: POINTS_HISTORY_ABI, eventName: "RateEpochAppended"})[0];

export type MorphoPointsConfig = {marketId: Hex; fromBlock: bigint; oracle: Address};

/**
 * The market to credit, from server-only configuration: its id, its `createMarket` block and the
 * SUSDfrExitValueOracle it was created with. All three are required together and only on
 * mainnet; with none set the feature is off. Set them once the creation block is finalized,
 * about fifteen minutes after `createMarket`.
 */
export function morphoPointsConfig(
  env: Record<string, string | undefined> = process.env,
  mainnet = IS_MAINNET,
): MorphoPointsConfig | null {
  if (!mainnet) return null;
  const id = env.MORPHO_SUSDFR_MARKET_ID?.trim();
  const from = env.MORPHO_SUSDFR_MARKET_FROM_BLOCK?.trim();
  const oracle = env.MORPHO_SUSDFR_ORACLE?.trim();
  if (!id && !from && !oracle) return null;
  if (!id || !from || !oracle) {
    throw new MorphoPointsIntegrityError(
      "MORPHO_SUSDFR_MARKET_ID, MORPHO_SUSDFR_MARKET_FROM_BLOCK and MORPHO_SUSDFR_ORACLE must be set together",
    );
  }
  if (!/^0x[0-9a-fA-F]{64}$/.test(id)) {
    throw new MorphoPointsIntegrityError("MORPHO_SUSDFR_MARKET_ID is not a bytes32 market id");
  }
  if (!/^[1-9][0-9]*$/.test(from)) {
    throw new MorphoPointsIntegrityError("MORPHO_SUSDFR_MARKET_FROM_BLOCK is not a block number");
  }
  if (!isAddress(oracle, {strict: true})) {
    throw new MorphoPointsIntegrityError("MORPHO_SUSDFR_ORACLE is not an address");
  }
  return {marketId: id.toLowerCase() as Hex, fromBlock: BigInt(from), oracle: getAddress(oracle)};
}

/** A raw `eth_getLogs` entry. */
export type RawLog = {
  address: Address;
  topics: Hex[];
  data: Hex;
  blockNumber: Hex;
  blockHash: Hex;
  logIndex: Hex;
  transactionHash: Hex;
  removed?: boolean;
};

/** Decodes one raw Morpho log into a collateral change, or throws on anything unexpected. */
export function decodeCollateralLog(
  log: {topics: readonly Hex[]; data: Hex; blockNumber: bigint | null; logIndex: number | null},
  marketId: Hex,
  timestamp: bigint,
): CollateralEvent {
  if (log.blockNumber === null || log.logIndex === null) {
    throw new MorphoPointsIntegrityError("points: pending log in history");
  }
  const decoded = decodeEventLog({
    abi: MORPHO_COLLATERAL_ABI,
    topics: log.topics as [Hex, ...Hex[]],
    data: log.data,
    strict: true,
  });
  if (decoded.args.id.toLowerCase() !== marketId.toLowerCase()) {
    throw new MorphoPointsIntegrityError("points: log from another market");
  }
  const base = {blockNumber: log.blockNumber, logIndex: log.logIndex, timestamp};
  switch (decoded.eventName) {
    case "SupplyCollateral":
      return {...base, kind: "supply", owner: decoded.args.onBehalf, assets: decoded.args.assets};
    case "WithdrawCollateral":
      return {...base, kind: "withdraw", owner: decoded.args.onBehalf, assets: decoded.args.assets};
    case "Liquidate":
      return {...base, kind: "liquidate", owner: decoded.args.borrower, assets: decoded.args.seizedAssets};
  }
}

/** Everything the loader reads through; injectable so tests can drive it without a network. */
export type MorphoPointsDeps = {
  client: PublicClient;
  config: MorphoPointsConfig;
  contracts: {usdc: Address; susdfr: Address; controller: Address; points: Address; compliance: Address};
  protocolDeploymentBlock: bigint;
  now: () => number;
};

/**
 * One finalized answer. It carries everything the per-wallet step reads after its own awaits, so
 * a concurrent integrity drop of the module-level history cannot change what it serves.
 */
type Snapshot = {
  asOfBlock: bigint;
  asOfTimestamp: bigint;
  owners: Map<string, OwnerPoints>;
  rateEpochs: number;
  history: History;
};
type History = {
  key: string;
  verified: boolean;
  events: CollateralEvent[];
  scannedTo: bigint;
  epochs: RateEpoch[];
  epochsScannedTo: bigint;
  /** The block at which `epochs` last matched `rateEpochCount`. Only a verified history is replayed. */
  epochsVerifiedTo: bigint;
  owners: Set<string>;
  /** Each owner's collateral after the last committed chunk, checked against Morpho Blue there. */
  balances: Map<string, bigint>;
  snapshot: Snapshot | null;
};

let history: History | null = null;
let rebuildAfter = 0;
let queue: Promise<unknown> = Promise.resolve();
let inflight: {target: bigint; promise: Promise<Snapshot>} | null = null;

/** Clears the per-instance cache. Tests only. */
export function resetMorphoPointsCache(): void {
  history = null;
  rebuildAfter = 0;
  queue = Promise.resolve();
  inflight = null;
}

/** Drops `h` after an integrity failure, unless a newer history has already replaced it. */
function dropHistory(deps: MorphoPointsDeps, h: History): void {
  if (history !== h) return;
  history = null;
  rebuildAfter = deps.now() + REBUILD_BACKOFF_MS;
}

function historyFor(deps: MorphoPointsDeps): History {
  const key = `${deps.config.marketId}:${deps.config.fromBlock}:${deps.config.oracle.toLowerCase()}`;
  if (history && history.key === key) return history;
  if (deps.now() < rebuildAfter) {
    throw new MorphoPointsNotReadyError("points: rebuilding history after an integrity failure");
  }
  history = {
    key,
    verified: false,
    events: [],
    scannedTo: 0n,
    epochs: [],
    epochsScannedTo: 0n,
    epochsVerifiedTo: 0n,
    owners: new Set(),
    balances: new Map(),
    snapshot: null,
  };
  return history;
}

function hex(n: bigint): Hex {
  return `0x${n.toString(16)}`;
}

/**
 * `eth_getLogs` over one range, refusing anything outside the filter. An answer of
 * LOG_RESULT_LIMIT entries or more is treated as possibly truncated: the range is halved and
 * each half read again, down to a single block, which then fails closed.
 */
async function getLogs(
  deps: MorphoPointsDeps,
  address: Address,
  topics: (Hex | Hex[] | null)[],
  from: bigint,
  to: bigint,
): Promise<RawLog[]> {
  const logs = (await deps.client.request({
    method: "eth_getLogs",
    params: [{address, topics, fromBlock: hex(from), toBlock: hex(to)}],
  } as never)) as RawLog[];
  for (const log of logs) {
    const n = BigInt(log.blockNumber);
    if (log.removed || n < from || n > to || log.address.toLowerCase() !== address.toLowerCase()) {
      throw new MorphoPointsIntegrityError("points: the RPC returned a log outside the requested filter");
    }
  }
  if (logs.length < LOG_RESULT_LIMIT) return logs;
  if (from === to) {
    throw new MorphoPointsIntegrityError("points: one block returned too many logs to prove the answer complete");
  }
  const middle = from + (to - from) / 2n;
  const first = await getLogs(deps, address, topics, from, middle);
  const second = await getLogs(deps, address, topics, middle + 1n, to);
  return [...first, ...second];
}

async function headers(
  deps: MorphoPointsDeps,
  numbers: bigint[],
): Promise<Map<bigint, {hash: Hex; timestamp: bigint}>> {
  const out = new Map<bigint, {hash: Hex; timestamp: bigint}>();
  const unique = [...new Set(numbers)];
  for (let i = 0; i < unique.length; i += HEADER_CONCURRENCY) {
    const slice = unique.slice(i, i + HEADER_CONCURRENCY);
    const blocks = await Promise.all(slice.map((blockNumber) => deps.client.getBlock({blockNumber})));
    blocks.forEach((block, j) => {
      if (block.hash === null) throw new MorphoPointsIntegrityError("points: a pending block in history");
      out.set(slice[j], {hash: block.hash, timestamp: block.timestamp});
    });
  }
  return out;
}

function headerFor(map: Map<bigint, {hash: Hex; timestamp: bigint}>, log: RawLog): bigint {
  const header = map.get(BigInt(log.blockNumber));
  if (!header || header.hash.toLowerCase() !== log.blockHash.toLowerCase()) {
    throw new MorphoPointsIntegrityError("points: a log's block is not the canonical block the RPC reports");
  }
  return header.timestamp;
}

async function verifyMarket(deps: MorphoPointsDeps, block: bigint): Promise<void> {
  const {client, config, contracts} = deps;
  if ((await client.getChainId()) !== EXPECTED_CHAIN.id) {
    throw new MorphoPointsIntegrityError("points: the archive RPC serves another chain");
  }
  const params = await client.readContract({
    address: MORPHO_BLUE,
    abi: MORPHO_COLLATERAL_ABI,
    functionName: "idToMarketParams",
    args: [config.marketId],
    blockNumber: block,
  });
  const [loanToken, collateralToken, oracle, irm, lltv] = params;
  if (
    loanToken.toLowerCase() !== contracts.usdc.toLowerCase() ||
    collateralToken.toLowerCase() !== contracts.susdfr.toLowerCase() ||
    irm.toLowerCase() !== ADAPTIVE_CURVE_IRM.toLowerCase() ||
    lltv !== MARKET_LLTV
  ) {
    throw new MorphoPointsIntegrityError("points: the configured market is not Forest Road's USDC/sUSDfr market");
  }
  // createMarket is permissionless, so a look-alike market can carry another oracle that answers
  // the four wiring views below. Only the deployed oracle, pinned by address, qualifies.
  if (oracle.toLowerCase() !== config.oracle.toLowerCase()) {
    throw new MorphoPointsIntegrityError("points: the market's oracle is not the pinned MORPHO_SUSDFR_ORACLE");
  }
  const wiring = await Promise.all(
    (["vault", "controller", "loanToken", "ONE_SHARE"] as const).map((functionName) =>
      client.readContract({address: oracle, abi: ORACLE_WIRING_ABI, functionName, blockNumber: block}),
    ),
  );
  const [vault, controller, oracleLoanToken, oneShare] = wiring as [Address, Address, Address, bigint];
  if (
    vault.toLowerCase() !== contracts.susdfr.toLowerCase() ||
    controller.toLowerCase() !== contracts.controller.toLowerCase() ||
    oracleLoanToken.toLowerCase() !== contracts.usdc.toLowerCase() ||
    oneShare !== ONE_SHARE
  ) {
    throw new MorphoPointsIntegrityError("points: the market's oracle is not Forest Road's exit-value oracle");
  }
  const [before, at] = await Promise.all(
    [config.fromBlock - 1n, config.fromBlock].map((blockNumber) =>
      client.readContract({
        address: MORPHO_BLUE,
        abi: MORPHO_COLLATERAL_ABI,
        functionName: "idToMarketParams",
        args: [config.marketId],
        blockNumber,
      }),
    ),
  );
  if (BigInt(before[0]) !== 0n || at[0].toLowerCase() !== contracts.usdc.toLowerCase()) {
    throw new MorphoPointsIntegrityError("points: MORPHO_SUSDFR_MARKET_FROM_BLOCK is not the market's creation block");
  }
}

async function checkLedgerWiring(deps: MorphoPointsDeps, block: bigint): Promise<void> {
  const {client, contracts} = deps;
  const [slot, hook] = await Promise.all([
    client.getStorageAt({address: contracts.points, slot: IMPLEMENTATION_SLOT, blockNumber: block}),
    client.readContract({
      address: contracts.susdfr,
      abi: VAULT_POINTS_ABI,
      functionName: "pointsModule",
      blockNumber: block,
    }),
  ]);
  const implementation = slot ? `0x${slot.slice(-40)}` : "";
  if (implementation.toLowerCase() !== POINTS_MODULE_IMPLEMENTATION.toLowerCase()) {
    throw new MorphoPointsIntegrityError("points: the PointsModule implementation changed; re-verify the mirror");
  }
  if ((hook as Address).toLowerCase() !== contracts.points.toLowerCase()) {
    throw new MorphoPointsIntegrityError("points: sUSDfr no longer reports this PointsModule");
  }
}

/**
 * Extends the rate-epoch history to `toBlock`, committing each finalized chunk as it is read, so
 * a cold instance far past the deployment block converges over successive requests instead of
 * rescanning the same capped range forever (MORPHO-10).
 *
 * Committing is not trusting (MORPHO-32). The replay runs only on a history whose epoch count
 * matched `rateEpochCount` at the boundary it was scanned to, and that check runs whenever the
 * verified boundary trails the scanned one, including when this call scans nothing new. Without
 * it, a count read that failed after the last chunk, or a finalized head at or below what an
 * earlier capped request committed, would replay a history nobody counted, and a missing epoch
 * log would over-award every owner.
 */
async function extendEpochs(deps: MorphoPointsDeps, h: History, toBlock: bigint, deadline: number): Promise<void> {
  let from = h.epochsScannedTo === 0n ? deps.protocolDeploymentBlock : h.epochsScannedTo + 1n;
  for (let chunks = 0; from <= toBlock; ++chunks) {
    if (chunks >= MAX_CHUNKS_PER_REQUEST || (chunks > 0 && deps.now() > deadline)) {
      throw new MorphoPointsNotReadyError("points: catching up on rate history");
    }
    const to = from + BLOCK_CHUNK - 1n < toBlock ? from + BLOCK_CHUNK - 1n : toBlock;
    const logs = await getLogs(deps, deps.contracts.points, [RATE_EPOCH_TOPIC], from, to);
    const map = await headers(
      deps,
      logs.map((log) => BigInt(log.blockNumber)),
    );
    const added: RateEpoch[] = [];
    for (const log of logs) {
      const decoded = decodeEventLog({
        abi: POINTS_HISTORY_ABI,
        topics: log.topics as [Hex, ...Hex[]],
        data: log.data,
        strict: true,
      });
      if (decoded.args.index !== BigInt(h.epochs.length + added.length)) {
        throw new MorphoPointsIntegrityError("points: rate epochs are not contiguous");
      }
      added.push({start: headerFor(map, log), ratePerUnitDay: decoded.args.ratePerUnitDay});
    }
    for (const epoch of added) h.epochs.push(epoch);
    h.epochsScannedTo = to;
    from = to + 1n;
  }
  if (h.epochsVerifiedTo < h.epochsScannedTo) {
    const count = await deps.client.readContract({
      address: deps.contracts.points,
      abi: POINTS_ABI,
      functionName: "rateEpochCount",
      blockNumber: h.epochsScannedTo,
    });
    if (count !== BigInt(h.epochs.length)) {
      throw new MorphoPointsIntegrityError("points: rate epoch history does not match rateEpochCount");
    }
    h.epochsVerifiedTo = h.epochsScannedTo;
  }
}

/**
 * Extends the market's collateral history to `toBlock`, one chunk at a time. Before a chunk is
 * committed, the owners it could over-award are checked against Morpho Blue's `position()` at the
 * chunk's last block, so an omitted log changes a balance somewhere and fails closed, even when a
 * later omitted log nets it back to the same end balance. An omitted pair that nets to zero
 * inside one chunk (for example a withdrawal and an equal re-supply less than 9,000 blocks apart)
 * is not caught: that residual is accepted.
 *
 * Returns the block the last committed chunk was reconciled at, or null if it scanned nothing.
 */
async function extendCollateral(
  deps: MorphoPointsDeps,
  h: History,
  toBlock: bigint,
  deadline: number,
): Promise<bigint | null> {
  const {config} = deps;
  const collateralTopics = [
    MORPHO_COLLATERAL_TOPICS.SupplyCollateral,
    MORPHO_COLLATERAL_TOPICS.WithdrawCollateral,
    MORPHO_COLLATERAL_TOPICS.Liquidate,
  ] as Hex[];
  let from = h.scannedTo === 0n ? config.fromBlock : h.scannedTo + 1n;
  let reconciledAt: bigint | null = null;
  for (let chunks = 0; from <= toBlock; ++chunks) {
    if (chunks >= MAX_CHUNKS_PER_REQUEST || (chunks > 0 && deps.now() > deadline)) {
      throw new MorphoPointsNotReadyError("points: catching up on market history");
    }
    // Chunk n ends at the market's first block plus n * BLOCK_CHUNK - 1, whatever block this request
    // resumed from: a history extended from a head mid-chunk finishes that chunk first, so every
    // instance checks the owners held at zero at the same blocks as a cold build (Corrovera
    // M1001-m4-06).
    const chunk = (from - config.fromBlock) / BLOCK_CHUNK + 1n;
    const end = config.fromBlock + chunk * BLOCK_CHUNK - 1n;
    const to = end < toBlock ? end : toBlock;
    const logs = await getLogs(deps, MORPHO_BLUE, [collateralTopics, config.marketId], from, to);
    const map = await headers(
      deps,
      logs.map((log) => BigInt(log.blockNumber)),
    );
    const decoded = logs.map((log) =>
      decodeCollateralLog(
        {
          topics: log.topics,
          data: log.data,
          blockNumber: BigInt(log.blockNumber),
          logIndex: Number(BigInt(log.logIndex)),
        },
        config.marketId,
        headerFor(map, log),
      ),
    );
    decoded.sort((a, b) =>
      a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1,
    );
    const last = h.events.at(-1);
    const first = decoded[0];
    if (
      last &&
      first &&
      (first.blockNumber < last.blockNumber || (first.blockNumber === last.blockNumber && first.logIndex <= last.logIndex))
    ) {
      throw new MorphoPointsIntegrityError("points: collateral history overlaps what is already committed");
    }
    const balances = new Map(h.balances);
    const owners = new Set(h.owners);
    const touched = new Set<string>();
    for (const event of decoded) {
      const owner = event.owner.toLowerCase();
      const before = balances.get(owner) ?? 0n;
      const after = event.kind === "supply" ? before + event.assets : before - event.assets;
      if (after < 0n) {
        throw new MorphoPointsIntegrityError("points: collateral removed that the replay never saw supplied");
      }
      balances.set(owner, after);
      owners.add(owner);
      touched.add(owner);
    }
    // Points accrue only on collateral the replay credits, so an omitted log can over-award an
    // owner only by leaving a replayed balance Morpho Blue does not hold, which is non-zero at
    // this boundary or a later one: checking every non-zero balance, plus every owner this chunk
    // touched, keeps the over-award check whole (MORPHO-31). An owner the replay holds at zero
    // can only be under-counted, and its own request still reads its position before any answer;
    // each is also checked once every 16 chunks, a sixteenth of them at each chunk's end, so an
    // omitted round trip spanning one of its check blocks fails closed instead of under-counting
    // (MORPHO-55, M1001-m4-07).
    const every = Number(ZERO_HELD_GRID_CHUNKS);
    const phase = Number(chunk % ZERO_HELD_GRID_CHUNKS);
    const due = [...owners].filter(
      (owner, i) => touched.has(owner) || (balances.get(owner) ?? 0n) !== 0n || i % every === phase,
    );
    await reconcileAt(deps, due, (owner) => balances.get(owner) ?? 0n, to);
    for (const event of decoded) h.events.push(event);
    h.owners = owners;
    h.balances = balances;
    h.scannedTo = to;
    reconciledAt = to;
    from = to + 1n;
  }
  return reconciledAt;
}

/** Checks each owner's collateral in Morpho Blue at `block` against what the history expects. */
async function reconcileAt(
  deps: MorphoPointsDeps,
  owners: readonly string[],
  expected: (owner: string) => bigint,
  block: bigint,
): Promise<void> {
  const batches: string[][] = [];
  for (let i = 0; i < owners.length; i += RECONCILE_BATCH) batches.push(owners.slice(i, i + RECONCILE_BATCH));
  for (let i = 0; i < batches.length; i += RECONCILE_CONCURRENCY) {
    await Promise.all(
      batches.slice(i, i + RECONCILE_CONCURRENCY).map(async (batch) => {
        const positions = (await deps.client.multicall({
          contracts: batch.map((owner) => ({
            address: MORPHO_BLUE,
            abi: MORPHO_COLLATERAL_ABI,
            functionName: "position" as const,
            args: [deps.config.marketId, owner as Address] as const,
          })),
          blockNumber: block,
          allowFailure: false,
          batchSize: RECONCILE_CALLDATA_BYTES,
        })) as (readonly [bigint, bigint, bigint])[];
        positions.forEach((position, j) => {
          if (position[2] !== expected(batch[j])) {
            throw new MorphoPointsIntegrityError("points: replayed collateral disagrees with Morpho Blue");
          }
        });
      }),
    );
  }
}

async function buildSnapshot(
  deps: MorphoPointsDeps,
  asOf: {number: bigint; timestamp: bigint},
  deadline: number,
): Promise<Snapshot> {
  const h = historyFor(deps);
  if (h.snapshot && h.snapshot.asOfBlock >= asOf.number) return h.snapshot;
  try {
    if (!h.verified) {
      await verifyMarket(deps, asOf.number);
      h.verified = true;
    }
    await checkLedgerWiring(deps, asOf.number);
    await extendEpochs(deps, h, asOf.number, deadline);
    const reconciledAt = await extendCollateral(deps, h, asOf.number, deadline);
    const owners = replayCollateralPoints(h.events, h.epochs, asOf.timestamp);
    // The last chunk was just reconciled at this very block (MORPHO-31); only a build that
    // scanned no chunk up to it needs the check here.
    if (reconciledAt !== asOf.number) {
      await reconcileAt(deps, [...h.owners], (owner) => owners.get(owner)?.collateral ?? 0n, asOf.number);
    }
    h.snapshot = {
      asOfBlock: asOf.number,
      asOfTimestamp: asOf.timestamp,
      owners,
      rateEpochs: h.epochs.length,
      history: h,
    };
    return h.snapshot;
  } catch (error) {
    if (error instanceof MorphoPointsIntegrityError) dropHistory(deps, h);
    throw error;
  }
}

/**
 * One cache extension at a time; concurrent requests for the same or an older block share it. A
 * build queued behind another keeps its own request's deadline, so once that has passed it does the
 * first chunk of each scan and then stops (Corrovera MORPHO-71, M1001-m4-07).
 */
function snapshotAt(
  deps: MorphoPointsDeps,
  asOf: {number: bigint; timestamp: bigint},
  deadline: number,
): Promise<Snapshot> {
  const current = history?.snapshot;
  if (current && current.asOfBlock >= asOf.number) return Promise.resolve(current);
  if (inflight && inflight.target >= asOf.number) return inflight.promise;
  const run = () => buildSnapshot(deps, asOf, deadline);
  const promise = queue.then(run, run);
  queue = promise.catch(() => undefined);
  const entry = {target: asOf.number, promise};
  inflight = entry;
  void promise
    .catch(() => undefined)
    .finally(() => {
      if (inflight === entry) inflight = null;
    });
  return promise;
}

function defaultDeps(): MorphoPointsDeps | null {
  const config = morphoPointsConfig();
  if (!config) return null;
  const {USDC, sUSDfr, MintRedeemController, PointsModule, ComplianceRegistry} = CONTRACTS;
  if (!USDC || !sUSDfr || !MintRedeemController || !PointsModule || !ComplianceRegistry) {
    throw new MorphoPointsIntegrityError("points: protocol addresses are not configured");
  }
  const client = createPublicClient({
    chain: EXPECTED_CHAIN,
    transport: http(archiveRpcUrl(), {timeout: 15_000, retryCount: 2, batch: true}),
  }) as PublicClient;
  return {
    client,
    config,
    contracts: {
      usdc: USDC,
      susdfr: sUSDfr,
      controller: MintRedeemController,
      points: PointsModule,
      compliance: ComplianceRegistry,
    },
    protocolDeploymentBlock: PROTOCOL_DEPLOYMENT_BLOCK,
    now: () => Date.now(),
  };
}

type MorphoPointsAnswer = {
  ok: true;
  enabled: true;
  marketId: Hex;
  asOfBlock: string;
  asOfTimestamp: string;
  wallet: Address;
  collateral: string;
  rateEpochs: number;
};

export type MorphoPointsWire =
  | {ok: true; enabled: false}
  | (MorphoPointsAnswer & {points: string; excluded?: "protocol-exempt" | "jurisdiction-blocked"})
  | (MorphoPointsAnswer & {reconcileRequired: true; trackedShares: string; walletShares: string});

/**
 * One wallet's sUSDfr collateral in the Forest Road Morpho market and the points it has earned,
 * replayed from the market's finalized events and reconciled with Morpho Blue at the same block.
 * `arrivedAt` is when the request arrived (ms): apart from the first of each scan, no chunk of
 * history starts later than `REQUEST_BUDGET_MS` after then, however long it waited for another
 * build (Corrovera MORPHO-71). `REQUEST_BUDGET_MS` states the whole request's bound (M1001-m4-07).
 */
export async function loadMorphoCollateralPoints(
  wallet: Address,
  injected?: MorphoPointsDeps,
  arrivedAt?: number,
): Promise<MorphoPointsWire> {
  const deps = injected ?? defaultDeps();
  if (!deps) return {ok: true, enabled: false};
  const deadline = (arrivedAt ?? deps.now()) + REQUEST_BUDGET_MS;
  const finalized = await deps.client.getBlock({blockTag: "finalized"});
  if (finalized.number === null) throw new MorphoPointsNotReadyError("points: no finalized block");
  if (finalized.number < deps.config.fromBlock) {
    throw new MorphoPointsNotReadyError("points: the market's creation block is not finalized yet");
  }
  const snapshot = await snapshotAt(deps, {number: finalized.number, timestamp: finalized.timestamp}, deadline);
  const block = snapshot.asOfBlock;
  const owner = wallet.toLowerCase();
  const [position, exempt, blocked, tracked, walletShares] = await Promise.all([
    deps.client.readContract({
      address: MORPHO_BLUE,
      abi: MORPHO_COLLATERAL_ABI,
      functionName: "position",
      args: [deps.config.marketId, wallet],
      blockNumber: block,
    }),
    deps.client.readContract({
      address: deps.contracts.compliance,
      abi: OWNER_STATUS_ABI,
      functionName: "isProtocolExempt",
      args: [wallet],
      blockNumber: block,
    }),
    deps.client.readContract({
      address: deps.contracts.compliance,
      abi: OWNER_STATUS_ABI,
      functionName: "isJurisdictionBlocked",
      args: [wallet],
      blockNumber: block,
    }),
    deps.client.readContract({
      address: deps.contracts.points,
      abi: POINTS_ABI,
      functionName: "trackedBalances",
      args: [wallet],
      blockNumber: block,
    }),
    deps.client.readContract({
      address: deps.contracts.susdfr,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [wallet],
      blockNumber: block,
    }),
  ]);
  const mine = snapshot.owners.get(owner);
  const collateral = mine?.collateral ?? 0n;
  if (position[2] !== collateral) {
    dropHistory(deps, snapshot.history);
    throw new MorphoPointsIntegrityError("points: replayed collateral disagrees with Morpho Blue");
  }
  const base = {
    ok: true as const,
    enabled: true as const,
    marketId: deps.config.marketId,
    asOfBlock: block.toString(),
    asOfTimestamp: snapshot.asOfTimestamp.toString(),
    wallet,
    collateral: collateral.toString(),
    rateEpochs: snapshot.rateEpochs,
  };
  // PointsModule never credits a protocol-exempt address, and a jurisdiction-blocked address could
  // never have received these shares in a wallet; neither is credited here.
  if (exempt) return {...base, points: "0", excluded: "protocol-exempt"};
  if (blocked) return {...base, points: "0", excluded: "jurisdiction-blocked"};
  // The vault calls the points hook on every mint, burn and transfer, so for a wallet that is not
  // exempt the ledger's tracked shares equal its balance unless a hook failed and dropped a
  // transition. Tracked shares above the balance mean the on-chain ledger is still crediting
  // shares that left the wallet, possibly the very shares posted here, so the Morpho points are
  // withheld until anyone calls PointsModule.reconcile(wallet). This covers every leg of a
  // routed supply and clears itself on reconcile. It does not net the on-chain over-credit that
  // accrued before the reconcile, nor one that a later opposite failure has already cancelled.
  if (mine !== undefined && tracked[0] > walletShares) {
    return {...base, reconcileRequired: true, trackedShares: tracked[0].toString(), walletShares: walletShares.toString()};
  }
  return {...base, points: (mine?.points ?? 0n).toString()};
}
