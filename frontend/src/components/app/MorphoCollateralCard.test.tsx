import {QueryClient, QueryClientProvider} from "@tanstack/react-query";
import {render, screen, waitFor} from "@testing-library/react";
import {afterEach, describe, expect, it, vi} from "vitest";

import {MorphoCollateralCard} from "./PointsDashboard";

const WALLET = "0x000000000000000000000000000000000000a11c" as const;

function renderCard(response: unknown, status = 200) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response(JSON.stringify(response), {status, headers: {"content-type": "application/json"}})),
  );
  const client = new QueryClient({defaultOptions: {queries: {retry: false}}});
  return render(
    <QueryClientProvider client={client}>
      <MorphoCollateralCard wallet={WALLET} />
    </QueryClientProvider>,
  );
}

afterEach(() => vi.unstubAllGlobals());

describe("MorphoCollateralCard", () => {
  it("renders nothing while the market is not configured", async () => {
    const {container} = renderCard({ok: true, enabled: false});
    await waitFor(() => expect(fetch).toHaveBeenCalledWith(`/api/points/morpho?wallet=${WALLET}`));
    expect(container).toBeEmptyDOMElement();
  });

  it("shows the collateral and the points computed from Morpho events", async () => {
    renderCard({
      ok: true,
      enabled: true,
      collateral: (1_234n * 10n ** 24n).toString(),
      points: (56n * 10n ** 18n).toString(),
      asOfBlock: "26100000",
    });
    expect(await screen.findByText("sUSDfr posted as collateral on Morpho")).toBeInTheDocument();
    expect(screen.getByText(/1,234/)).toBeInTheDocument();
    expect(screen.getByText("56")).toBeInTheDocument();
    expect(screen.getByText("26100000")).toBeInTheDocument();
    expect(screen.getByText(/shown separately from the on-chain total/)).toBeInTheDocument();
    // Decision D16: blocked or exempt status is read at the served block and applied to the whole
    // history, and the page says so.
    expect(screen.getByText(/read at the block\s+shown and applies to its whole collateral history/)).toBeInTheDocument();
  });

  it("says it is unavailable rather than showing zero when the server fails", async () => {
    renderCard({ok: false, error: "Morpho collateral points are temporarily unavailable."}, 502);
    expect(await screen.findByText(/temporarily unavailable\. No zero balance has been assumed/)).toBeInTheDocument();
  });

  it("explains an address that is not credited", async () => {
    renderCard({
      ok: true,
      enabled: true,
      collateral: "5",
      points: "0",
      asOfBlock: "1",
      excluded: "jurisdiction-blocked",
    });
    expect(
      await screen.findByText(/jurisdiction-blocked, so none of its collateral earns points while that status stands/),
    ).toBeInTheDocument();
  });

  it("holds the points back, without showing zero, while the on-chain ledger needs reconciling", async () => {
    renderCard({
      ok: true,
      enabled: true,
      collateral: (800n * 10n ** 24n).toString(),
      asOfBlock: "26100000",
      reconcileRequired: true,
      trackedShares: (900n * 10n ** 24n).toString(),
      walletShares: "0",
    });
    expect(await screen.findByText(/held back until the on-chain points ledger is reconciled/)).toBeInTheDocument();
    expect(screen.getByText(/still counts 900 sUSDfr in\s+this wallet, which holds 0/)).toBeInTheDocument();
    expect(screen.queryByText("points computed from Morpho events")).not.toBeInTheDocument();
    expect(screen.queryByText(/temporarily unavailable/)).not.toBeInTheDocument();
  });
});
