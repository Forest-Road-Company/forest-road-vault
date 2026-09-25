// Registry of published documentation. Markdown lives in ./docs/*.md and is rendered at
// build time (see /docs/[slug]/page.tsx). Order here is the reading order on the index.
export type DocEntry = {
  slug: string;
  file: string;
  title: string;
  eyebrow: string;
  summary: string;
};

export const DOCS: DocEntry[] = [
  {
    slug: "overview",
    file: "overview.md",
    title: "Protocol overview",
    eyebrow: "Start here",
    summary:
      "What the protocol is: two tokens, identified-per-asset collateral, and the three-layer loss cascade.",
  },
  {
    slug: "how-to",
    file: "how-to.md",
    title: "How to use the app",
    eyebrow: "Guide",
    summary:
      "Step by step: connect a wallet, check what your address can do, get USDfr, stake it for yield, exit through the redemption queue, and track your position.",
  },
  {
    slug: "status",
    file: "status.md",
    title: "Live deployment status",
    eyebrow: "Ethereum V2",
    summary:
      "The live loan book, the loss protection in place today, what has run on mainnet, governance in progress, and the operating limits that apply.",
  },
  {
    slug: "guarantees",
    file: "invariants.md",
    title: "Protocol guarantees",
    eyebrow: "Safety spec",
    summary:
      "The nine system invariants: backing, value conservation, cascade ordering, the mint gate, FIFO redemption. Each is mapped to the on-chain mechanism that enforces it and the test that proves it.",
  },
  {
    slug: "roles-and-governance",
    file: "roles-and-governance.md",
    title: "Roles & governance",
    eyebrow: "Trust model",
    summary:
      "Every privileged role, who holds it in production, and the exact functions it gates, including the timelocked governance setters and the never-pausable cascade.",
  },
  {
    slug: "recovery",
    file: "recovery.md",
    title: "Default recovery & exit pricing",
    eyebrow: "Valuation",
    summary:
      "How professional recovery assessments affect the queue, how junior protection is applied, and why any later redeemer top-up is discretionary and separately funded.",
  },
  {
    slug: "security",
    file: "security.md",
    title: "Security & testing",
    eyebrow: "Assurance",
    summary:
      "Test rigor and the evidence behind the deployed release, the limits that remain, the trust boundaries, and how to report a vulnerability.",
  },
  {
    slug: "integrating",
    file: "integrating.md",
    title: "Integrating",
    eyebrow: "For builders",
    summary:
      "Where our tokens depart from what their interfaces imply: asynchronous redemption through the queue, the absolute gas floor on every balance change, sanctions-screened transfers, and the 24-decimal share. Read before wiring a router, adapter or aggregator.",
  },
];

/**
 * The audit section is not a single markdown page and so is not a DOCS entry: it is a
 * register of separate review rounds at /docs/audit, each with its own findings and
 * remediation history (see ./audits.ts). It is listed last in the docs reading order and
 * is the "next" target after the final DOCS entry.
 *
 * Keeping it out of DOCS also keeps /docs/audit off the [slug] route's static params, so
 * the explicit /docs/audit page is the only thing that claims that path.
 */
export const AUDIT_SECTION = {
  href: "/docs/audit",
  title: "Audit register",
  eyebrow: "Full findings",
  summary:
    "Dated contract, deployment, curator and interface reviews, newest first. Each record states its scope, material findings, remediation status and limits; complete claim corpora remain in their named reports.",
} as const;

/**
 * Deployed addresses are generated from the typed deployment config rather than written
 * as markdown, so the page cannot drift from the addresses the application actually calls.
 * Like AUDIT_SECTION it is therefore not a DOCS entry, which also keeps /docs/addresses
 * off the [slug] route's static params.
 */
export const ADDRESSES_SECTION = {
  href: "/docs/addresses",
  title: "Deployed addresses",
  eyebrow: "On-chain",
  summary:
    "Every contract, what it does, and a block-explorer link, plus the USDfr/USDC market. Addresses come from the same configuration the application uses, so they cannot fall out of step with the live deployment.",
} as const;

export function docBySlug(slug: string): DocEntry | undefined {
  return DOCS.find((d) => d.slug === slug);
}
