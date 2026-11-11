import type { Metadata } from "next";

export const SHARE_CARDS = {
  overview: {
    path: "/share/overview.webp",
    alt: "Forest Road Vault protocol overview and three-layer loss cascade",
  },
  transparency: {
    path: "/share/transparency.webp",
    alt: "Forest Road Vault live supply and backing transparency",
  },
  "how-to": {
    path: "/share/how-to.webp",
    alt: "How to use the Forest Road Vault app",
  },
  risk: {
    path: "/share/risk.webp",
    alt: "Forest Road Vault risk factors",
  },
  markets: {
    path: "/share/markets.webp",
    alt: "Forest Road Vault lending and borrowing markets",
  },
  sectors: {
    path: "/share/sectors.webp",
    alt: "Forest Road Vault specialty-finance sectors",
  },
} as const;

export type ShareCard = keyof typeof SHARE_CARDS;

/** The site-wide share image, for a page without a card of its own. */
export const DEFAULT_SHARE_IMAGE = {
  url: "/share/default.png",
  width: 1200,
  height: 630,
  alt: "Forest Road Vault: specialty finance credit, on-chain",
  type: "image/png",
} as const;

function shareImage(card: ShareCard | undefined) {
  if (!card) return DEFAULT_SHARE_IMAGE;
  const image = SHARE_CARDS[card];
  return {url: image.path, width: 1000, height: 525, alt: image.alt, type: "image/webp"} as const;
}

/**
 * Open Graph and Twitter fields for one page. Next.js merges metadata shallowly, so a page that sets
 * only a description still inherits the root layout's whole `openGraph` and `twitter` objects, which
 * describe the homepage. Every page therefore sets both, image included.
 */
export function socialMetadata({
  card,
  title,
  description,
}: {
  card?: ShareCard;
  title: string;
  description: string;
}): Pick<Metadata, "openGraph" | "twitter"> {
  const image = shareImage(card);

  return {
    openGraph: {
      type: "website",
      siteName: "Forest Road Vault",
      title,
      description,
      images: [image],
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
      images: [{url: image.url, alt: image.alt}],
    },
  };
}

/**
 * A page's title, description and social text together. The social title and description default
 * to the page's own; pass them when the share card should read differently.
 */
export function pageMetadata({
  title,
  description,
  card,
  socialTitle = title,
  socialDescription = description,
  robots,
}: {
  title: string;
  description: string;
  card?: ShareCard;
  socialTitle?: string;
  socialDescription?: string;
  robots?: Metadata["robots"];
}): Metadata {
  return {
    title,
    description,
    ...socialMetadata({card, title: socialTitle, description: socialDescription}),
    ...(robots ? {robots} : {}),
  };
}
