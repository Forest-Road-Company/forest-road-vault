"use client";

import Image from "next/image";
import Link from "next/link";
import { useSelectedLayoutSegment } from "next/navigation";
import { useEffect, useRef, useState } from "react";

/* Risk is deliberately not in the top nav. It stays reachable from the footer
   and from the landing page's closing action, both of which point at it. */
const links = [
  { href: "/how-it-works", label: "How it works" },
  { href: "/sectors", label: "Sectors" },
  { href: "/transparency", label: "Transparency" },
  { href: "/docs", label: "Docs" },
  { href: "/points", label: "Points" },
  { href: "/markets", label: "Borrow & lend" },
  { href: "/curators", label: "Curators" },
] as const;

export function SiteNav() {
  // Using the selected layout segment instead of usePathname keeps SSR and client
  // hydration identical on statically prerendered 404 routes under known prefixes
  // (e.g. /docs/unknown), and prevents a 404 page from marking a nav section active.
  const segment = useSelectedLayoutSegment();
  const isAppRoute = segment === "app";
  const [open, setOpen] = useState(false);
  const [menuMaxHeight, setMenuMaxHeight] = useState<number | null>(null);
  const headerRef = useRef<HTMLElement | null>(null);
  const barRef = useRef<HTMLDivElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);
  const menuButtonRef = useRef<HTMLButtonElement | null>(null);

  /* The panel must not leave the page scrollable underneath it. Closing on
     navigation is handled by the links themselves rather than by an effect on
     pathname: a tap on the current route changes no pathname, so an effect
     would leave the overlay open on exactly that case. */
  useEffect(() => {
    document.body.style.overflow = open ? "hidden" : "";
    if (!open) {
      return () => {
        document.body.style.overflow = "";
      };
    }
    const desktopQuery =
      typeof window.matchMedia === "function" ? window.matchMedia("(min-width: 1024px)") : null;
    const onViewportChange = (event: MediaQueryListEvent) => {
      if (event.matches) setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setOpen(false);
        menuButtonRef.current?.focus();
        return;
      }
      if (event.key !== "Tab") return;
      const menuLinks = menuRef.current
        ? Array.from(menuRef.current.querySelectorAll<HTMLElement>('a[href], button:not([disabled])')).filter(
            (el) => el.getClientRects().length > 0 && window.getComputedStyle(el).visibility !== "hidden",
          )
        : [];
      const focusables = [menuButtonRef.current, ...menuLinks].filter((el): el is HTMLElement => el !== null);
      if (focusables.length < 2) return;
      const first = focusables[0];
      const last = focusables[focusables.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    const onPointerDown = (event: PointerEvent) => {
      if (headerRef.current && event.target instanceof Node && !headerRef.current.contains(event.target)) {
        setOpen(false);
      }
    };
    const updateMenuHeight = () => {
      const bottom = barRef.current?.getBoundingClientRect().bottom ?? 64;
      const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
      setMenuMaxHeight(Math.max(120, Math.floor(viewportHeight - bottom)));
    };
    updateMenuHeight();
    window.addEventListener("resize", updateMenuHeight);
    window.visualViewport?.addEventListener("resize", updateMenuHeight);
    window.visualViewport?.addEventListener("scroll", updateMenuHeight);
    desktopQuery?.addEventListener("change", onViewportChange);
    window.addEventListener("keydown", onKeyDown);
    document.addEventListener("pointerdown", onPointerDown);
    return () => {
      document.body.style.overflow = "";
      window.removeEventListener("resize", updateMenuHeight);
      window.visualViewport?.removeEventListener("resize", updateMenuHeight);
      window.visualViewport?.removeEventListener("scroll", updateMenuHeight);
      desktopQuery?.removeEventListener("change", onViewportChange);
      window.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("pointerdown", onPointerDown);
    };
  }, [open]);

  const isActive = (href: string) => segment === href.slice(1);

  return (
    <header
      ref={headerRef}
      className="site-nav sticky top-0 z-40 border-b border-line bg-bg/80 backdrop-blur-xl"
      style={{ viewTransitionName: "site-header" }}
    >
      <nav aria-label="Primary">
        <div ref={barRef} className="mx-auto flex h-16 max-w-6xl items-center justify-between gap-3 px-5 sm:gap-6">
        <Link
          href="/"
          onClick={() => setOpen(false)}
          className="flex min-h-11 flex-none items-center py-2"
        >
          {/* The current brand lockup (owner, 11 November 2026): the tree, FOREST ROAD, a rule, VAULT.
              It is tightly cropped (about 13.9:1), so it is sized by width. */}
          <Image
            src="/brand/forest-road-vault-lockup-navy.png"
            alt="Forest Road Vault"
            width={2400}
            height={173}
            sizes="(min-width: 640px) 208px, 168px"
            priority
            className="h-auto w-[168px] sm:w-[208px]"
          />
        </Link>

        <div className="hidden items-center gap-4 lg:flex xl:gap-6">
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
          {/* Below 360px the lockup, the pill and the 44px menu target together
              measured wider than the viewport, and every page scrolled sideways
              by 36px as a result. The pill stands down at that width and the
              menu panel carries the same link, so nothing becomes unreachable. */}
          {isAppRoute ? null : (
            <Link
              href="/app"
              onClick={() => setOpen(false)}
              className="hidden rounded-pill bg-navy px-4 py-1.5 text-[13px] font-semibold text-on-navy transition-colors hover:bg-navy-raised sm:block"
            >
              Enter App
            </Link>
          )}
          <button
            ref={menuButtonRef}
            type="button"
            onClick={() => setOpen((v) => !v)}
            aria-expanded={open}
            aria-controls="site-menu"
            aria-label={open ? "Close menu" : "Open menu"}
            /* The button is the 44px target, the one control a thumb reaches
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
      </div>

      {open ? (
        <div
          ref={menuRef}
          id="site-menu"
          style={menuMaxHeight !== null ? { maxHeight: `${menuMaxHeight}px` } : undefined}
          className="max-h-[calc(100dvh-4rem)] overflow-y-auto overscroll-contain border-t border-line bg-bg lg:hidden"
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
            {isAppRoute ? null : (
              <Link
                href="/app"
                onClick={() => setOpen(false)}
                className="mt-3 flex items-center justify-center rounded-pill bg-navy px-4 py-2.5 text-[15px] font-semibold text-on-navy sm:hidden"
              >
                Enter App
              </Link>
            )}
          </div>
        </div>
      ) : null}
      </nav>
    </header>
  );
}
