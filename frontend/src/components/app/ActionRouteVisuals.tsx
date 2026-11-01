/**
 * Compact process diagrams shared by the three /app action cards. They explain
 * the asset path without making a promise about timing or outcome. The parent
 * cards already participate in the viewport replay controller, so the travelling
 * dots pause off-screen and restart when the card is seen again.
 */

export function StakeRouteVisual() {
  return (
    <div
      className="action-card-route action-card-route--stake mt-5"
      aria-label="USDfr enters the sUSDfr vault and returns vault shares"
    >
      <span><b>USDfr</b><small>deposit</small></span>
      <i aria-hidden><em /></i>
      <span className="action-card-route__core"><b>Vault</b><small>credit book</small></span>
      <i aria-hidden><em /></i>
      <span><b>sUSDfr</b><small>shares</small></span>
    </div>
  );
}

export function RedeemRouteVisual({
  mode,
  stableSymbol,
}: {
  mode: "instant" | "queue";
  stableSymbol: string;
}) {
  if (mode === "queue") {
    return (
      <div
        className="action-card-route action-card-route--queue mt-5"
        aria-label="sUSDfr completes its minimum hold, advances through the FIFO queue, and settles in USDfr as liquidity becomes available"
      >
        <span><b>sUSDfr</b><small>locked</small></span>
        <i aria-hidden><em /></i>
        <span className="action-card-route__core"><b>FIFO</b><small>hold + queue</small></span>
        <i aria-hidden><em /></i>
        <span><b>USDfr</b><small>cash-paced</small></span>
      </div>
    );
  }

  return (
    <div
      className="action-card-route action-card-route--instant mt-5"
      aria-label={`USDfr is burned against idle reserves and returns ${stableSymbol} one for one`}
    >
      <span><b>USDfr</b><small>burned</small></span>
      <i aria-hidden><em /></i>
      <span className="action-card-route__core"><b>1:1</b><small>idle reserves</small></span>
      <i aria-hidden><em /></i>
      <span><b>{stableSymbol}</b><small>received</small></span>
    </div>
  );
}
