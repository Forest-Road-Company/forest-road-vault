import fs from "node:fs";
import path from "node:path";
import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { ProtocolScene, type ProtocolSceneName } from "@/components/site/ProtocolScene";
import { PageShell } from "@/components/site/PageShell";
import { AUDIT_SECTION, DOCS, docBySlug } from "@/content/docs";
import { socialMetadata, type ShareCard } from "@/lib/shareCards";

export function generateStaticParams() {
  return DOCS.map((d) => ({ slug: d.slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const doc = docBySlug(slug);
  if (!doc) return { title: "Docs | Forest Road Vault" };
  const title = `${doc.title} | Forest Road Vault`;
  const card: ShareCard | undefined =
    slug === "overview" ? "overview" : slug === "how-to" ? "how-to" : undefined;

  return {
    title,
    description: doc.summary,
    ...(card ? socialMetadata({ card, title, description: doc.summary }) : {}),
  };
}

function readDoc(file: string): string {
  const full = path.join(process.cwd(), "src/content/docs", file);
  const md = fs.readFileSync(full, "utf8");
  // Drop the leading H1 (the page header renders the title itself).
  return md.replace(/^#\s+.*(\r?\n)+/, "");
}

export default async function DocPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const doc = docBySlug(slug);
  if (!doc) notFound();

  const markdown = readDoc(doc.file);
  const idx = DOCS.findIndex((d) => d.slug === slug);
  // The audit register closes the reading order, so the last markdown doc points at it.
  const nextDoc = DOCS[idx + 1];
  const next = nextDoc
    ? { href: `/docs/${nextDoc.slug}`, title: nextDoc.title }
    : { href: AUDIT_SECTION.href, title: AUDIT_SECTION.title };
  const scene: ProtocolSceneName =
    slug === "overview" ? "capital" : slug === "how-to" ? "lifecycle" : "docs";

  return (
    <PageShell
      bleed
      section={`Docs / ${doc.eyebrow}`}
      title={doc.title}
      lede={doc.summary}
      visual={<ProtocolScene scene={scene} />}
    >
      <div className="section-motion section-light">
        <div className="mx-auto max-w-3xl px-5 py-16 md:py-20">
          <article className="doc-prose">
            {/* Raw HTML is explicitly discarded. react-markdown also applies a safe URL transform,
                so repository prose cannot inject script URLs or executable markup into the site. */}
            <ReactMarkdown skipHtml remarkPlugins={[remarkGfm]}>
              {markdown}
            </ReactMarkdown>
          </article>

          <Link
            href={next.href}
            className="mt-16 flex items-center justify-between rounded-card border border-line bg-raised/70 p-5 transition-colors hover:border-accent/50 hover:bg-raised"
          >
            <span>
              <span className="text-[11px] font-semibold uppercase tracking-[0.2em] text-ink-faint">
                Next
              </span>
              <span className="mt-1 block text-[15px] font-medium text-ink">
                {next.title}
              </span>
            </span>
            <span className="text-accent">→</span>
          </Link>
        </div>
      </div>
    </PageShell>
  );
}
