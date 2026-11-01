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

export function socialMetadata({
  card,
  title,
  description,
}: {
  card: ShareCard;
  title: string;
  description: string;
}): Pick<Metadata, "openGraph" | "twitter"> {
  const image = SHARE_CARDS[card];

  return {
    openGraph: {
      type: "website",
      title,
      description,
      images: [
        {
          url: image.path,
          width: 1000,
          height: 525,
          alt: image.alt,
          type: "image/webp",
        },
      ],
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
      images: [{ url: image.path, alt: image.alt }],
    },
  };
}
