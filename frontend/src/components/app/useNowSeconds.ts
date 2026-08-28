"use client";

/**
 * Wall-clock seconds as React state: null until mounted (so SSR/hydration render
 * a stable ", "), then ticking on an interval. Exists because calling Date.now()
 * during render is impure (react-hooks/purity) and can mismatch hydration.
 */

import {useEffect, useState} from "react";

export function useNowSeconds(intervalMs = 30_000): number | null {
  const [now, setNow] = useState<number | null>(null);
  useEffect(() => {
    const update = () => setNow(Math.floor(Date.now() / 1000));
    update();
    const id = setInterval(update, intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}
