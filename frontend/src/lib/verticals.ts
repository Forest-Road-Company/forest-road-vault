/**
 * Static vertical descriptions (copy). Live parameters (LTV caps, rate tiers,
 * concentration limits) are read from CollateralRegistry once deployed —
 * never hardcoded here (brief §8.3).
 */
export type Vertical = {
  slug: string;
  name: string;
  financed: string;
  claimType: string;
  duration: string;
  risks: { name: string; detail: string }[];
  remedy: string;
  /** Receivable-style classes enforce via legal foreclosure; marked-to-market
   *  classes (digital assets) use margin/liquidation mechanics instead. */
  collateralModel: "receivable" | "marked-to-market";
  tag?: string;
  /** On-chain collateral classes that are not marketed as sectors on the site.
   *  The class still exists in the deployed CollateralRegistry (class IDs are
   *  positional in this array), so app surfaces keep reading it; only the
   *  marketing pages filter it out via SECTORS. */
  siteHidden?: boolean;
};

export const VERTICALS: Vertical[] = [
  {
    slug: "media",
    name: "Media & entertainment",
    financed:
      "Senior secured lending against tax credits and other contracted receivables, financing film and television. A production borrows today against payments it is contractually owed, so repayment does not depend on box-office performance.",
    claimType:
      "A perfected security interest (UCC-1 and assignment) in the tax credits or contracted receivables and the borrower's right to receive them.",
    duration: "Short: months to roughly two years, driven by receivable payment timing.",
    risks: [
      { name: "Payment timing", detail: "The obligor controls when the receivable is actually paid; delays extend duration." },
      { name: "Audit / clawback", detail: "For tax-credit collateral, the agreed-upon-procedures audit can reduce the credit below the underwritten amount." },
      { name: "Obligor counterparty", detail: "Obligors range from US state programs to contracted distributors; changes in either are a real, priced risk." },
      { name: "Secondary price", detail: "Recovery in default can depend on the secondary market for the assigned claim." },
    ],
    remedy:
      "No physical collateral exists. In default the protocol forecloses on the assigned receivable, steps into the right to payment, and sells it into the secondary market.",
    collateralModel: "receivable",
  },
  {
    slug: "renewable-energy",
    name: "Renewable energy",
    financed:
      "Loans to small and mid-market renewable projects, against transferable ITC/PTC tax credits and project cashflows, for borrowers underserved by community banks and capital markets.",
    claimType:
      "Security interests in transferable federal tax credits and/or project assets and their cashflows.",
    duration: "Medium to long, spanning construction and operation.",
    risks: [
      { name: "Construction & completion", detail: "Credits and cashflows depend on the project reaching completion and qualification." },
      { name: "Policy timing", detail: "Transferability rules and deadlines shape credit value and eligibility windows." },
      { name: "Offtake & production", detail: "Operating cashflows vary with production and counterparty performance." },
    ],
    remedy:
      "Foreclose on assigned credits and project security; project-level assets provide an asset-backed remedy path unlike pure receivable classes.",
    collateralModel: "receivable",
  },
  {
    slug: "life-sciences",
    name: "Life sciences",
    financed:
      "Venture debt, royalty financing, and milestone-based credit for biotech and life-science companies.",
    claimType:
      "Security interests in company assets, royalty streams, or milestone payment rights, per structure.",
    duration: "Long, with milestone-driven repricing.",
    risks: [
      { name: "Clinical & milestone", detail: "Repayment capacity is tied to trial outcomes and development milestones." },
      { name: "Concentration", detail: "Individual positions are larger and idiosyncratic; on-chain per-borrower limits apply." },
      { name: "Exit timing", detail: "Refinancing and exit windows for venture-stage borrowers vary with market cycles." },
    ],
    remedy:
      "Standard secured-credit remedies against pledged assets and royalty/milestone rights; workout-driven rather than market-sale-driven.",
    collateralModel: "receivable",
    siteHidden: true,
  },
  {
    slug: "real-estate",
    name: "Real estate",
    financed: "Property-backed debt and structured credit positions.",
    claimType: "Mortgages / deeds of trust and related security in real property.",
    duration: "Medium to long.",
    risks: [
      { name: "Valuation", detail: "Recovery depends on property value at the time of remedy, not origination." },
      { name: "Rate environment", detail: "Refinancing risk and cap-rate moves affect borrower exit and collateral value." },
      { name: "Asset-level remedy", detail: "Foreclosure timelines vary by jurisdiction and can extend workouts." },
    ],
    remedy:
      "Classic property foreclosure and sale. It's the one class in the book with a physical-asset remedy path.",
    collateralModel: "receivable",
    siteHidden: true,
  },
  {
    slug: "digital-assets",
    name: "Digital assets",
    financed:
      "Secured lending to Forest Road's digital-assets trading subsidiary, financing the desk's trading book. It's a related-party facility, disclosed as such.",
    claimType:
      "A pledged, marked-to-market portfolio of liquid crypto assets, not a receivable. The collateral is price-volatile and liquid: the opposite profile of the receivable-backed sectors.",
    duration: "Short and revolving, with continuous collateral-health monitoring.",
    risks: [
      {
        name: "Price volatility & gap risk",
        detail:
          "Crypto collateral can reprice sharply and gap through margin levels. LTV is set conservatively and margin thresholds trigger well before impairment.",
      },
      {
        name: "Related-party exposure",
        detail:
          "The borrower is Forest Road's own subsidiary. Terms must be arm's-length, the position is capped by concentration limits, and the conflict of interest is disclosed plainly.",
      },
      {
        name: "Valuation freshness",
        detail:
          "Health checks depend on frequent attested marks. Stale marks block new draws and tighten the margin machinery automatically.",
      },
      {
        name: "Custody & operational",
        detail: "Pledged assets sit with qualified custody; key management and operational controls are part of the risk surface.",
      },
    ],
    remedy:
      "Margin-call and liquidation mechanics, not legal foreclosure: mark breach → margin call with a short cure window (top-up collateral or pay down) → liquidation of pledged assets. Hours-to-days, closer to DeFi collateral liquidation than UCC enforcement.",
    collateralModel: "marked-to-market",
    tag: "Marked-to-market · related party",
  },
];

/**
 * The sectors the site markets: media & entertainment, renewable energy and
 * digital assets. App surfaces (transparency, points) keep reading VERTICALS,
 * whose array order is the on-chain class-ID mapping.
 */
export const SECTORS: Vertical[] = VERTICALS.filter((v) => !v.siteHidden);
