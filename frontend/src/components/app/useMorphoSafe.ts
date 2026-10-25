"use client";

import {useEffect, useState} from "react";
import type SafeAppsSDK from "@safe-global/safe-apps-sdk";
import {isAddress, type Address} from "viem";

export function useMorphoSafe() {
  const [context, setContext] = useState<{sdk: SafeAppsSDK; address: Address; chainId: number; threshold: number; owners: string[]} | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (window.parent === window) return;
    let alive = true;
    const timer = setTimeout(() => {
      if (alive) setError("The Safe connection is unavailable. Open this page from app.safe.global.");
    }, 8_000);
    void import("@safe-global/safe-apps-sdk").then(async ({default: SDK}) => {
      const sdk = new SDK({allowedDomains: [/^https:\/\/app\.safe\.global$/], debug: false});
      const info = await sdk.safe.getInfo();
      if (!isAddress(info.safeAddress) || info.chainId !== 1 || !Number.isSafeInteger(info.threshold) || info.threshold < 1
        || !Array.isArray(info.owners) || info.threshold > info.owners.length || !info.owners.every(owner => isAddress(owner))) throw new Error("Use an Ethereum Safe.");
      if (alive) {clearTimeout(timer); setError(null); setContext({sdk, address: info.safeAddress, chainId: info.chainId, threshold: info.threshold, owners: info.owners});}
    }).catch(() => {
      if (alive) {clearTimeout(timer); setError("Connect an Ethereum Safe through app.safe.global.");}
    });
    return () => {alive = false; clearTimeout(timer);};
  }, []);
  return {context, error};
}
