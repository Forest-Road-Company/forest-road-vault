import {QueryClient, QueryClientProvider} from "@tanstack/react-query";
import {render, screen, waitFor} from "@testing-library/react";
import {afterEach, describe, expect, it, vi} from "vitest";

import {PendlePointsCard} from "./PendlePointsCard";

const WALLET = "0x000000000000000000000000000000000000a11c" as const;
const E18 = 10n ** 18n;

function renderCard(response: unknown, status = 200) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response(JSON.stringify(response), {status, headers: {"content-type": "application/json"}})),
  );
  const client = new QueryClient({defaultOptions: {queries: {retry: false}}});
  return render(
    <QueryClientProvider client={client}>
      <PendlePointsCard wallet={WALLET} />
    </QueryClientProvider>,
  );
}

afterEach(() => vi.unstubAllGlobals());

describe("PendlePointsCard", () => {
  it("renders nothing while Pendle points are not enabled", async () => {
    const {container} = renderCard({ok: true, enabled: false});
    await waitFor(() => expect(fetch).toHaveBeenCalledWith(`/api/points/pendle?wallet=${WALLET}`));
    expect(container).toBeEmptyDOMElement();
  });

  it("shows the points, the day's rate and each market held", async () => {
    renderCard({
      ok: true,
      enabled: true,
      asOfBlock: "26148102",
      asOfTimestamp: 1_791_500_000,
      excluded: null,
      points: String(1_234n * E18),
      pointsPerDay: String(56n * E18),
      markets: [
        {key: "susdfr-2027jan", label: "sUSDfr 28 Jan 2027", yt: String(1_000n * E18), sy: "0", lp: String(234n * E18), points: String(1_234n * E18), pointsPerDay: String(56n * E18)},
        {key: "usdfr-2027jan", label: "USDfr 28 Jan 2027", yt: "0", sy: "0", lp: "0", points: "0", pointsPerDay: "0"},
      ],
    });
    expect(await screen.findByText("sUSDfr and USDfr held through Pendle")).toBeInTheDocument();
    expect(screen.getByText("1,234")).toBeInTheDocument();
    expect(screen.getByText("56 a day")).toBeInTheDocument();
    expect(screen.getByText(/YT 1,000 · LP 234 · SY 0/)).toBeInTheDocument();
    expect(screen.queryByText(/^USDfr 28 Jan 2027:/)).not.toBeInTheDocument();
    expect(screen.getByText("26148102")).toBeInTheDocument();
    expect(screen.getByText(/shown separately from the on-chain total above/)).toBeInTheDocument();
    // Decision D16, as on the Morpho card.
    expect(screen.getByText(/read at the block shown and applies to its\s+whole Pendle history/)).toBeInTheDocument();
  });

  it("says it is unavailable rather than showing zero when the server fails", async () => {
    renderCard({ok: false, error: "Pendle points are temporarily unavailable."}, 502);
    expect(await screen.findByText(/temporarily unavailable\. No zero balance has been assumed/)).toBeInTheDocument();
  });

  it("explains an address that is not credited", async () => {
    renderCard({
      ok: true, enabled: true, asOfBlock: "1", asOfTimestamp: 1, excluded: "jurisdiction-blocked",
      points: "0", pointsPerDay: "0", markets: [],
    });
    expect(await screen.findByText(/jurisdiction-blocked, so none of its Pendle positions earn points/)).toBeInTheDocument();
    expect(screen.queryByText("points computed from Pendle events")).not.toBeInTheDocument();
  });
});
