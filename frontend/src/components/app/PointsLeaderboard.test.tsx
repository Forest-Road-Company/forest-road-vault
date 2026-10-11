import {QueryClient, QueryClientProvider} from "@tanstack/react-query";
import {act, fireEvent, render, screen, waitFor, within} from "@testing-library/react";
import {afterEach, describe, expect, it, vi} from "vitest";

const account = vi.hoisted(() => ({address: undefined as string | undefined}));
vi.mock("wagmi", () => ({useAccount: () => ({address: account.address})}));

import {LEADERBOARD_STEP, PointsLeaderboard, type LeaderboardResponse} from "./PointsLeaderboard";

const E18 = 10n ** 18n;
const wallet = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as `0x${string}`;
const row = (rank: number, n: number, points: bigint, parts: Partial<Record<"onchain" | "pendle" | "morpho", bigint>> = {}) => ({
  rank,
  wallet: wallet(n),
  points: String(points * E18),
  onchain: String((parts.onchain ?? points) * E18),
  pendle: String((parts.pendle ?? 0n) * E18),
  morpho: String((parts.morpho ?? 0n) * E18),
});
/** A checksummed address, as the server's getAddress and wagmi both return it (mixed case). */
const CHECKSUMMED = "0xAbCdEf0123456789aBcDeF0123456789AbCdEf01" as const;

function board(overrides: Partial<Extract<LeaderboardResponse, {enabled: true}>> = {}): LeaderboardResponse {
  return {
    ok: true,
    enabled: true,
    asOfBlock: "26170000",
    asOfTimestamp: "1791700000",
    pendle: {enabled: true, asOfBlock: "26170020", asOfTimestamp: 1_791_700_240},
    morpho: {enabled: true, withheld: 0},
    ranked: 3,
    rankedPoints: String(650n * E18),
    truncated: false,
    rows: [row(1, 0xb0b, 350n, {onchain: 100n, pendle: 250n}), row(2, 0xa11c, 200n), row(3, 0xca7, 100n, {onchain: 0n, morpho: 100n})],
    forestRoad: {wallets: 2, points: String(1_000n * E18)},
    venues: [
      {key: "uniswap-v4", label: "Uniswap v4 PoolManager", address: wallet(0x4444), note: "Liquidity in Uniswap v4 pools.", points: String(5_000n * E18)},
      {key: "morpho-blue", label: "Morpho Blue", address: wallet(0xbbbb), note: "Collateral on Morpho.", points: "0"},
    ],
    notRanked: {jurisdictionBlocked: 0, belowOnePoint: 0},
    ...overrides,
  } as LeaderboardResponse;
}

const json = (response: unknown, status = 200) =>
  new Response(JSON.stringify(response), {status, headers: {"content-type": "application/json"}});

function renderBoard(response: unknown, status = 200) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => json(response, status)),
  );
  return mount();
}

/** Renders the board against whatever `fetch` the test has stubbed. */
function mount() {
  const client = new QueryClient({defaultOptions: {queries: {retry: false}}});
  const view = render(
    <QueryClientProvider client={client}>
      <div data-testid="board">
        <PointsLeaderboard />
      </div>
      {/* A sibling: a render error unmounts the whole root, so its presence proves the board did not crash. */}
      <p>after the board</p>
    </QueryClientProvider>,
  );
  return {...view, client};
}

afterEach(() => {
  vi.unstubAllGlobals();
  account.address = undefined;
});

describe("PointsLeaderboard", () => {
  it("renders nothing when the server reports the leaderboard off, without crashing", async () => {
    renderBoard({ok: true, enabled: false});
    expect(screen.getByText("Loading the leaderboard…")).toBeInTheDocument();
    await waitFor(() => expect(fetch).toHaveBeenCalledWith("/api/points/leaderboard"));
    await waitFor(() => expect(screen.getByTestId("board")).toBeEmptyDOMElement());
    expect(screen.getByText("after the board")).toBeInTheDocument();
  });

  it("ranks the wallets with their parts, and lists Forest Road and the venues with points under the table", async () => {
    renderBoard(board());
    expect(await screen.findByText("3 wallets ranked")).toBeInTheDocument();
    const rows = within(screen.getByRole("table")).getAllByRole("row").slice(1);
    expect(rows.map((r) => within(r).getAllByRole("cell").map((c) => c.textContent))).toEqual([
      ["1", "0x0000…0b0b", "350", "100", "250", "0"],
      ["2", "0x0000…a11c", "200", "200", "0", "0"],
      ["3", "0x0000…0ca7", "100", "0", "0", "100"],
    ]);
    expect(screen.getByText(/Forest Road wallets \(2\):/)).toBeInTheDocument();
    expect(screen.getByText(/Uniswap v4 PoolManager \(/)).toBeInTheDocument();
    expect(screen.getByText("Liquidity in Uniswap v4 pools.")).toBeInTheDocument();
    // A venue holding nothing is not listed.
    expect(screen.queryByText(/Morpho Blue \(/)).not.toBeInTheDocument();
    // Lines with nothing to report are not shown.
    expect(screen.queryByText(/Jurisdiction-blocked wallets:/)).not.toBeInTheDocument();
    expect(screen.queryByText(/held back/)).not.toBeInTheDocument();
    expect(screen.getByText("26170000")).toBeInTheDocument();
    expect(screen.getByText(/\(2026-10-11 06:26 UTC\)/)).toBeInTheDocument();
    expect(screen.getByText(/as of block 26170020 \(2026-10-11 06:30 UTC\)/)).toBeInTheDocument();
    expect(screen.getByText(/Morpho points are computed by Forest Road from Morpho Blue’s events at the same block/)).toBeInTheDocument();
    expect(screen.getByText(/must add up exactly to its own tracked totals at that block/)).toBeInTheDocument();
  });

  it("links each wallet to its explorer page", async () => {
    renderBoard(board());
    await screen.findByText("3 wallets ranked");
    expect(screen.getByRole("link", {name: "0x0000…0b0b"})).toHaveAttribute(
      "href",
      `https://sepolia.etherscan.io/address/${wallet(0xb0b)}`,
    );
  });

  it("keeps the compliance sentences under the board", async () => {
    renderBoard(board());
    await screen.findByText("3 wallets ranked");
    expect(screen.getByText(/jurisdiction-blocked wallets are not ranked\./)).toBeInTheDocument();
    expect(screen.getByText(/Points are not a token, and neither points nor a rank carry any promise of value or conversion\./)).toBeInTheDocument();
  });

  it("shows whole points truncated, never rounded up, and a holding under one point as <1", async () => {
    const almost = String(350n * E18 - 1n); // 349.999… points
    const dust = String(E18 / 4n); // 0.25 points
    renderBoard(
      board({
        ranked: 2,
        rows: [
          {rank: 1, wallet: wallet(0xb0b), points: almost, onchain: almost, pendle: "0", morpho: "0"},
          {rank: 2, wallet: wallet(0xa11c), points: dust, onchain: dust, pendle: "0", morpho: "0"},
        ],
      }),
    );
    await screen.findByText("2 wallets ranked");
    const rows = within(screen.getByRole("table")).getAllByRole("row").slice(1);
    expect(within(rows[0]).getAllByRole("cell")[2]).toHaveTextContent(/^349$/);
    expect(within(rows[1]).getAllByRole("cell")[2]).toHaveTextContent(/^<1$/);
  });

  it("speaks of one wallet and one point in the singular", async () => {
    account.address = wallet(0xb0b);
    renderBoard(board({ranked: 1, rows: [row(1, 0xb0b, 1n)]}));
    expect(await screen.findByText("1 wallet ranked")).toBeInTheDocument();
    expect(screen.getByTestId("leaderboard-you")).toHaveTextContent("Your wallet ranks #1 of 1, with 1 point in total at block 26170000.");
  });

  it("shows the server's shared ranks for equal totals", async () => {
    renderBoard(board({ranked: 4, rows: [row(1, 1, 400n), row(2, 2, 300n), row(2, 3, 300n), row(4, 4, 100n)]}));
    await screen.findByText("4 wallets ranked");
    const ranks = within(screen.getByRole("table")).getAllByRole("row").slice(1).map((r) => within(r).getAllByRole("cell")[0].textContent);
    expect(ranks).toEqual(["1", "2", "2", "4"]);
  });

  it("highlights the connected wallet's row and states its rank", async () => {
    account.address = wallet(0xa11c);
    renderBoard(board());
    expect(await screen.findByTestId("leaderboard-you")).toHaveTextContent("Your wallet ranks #2 of 3, with 200 points in total at block 26170000.");
    const mine = screen.getByText("You").closest("tr")!;
    expect(mine).toHaveAttribute("aria-current", "true");
    expect(mine).toHaveClass("bg-accent-faint");
    expect(within(mine).getAllByRole("cell")[0]).toHaveTextContent("2");
  });

  it("matches the connected wallet against the server's checksummed rows", async () => {
    account.address = CHECKSUMMED;
    renderBoard(board({rows: [{...row(1, 0xb0b, 350n), wallet: CHECKSUMMED}, row(2, 0xa11c, 200n), row(3, 0xca7, 100n)]}));
    expect(await screen.findByTestId("leaderboard-you")).toHaveTextContent("Your wallet ranks #1 of 3");
    expect(screen.getByText("You").closest("tr")).toHaveAttribute("aria-current", "true");
  });

  it("says a connected wallet outside the ranks has no ranked points, naming no reason (the page knows none)", async () => {
    account.address = wallet(0xdead);
    renderBoard(board());
    expect(await screen.findByTestId("leaderboard-you")).toHaveTextContent("Your wallet has no ranked points at block 26170000.");
    expect(screen.queryByText(/Forest Road wallet,/)).not.toBeInTheDocument();
  });

  it("shows the first rows, then more on request, and says when the answer is cut to the top rows", async () => {
    const rows = Array.from({length: LEADERBOARD_STEP + 5}, (_, i) => row(i + 1, 0x1000 + i, BigInt(1_000 - i)));
    account.address = wallet(0xdead);
    renderBoard(board({rows, ranked: 2_000, truncated: true}));
    expect(await screen.findByText("2,000 wallets ranked")).toBeInTheDocument();
    expect(within(screen.getByRole("table")).getAllByRole("row")).toHaveLength(LEADERBOARD_STEP + 1);
    expect(screen.getByTestId("leaderboard-you")).toHaveTextContent(`Your wallet is not in the top ${LEADERBOARD_STEP + 5}.`);
    expect(screen.getByText(`The list holds the top ${LEADERBOARD_STEP + 5} of 2,000 ranked wallets.`)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", {name: "Show more"}));
    expect(within(screen.getByRole("table")).getAllByRole("row")).toHaveLength(LEADERBOARD_STEP + 5 + 1);
    expect(screen.queryByRole("button", {name: "Show more"})).not.toBeInTheDocument();
  });

  it("states a ranked wallet's place out of every ranked wallet, and offers to show its row", async () => {
    const rows = Array.from({length: LEADERBOARD_STEP + 5}, (_, i) => row(i + 1, 0x1000 + i, BigInt(1_000 - i)));
    account.address = wallet(0x1000 + LEADERBOARD_STEP + 2);
    renderBoard(board({rows, ranked: 2_000, truncated: true}));
    expect(await screen.findByTestId("leaderboard-you")).toHaveTextContent(`Your wallet ranks #${LEADERBOARD_STEP + 3} of 2,000`);
    expect(screen.queryByText("You")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", {name: "Show my row"}));
    expect(screen.getByText("You").closest("tr")).toHaveAttribute("aria-current", "true");
  });

  it("does not report Forest Road's line when none of its wallets has points", async () => {
    renderBoard(board({forestRoad: {wallets: 0, points: "0"}}));
    await screen.findByText("3 wallets ranked");
    expect(screen.queryByText(/Forest Road wallets/)).not.toBeInTheDocument();
  });

  it("reports the jurisdiction-blocked count and withheld Morpho points, without calling the withheld wallets unranked", async () => {
    renderBoard(board({notRanked: {jurisdictionBlocked: 2, belowOnePoint: 0}, morpho: {enabled: true, withheld: 1}}));
    expect(await screen.findByText("Jurisdiction-blocked wallets: 2")).toBeInTheDocument();
    const note = screen.getByText(/Morpho points are held back for 1 wallet until the PointsModule is reconciled for it/);
    expect(note.closest("ul")).toBeNull();
  });

  it("names only the sources the answer includes", async () => {
    renderBoard(board({pendle: {enabled: false}, morpho: {enabled: false, withheld: 0}}));
    await screen.findByText("3 wallets ranked");
    expect(screen.getByText("on-chain")).toBeInTheDocument();
    expect(screen.queryByRole("columnheader", {name: "Pendle"})).not.toBeInTheDocument();
    expect(screen.queryByRole("columnheader", {name: "Morpho"})).not.toBeInTheDocument();
    expect(screen.getByText(/Pendle points are not included in this answer\./)).toBeInTheDocument();
    expect(screen.getByText(/Morpho points are not included in this answer\./)).toBeInTheDocument();
  });

  it("says no wallet is ranked yet, while still reporting the unranked lines", async () => {
    renderBoard(board({ranked: 0, rows: [], rankedPoints: "0"}));
    expect(await screen.findByText("No wallet is ranked yet.")).toBeInTheDocument();
    expect(screen.getByText(/Forest Road wallets \(2\):/)).toBeInTheDocument();
  });

  it("says it is unavailable rather than showing a partial ranking when the server fails", async () => {
    renderBoard({ok: false, error: "The leaderboard is temporarily unavailable."}, 502);
    expect(await screen.findByText(/temporarily unavailable\. No ranking is shown from a partial view/)).toBeInTheDocument();
  });

  it("says it is catching up when the server is still indexing", async () => {
    renderBoard({ok: false, error: "The leaderboard is catching up with the chain. Try again in a minute."}, 503);
    expect(await screen.findByText(/catching up with the chain and will appear here shortly/)).toBeInTheDocument();
  });

  it("does not ask again at once after a failure the server answered", async () => {
    renderBoard({ok: false, error: "The leaderboard is temporarily unavailable."}, 502);
    await screen.findByText(/temporarily unavailable/);
    // Past the client's first retry delay (one second): a retry would have asked by now.
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 1_200));
    });
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("retries once at once when the request never reached the server", async () => {
    const answers = vi.fn<() => Promise<Response>>()
      .mockRejectedValueOnce(new TypeError("Failed to fetch"))
      .mockImplementation(async () => json(board()));
    vi.stubGlobal("fetch", answers);
    mount();
    expect(await screen.findByText("3 wallets ranked", {}, {timeout: 3_000})).toBeInTheDocument();
    expect(answers).toHaveBeenCalledTimes(2);
  });

  it("keeps the last complete board, with a note, when a later refresh fails", async () => {
    const {client} = renderBoard(board());
    await screen.findByText("3 wallets ranked");
    vi.stubGlobal("fetch", vi.fn(async () => json({ok: false, error: "The leaderboard is temporarily unavailable."}, 502)));
    await act(async () => {
      await client.refetchQueries({queryKey: ["points-leaderboard"]});
    });
    expect(await screen.findByText(/The latest refresh failed; this board still stands as of block 26170000\./)).toBeInTheDocument();
    expect(screen.getByText("3 wallets ranked")).toBeInTheDocument();
  });

  it("counts wallets below one point under Not ranked", async () => {
    renderBoard(board({notRanked: {jurisdictionBlocked: 0, belowOnePoint: 3}}));
    expect(await screen.findByText("Wallets with less than one point: 3")).toBeInTheDocument();
  });

  it("says plainly when Pendle points are not part of the ranking, and not otherwise", async () => {
    const {unmount} = renderBoard(board({pendle: {enabled: false}}));
    expect(await screen.findByTestId("leaderboard-pendle-off")).toHaveTextContent("Pendle points are not included in this ranking right now");
    unmount();
    renderBoard(board());
    await screen.findByRole("table");
    expect(screen.queryByTestId("leaderboard-pendle-off")).not.toBeInTheDocument();
  });
});
