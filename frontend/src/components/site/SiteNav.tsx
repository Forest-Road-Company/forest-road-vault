"use client";

import Link from "next/link";
import {usePathname} from "next/navigation";

const links = [
  { href: "/how-it-works", label: "How it works" },
  { href: "/verticals", label: "Verticals" },
  { href: "/transparency", label: "Transparency" },
  { href: "/docs", label: "Docs" },
  { href: "/points", label: "Points" },
] as const;

export function SiteNav() {
  const pathname = usePathname();
  const isAppRoute = pathname === "/app" || pathname.startsWith("/app/");

  return (
    <header className="sticky top-0 z-40 border-b border-line bg-raised/95 shadow-[0_1px_12px_rgba(20,37,48,0.06)] backdrop-blur-lg">
      <nav className="mx-auto flex h-16 max-w-6xl items-center justify-between px-5">
        <Link href="/" className="group flex items-baseline gap-2">
          <span className="font-grotesk text-[17px] font-semibold tracking-tight text-ink">
            Forest Road
          </span>
          <span className="font-mono text-[11px] uppercase tracking-[0.18em] text-moss">
            Vault
          </span>
        </Link>

        <div className="hidden items-center gap-8 md:flex">
          {links.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              className="text-[13.5px] text-ink-muted transition-colors hover:text-ink"
            >
              {l.label}
            </Link>
          ))}
        </div>

        {isAppRoute ? null : (
          <Link
            href="/app"
            className="rounded-pill border border-moss/40 bg-moss-faint px-4 py-1.5 text-[13px] font-medium text-moss transition-colors hover:border-moss hover:bg-moss/15"
          >
            Enter App
          </Link>
        )}
      </nav>
    </header>
  );
}
