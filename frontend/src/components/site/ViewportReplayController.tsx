"use client";

import { useEffect } from "react";

const TARGET = "[data-viewport-replay]";
const OBSERVED = "data-viewport-observed";
const VISIBLE = "data-viewport-visible";

/**
 * Replays authored foreground motion when a substantial visual enters the
 * viewport. Leaving the viewport removes the running animation, which resets
 * it; entering again starts it from the first frame. The page-level ambient
 * backdrop deliberately sits outside this system and remains continuous.
 */
export function ViewportReplayController() {
  useEffect(() => {
    const targets = new Set<Element>();
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
    const canObserve = "IntersectionObserver" in window;

    const observer = canObserve
      ? new IntersectionObserver(
          (entries) => {
            for (const entry of entries) {
              entry.target.toggleAttribute(VISIBLE, entry.isIntersecting);
            }
          },
          {
            // Start shortly after the visual reaches the viewport and reset
            // only after it leaves the readable central band completely.
            rootMargin: "-8% 0px -8% 0px",
            threshold: 0,
          },
        )
      : null;

    const register = (target: Element) => {
      if (targets.has(target)) return;
      targets.add(target);
      target.setAttribute(OBSERVED, "");

      if (reducedMotion.matches || !observer) {
        target.setAttribute(VISIBLE, "");
        return;
      }

      // Removing the class before observation gives every newly mounted
      // target a clean first frame, including data-driven panels.
      target.removeAttribute(VISIBLE);
      if (document.visibilityState === "visible") observer.observe(target);
    };

    const unregister = (target: Element) => {
      if (!targets.delete(target)) return;
      observer?.unobserve(target);
      target.removeAttribute(OBSERVED);
      target.removeAttribute(VISIBLE);
    };

    const visit = (root: ParentNode, action: (target: Element) => void) => {
      if (root instanceof Element && root.matches(TARGET)) action(root);
      root.querySelectorAll(TARGET).forEach(action);
    };

    visit(document, register);

    const mutations =
      "MutationObserver" in window
        ? new MutationObserver((records) => {
            for (const record of records) {
              record.addedNodes.forEach((node) => {
                if (node instanceof Element) visit(node, register);
              });
              record.removedNodes.forEach((node) => {
                if (node instanceof Element) visit(node, unregister);
              });
            }
          })
        : null;

    mutations?.observe(document.body, { childList: true, subtree: true });

    const refreshObservations = () => {
      for (const target of targets) {
        if (reducedMotion.matches || !observer) {
          observer?.unobserve(target);
          target.setAttribute(VISIBLE, "");
        } else {
          observer.unobserve(target);
          target.removeAttribute(VISIBLE);
          if (document.visibilityState === "visible") observer.observe(target);
        }
      }
    };

    reducedMotion.addEventListener("change", refreshObservations);
    document.addEventListener("visibilitychange", refreshObservations);

    return () => {
      mutations?.disconnect();
      observer?.disconnect();
      reducedMotion.removeEventListener("change", refreshObservations);
      document.removeEventListener("visibilitychange", refreshObservations);
      targets.forEach((target) => {
        target.removeAttribute(OBSERVED);
        target.removeAttribute(VISIBLE);
      });
      targets.clear();
    };
  }, []);

  return null;
}
