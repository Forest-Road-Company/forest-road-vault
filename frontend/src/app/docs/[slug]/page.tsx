import fs from "node:fs";
import path from "node:path";
import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import ReactMarkdown from "react-markdown";
import { AUDIT_SECTION, DOCS, docBySlug } from "@/content/docs";

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
  if (!doc) return { title: "Docs — Forest Road Vault" };
  return { title: `${doc.title} — Forest Road Vault`, description: doc.summary };
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

  return (
    <div className="mx-auto max-w-3xl px-5 py-20">
      <Link
        href="/docs"
        className="font-mono text-[11px] uppercase tracking-[0.2em] text-moss transition-colors hover:text-moss-bright"
      >
        ← Docs
      </Link>
      <p className="mt-6 font-mono text-[11px] uppercase tracking-[0.22em] text-ink-faint">
        {doc.eyebrow}
      </p>
      <h1 className="serif-display mt-2 text-[38px] leading-[1.1] text-ink md:text-[46px]">
        {doc.title}
      </h1>
      <div className="keyline mt-6 w-14" />

      <article className="doc-prose mt-10">
        {/* Raw HTML is explicitly discarded. react-markdown also applies a safe URL transform,
            so repository prose cannot inject script URLs or executable markup into the site. */}
        <ReactMarkdown skipHtml>{markdown}</ReactMarkdown>
      </article>

      <Link
        href={next.href}
        className="mt-16 flex items-center justify-between rounded-card border border-line bg-raised/70 p-5 transition-colors hover:border-moss/50 hover:bg-raised"
      >
        <span>
          <span className="font-mono text-[11px] uppercase tracking-[0.2em] text-ink-faint">
            Next
          </span>
          <span className="mt-1 block text-[15px] font-medium text-ink">
            {next.title}
          </span>
        </span>
        <span className="text-moss">→</span>
      </Link>
    </div>
  );
}
