import type { Metadata } from "next";
import Link from "next/link";
import { PageShell } from "@/components/site/PageShell";
import { Section, SectionHead, KpiBand, HighlightBox } from "@/components/site/Blocks";
import { SeverityMix } from "@/components/site/AuditFindings";
import { AUDITS, openFindings, totalFindings } from "@/content/audits";

export const metadata: Metadata = {
  title: "Audit Register — Forest Road Vault",
  description:
    "Every source-level security review run against the protocol, newest first, each with its own findings and remediation history.",
};

/** Reviews run by a party other than Forest Road are labelled external. */
const isExternal = (eyebrow: string) => eyebrow.toLowerCase().includes("external");

export default function AuditRegisterPage() {
  const rounds = AUDITS.length;
  const findings = totalFindings();
  const open = openFindings().length;

  const external = AUDITS.filter((a) => isExternal(a.eyebrow));
  const internal = AUDITS.filter((a) => !isExternal(a.eyebrow));

  return (
    <PageShell
      bleed
      section="Assurance"
      title="Audit register"
      lede="Every source-level review run against this protocol, newest first. Each round keeps its own findings list and its own remediation history, including the findings that were accepted rather than fixed."
    >
      {/* ── The register in numbers, on navy. ───────────────────────────── */}
      <Section tone="navy">
        <KpiBand
          items={[
            {
              value: rounds,
              label: "Review rounds",
              note: "Each with its own findings list and remediation history.",
            },
            {
              value: findings,
              label: "Findings published",
              note: "Published in full, including those accepted rather than fixed.",
            },
            {
              value: open,
              label: "Still open or accepted",
              note: "Counted as open unless remediated or superseded.",
            },
          ]}
        />
        <div className="mt-8">
          <HighlightBox tone="navy" title="Published in full, open findings included">
            Because a protocol that custodies capital against legal claims
            should be reviewable before it is trusted. Most of these are
            internal engineering reviews, which are <em>not</em> a substitute
            for external audit. Reviews conducted by a party other than Forest
            Road are labelled external on their own page, and the limits of any
            engagement should be read alongside its findings. No review here by
            itself authorizes a mainnet launch. Nothing on this page is a
            securities-law representation; token characterization is a matter
            for counsel.
          </HighlightBox>
        </div>
      </Section>

      {/* ── External review, separated. The distinction between an outside
             engagement and an internal round is the one a reader most needs
             to see, so it does not sit in the same list. ────────────────── */}
      {external.length > 0 ? (
        <Section tone="light">
          <SectionHead
            title={
              external.length === 1
                ? "One review conducted by a party other than Forest Road."
                : "Reviews conducted by a party other than Forest Road."
            }
            lede="An outside engagement carries weight an internal round cannot. Its stated scope and methodological limits remain part of the evidence and are published alongside the findings."
          />
          {/* A single outside engagement fills the row and splits internally,
              rather than sitting as one narrow card beside dead space. */}
          <div
            className={`mt-12 grid gap-6 ${
              external.length > 1 ? "lg:grid-cols-2" : ""
            }`}
          >
            {external.map((a) => {
              const solo = external.length === 1;
              return (
                <Link
                  key={a.slug}
                  href={`/docs/audit/${a.slug}`}
                  className={`panel panel-hover group flex h-full p-8 ${
                    solo ? "flex-col gap-8 lg:flex-row lg:gap-16" : "flex-col"
                  }`}
                >
                  <div className={solo ? "lg:w-[3.4in] lg:flex-none" : ""}>
                    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-2">
                      <span className="running-head text-accent">
                        {a.dateLabel}
                      </span>
                      <span className="running-head rounded-pill bg-navy px-2.5 py-[3px] text-on-navy">
                        {a.eyebrow}
                      </span>
                    </div>
                    <h2 className="display mt-5 text-[24px] leading-tight transition-colors group-hover:text-accent">
                      {a.title}
                    </h2>
                    <div
                      className={`flex flex-wrap items-center gap-x-4 gap-y-2 ${
                        solo ? "mt-7" : "hidden"
                      }`}
                    >
                      <SeverityMix findings={a.findings} />
                    </div>
                    <span
                      className={`text-[12.5px] font-medium text-accent transition-transform group-hover:translate-x-0.5 ${
                        solo ? "mt-5 inline-block" : "hidden"
                      }`}
                    >
                      Read the report →
                    </span>
                  </div>

                  <div className="flex-1">
                    <p className="max-w-[64ch] text-[14px] leading-relaxed text-ink-muted">
                      {a.summary}
                    </p>
                    {solo ? null : (
                      <div className="mt-auto flex flex-wrap items-center gap-x-4 gap-y-2 pt-7">
                        <SeverityMix findings={a.findings} />
                        <span className="text-[12.5px] font-medium text-accent transition-transform group-hover:translate-x-0.5">
                          Read the report →
                        </span>
                      </div>
                    )}
                  </div>
                </Link>
              );
            })}
          </div>
        </Section>
      ) : null}

      {/* ── The internal programme, as a dated register. ────────────────── */}
      <Section tone="surface">
        <SectionHead
          title={
            <>
              {internal.length} internal rounds,{" "}
              <span className="display-accent">newest first.</span>
            </>
          }
          lede="Internal engineering reviews do not substitute for external audit. They are published on the same terms — every finding, every severity, every disposition."
        />

        <div className="mt-14">
          {internal.map((a, i) => (
            <Link
              key={a.slug}
              href={`/docs/audit/${a.slug}`}
              className={`group flex flex-col gap-4 py-7 transition-colors hover:bg-raised lg:flex-row lg:gap-12 ${
                i === 0 ? "border-t border-line-strong" : "border-t border-row"
              }`}
            >
              <div className="flex-none lg:w-[2.6in]">
                <span className="running-head block text-accent">
                  {a.eyebrow}
                </span>
                <span className="running-head mt-1.5 block">
                  {a.dateLabel}
                </span>
                <div className="mt-3.5">
                  <SeverityMix findings={a.findings} />
                </div>
              </div>

              <div className="flex-1">
                <h2 className="display text-[19px] leading-tight transition-colors group-hover:text-accent">
                  {a.title}
                </h2>
                <p className="mt-2.5 text-[14px] leading-relaxed text-ink-muted">
                  {a.summary}
                </p>
              </div>

              <span className="flex-none text-[12.5px] font-medium text-accent transition-transform group-hover:translate-x-0.5">
                Read →
              </span>
            </Link>
          ))}
        </div>
      </Section>
    </PageShell>
  );
}
