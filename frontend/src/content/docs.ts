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
    title: "Protocol Overview",
    eyebrow: "Start here",
    summary:
      "What the protocol is: two tokens, identified-per-asset collateral, and the three-layer loss cascade.",
  },
  {
    slug: "guarantees",
    file: "invariants.md",
    title: "Protocol Guarantees",
    eyebrow: "Safety spec",
    summary:
      "The nine system invariants — backing, value conservation, cascade ordering, the mint gate, FIFO redemption — each mapped to the on-chain mechanism that enforces it and the test that proves it.",
  },
  {
    slug: "roles-and-governance",
    file: "roles-and-governance.md",
    title: "Roles & Governance",
    eyebrow: "Trust model",
    summary:
      "Every privileged role, who holds it in production, and the exact functions it gates — including the timelocked governance setters and the never-pausable cascade.",
  },
  {
    slug: "recovery",
    file: "recovery.md",
    title: "Default Recovery & Exit Pricing",
    eyebrow: "Valuation",
    summary:
      "How professional recovery assessments affect the queue, how junior protection is applied, and why any later redeemer top-up is discretionary and separately funded.",
  },
  {
    slug: "security",
    file: "security.md",
    title: "Security & Testing",
    eyebrow: "Assurance",
    summary:
      "Test rigor, exact current evidence, the multi-round internal audit, and the human-owned production assurance gates.",
  },
];

/**
 * The audit section is not a single markdown page and so is not a DOCS entry — it is a
 * register of separate review rounds at /docs/audit, each with its own findings and
 * remediation history (see ./audits.ts). It is listed last in the docs reading order and
 * is the "next" target after the final DOCS entry.
 *
 * Keeping it out of DOCS also keeps /docs/audit off the [slug] route's static params, so
 * the explicit /docs/audit page is the only thing that claims that path.
 */
export const AUDIT_SECTION = {
  href: "/docs/audit",
  title: "Audit Register",
  eyebrow: "Full findings",
  summary:
    "Every source-level review run against the protocol, newest first — each round with its own findings and its own remediation history, including the findings that were accepted rather than fixed.",
} as const;

/**
 * Deployed addresses are generated from the typed deployment config rather than written
 * as markdown, so the page cannot drift from the addresses the application actually calls.
 * Like AUDIT_SECTION it is therefore not a DOCS entry, which also keeps /docs/addresses
 * off the [slug] route's static params.
 */
export const ADDRESSES_SECTION = {
  href: "/docs/addresses",
  title: "Deployed Addresses",
  eyebrow: "On-chain",
  summary:
    "Every contract this build reads, with its role and a block-explorer link — generated from the same configuration the application uses, so it cannot fall out of step with the live deployment.",
} as const;

export function docBySlug(slug: string): DocEntry | undefined {
  return DOCS.find((d) => d.slug === slug);
}
