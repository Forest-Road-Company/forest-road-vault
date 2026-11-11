import {describe, expect, it} from "vitest";
import {DEFAULT_SHARE_IMAGE, pageMetadata, SHARE_CARDS} from "@/lib/shareCards";

describe("pageMetadata", () => {
  it("gives a page its own title, description, Open Graph and Twitter text, with the default image", () => {
    const metadata = pageMetadata({title: "How it works | Forest Road Vault", description: "How the Vault works."});

    expect(metadata.title).toBe("How it works | Forest Road Vault");
    expect(metadata.description).toBe("How the Vault works.");
    expect(metadata.openGraph).toMatchObject({
      type: "website",
      siteName: "Forest Road Vault",
      title: "How it works | Forest Road Vault",
      description: "How the Vault works.",
      images: [DEFAULT_SHARE_IMAGE],
    });
    expect(metadata.twitter).toMatchObject({
      card: "summary_large_image",
      title: "How it works | Forest Road Vault",
      description: "How the Vault works.",
      images: [{url: DEFAULT_SHARE_IMAGE.url, alt: DEFAULT_SHARE_IMAGE.alt}],
    });
    expect(metadata).not.toHaveProperty("robots");
  });

  it("uses a page's card and separate share text when given", () => {
    const metadata = pageMetadata({
      title: "Risk factors | Forest Road Vault",
      description: "Page description.",
      card: "risk",
      socialTitle: "Share title",
      socialDescription: "Share description.",
      robots: {index: false, follow: false},
    });

    expect(metadata.description).toBe("Page description.");
    expect(metadata.openGraph).toMatchObject({
      title: "Share title",
      description: "Share description.",
      images: [{url: SHARE_CARDS.risk.path, alt: SHARE_CARDS.risk.alt, width: 1000, height: 525}],
    });
    expect(metadata.twitter).toMatchObject({title: "Share title", description: "Share description."});
    expect(metadata.robots).toEqual({index: false, follow: false});
  });
});
