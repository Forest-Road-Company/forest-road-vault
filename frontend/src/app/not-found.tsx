import type { Metadata } from "next";
import Link from "next/link";
import { PageShell } from "@/components/site/PageShell";
import { pageMetadata } from "@/lib/shareCards";

// Next.js App Router automatically emits `<meta name="robots" content="noindex" />` on 404
// responses; omitting `robots` avoids duplicate meta tags while `pageMetadata` (with no `path`)
// still clears `alternates.canonical` so RootLayout's `/` canonical is never inherited.
export const metadata: Metadata = pageMetadata({
  title: "Page not found | Forest Road Vault",
  description: "The requested page does not exist on Forest Road Vault.",
});

export default function NotFound() {
  return (
    <PageShell
      section="404"
      title="Page not found"
      lede="The route you requested does not exist or has moved. Use the links below to return to the overview, the vault app, or protocol documentation."
    >
      <div className="flex flex-wrap gap-3">
        <Link
          href="/"
          className="rounded-pill bg-navy px-5 py-2.5 text-[13px] font-semibold text-on-navy transition-colors hover:bg-navy-raised"
        >
          Back to home
        </Link>
        <Link
          href="/app"
          className="rounded-pill border border-line bg-raised/70 px-5 py-2.5 text-[13px] font-medium text-ink transition-colors hover:border-accent/50"
        >
          Enter App →
        </Link>
        <Link
          href="/docs"
          className="rounded-pill border border-line bg-raised/70 px-5 py-2.5 text-[13px] font-medium text-ink transition-colors hover:border-accent/50"
        >
          Protocol docs →
        </Link>
      </div>
    </PageShell>
  );
}
