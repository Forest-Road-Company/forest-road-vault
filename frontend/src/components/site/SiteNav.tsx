"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";

/* Risk is deliberately not in the top nav. It stays reachable from the footer
   and from the landing page's closing action, both of which point at it. */
const links = [
  { href: "/how-it-works", label: "How it works" },
  { href: "/sectors", label: "Sectors" },
  { href: "/transparency", label: "Transparency" },
  { href: "/docs", label: "Docs" },
  { href: "/points", label: "Points" },
] as const;

export function SiteNav() {
  const pathname = usePathname();
  const isAppRoute = pathname === "/app" || pathname.startsWith("/app/");
  const [open, setOpen] = useState(false);

  /* The panel must not leave the page scrollable underneath it. Closing on
     navigation is handled by the links themselves rather than by an effect on
     pathname: a tap on the current route changes no pathname, so an effect
     would leave the overlay open on exactly that case. */
  useEffect(() => {
    document.body.style.overflow = open ? "hidden" : "";
    return () => {
      document.body.style.overflow = "";
    };
  }, [open]);

  const isActive = (href: string) =>
    pathname === href || pathname.startsWith(`${href}/`);

  return (
    <header className="sticky top-0 z-40 border-b border-line bg-bg/88 backdrop-blur-xl">
      <nav className="mx-auto flex h-16 max-w-6xl items-center justify-between gap-6 px-5">
        <Link
          href="/"
          onClick={() => setOpen(false)}
          className="flex flex-none items-center gap-2.5"
        >
          <Image
            src="/brand/fram-mark-navy.png"
            alt=""
            width={220}
            height={187}
            priority
            className="h-7 w-auto"
          />
          <span className="flex items-baseline gap-1.5">
            <span className="text-[15.5px] font-semibold tracking-[-0.01em] text-ink">
              Forest Road
            </span>
            <span className="text-[10.5px] font-semibold uppercase tracking-[0.16em] text-accent">
              Vault
            </span>
          </span>
        </Link>

        <div className="hidden items-center gap-7 lg:flex">
          {links.map((l) => {
            const active = isActive(l.href);
            return (
              <Link
                key={l.href}
                href={l.href}
                aria-current={active ? "page" : undefined}
                className={`relative py-1 text-[13.5px] transition-colors ${
                  active
                    ? "font-medium text-ink"
                    : "text-ink-muted hover:text-ink"
                }`}
              >
                {l.label}
                {active ? (
                  <span className="absolute -bottom-[3px] left-0 h-[1.5px] w-full bg-accent" />
                ) : null}
              </Link>
            );
          })}
        </div>

        <div className="flex flex-none items-center gap-2">
          {isAppRoute ? null : (
            <Link
              href="/app"
              onClick={() => setOpen(false)}
              className="rounded-pill bg-navy px-4 py-1.5 text-[13px] font-semibold text-on-navy transition-colors hover:bg-navy-raised"
            >
              Enter App
            </Link>
          )}
          <button
            type="button"
            onClick={() => setOpen((v) => !v)}
            aria-expanded={open}
            aria-controls="site-menu"
            aria-label={open ? "Close menu" : "Open menu"}
            /* The button is the 44px target — the one control a thumb reaches
               for before anything has been read, so it takes the enhanced size
               rather than the 24px minimum. The bordered box inside stays 36px,
               so the nav looks exactly as it did; only the hit area grew. */
            className="group -mr-1 flex h-11 w-11 items-center justify-center lg:hidden"
          >
            <span className="flex h-9 w-9 items-center justify-center rounded-md border border-line-strong text-ink transition-colors group-hover:bg-surface">
              <svg
                width="16"
                height="16"
                viewBox="0 0 16 16"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.5"
                strokeLinecap="round"
                aria-hidden
              >
                {open ? (
                  <>
                    <path d="M3.5 3.5l9 9" />
                    <path d="M12.5 3.5l-9 9" />
                  </>
                ) : (
                  <>
                    <path d="M2 4.5h12" />
                    <path d="M2 11.5h12" />
                  </>
                )}
              </svg>
            </span>
          </button>
        </div>
      </nav>

      {open ? (
        <div
          id="site-menu"
          className="border-t border-line bg-bg lg:hidden"
        >
          <div className="mx-auto max-w-6xl px-5 py-3">
            {links.map((l) => {
              const active = isActive(l.href);
              return (
                <Link
                  key={l.href}
                  href={l.href}
                  onClick={() => setOpen(false)}
                  aria-current={active ? "page" : undefined}
                  className={`flex items-center justify-between border-b border-row py-3 text-[15px] last:border-b-0 ${
                    active ? "font-medium text-ink" : "text-ink-muted"
                  }`}
                >
                  {l.label}
                  {active ? (
                    <span className="h-1.5 w-1.5 rounded-full bg-accent" />
                  ) : null}
                </Link>
              );
            })}
          </div>
        </div>
      ) : null}
    </header>
  );
}
