"use client";

/**
 * Client-side providers for wallet + on-chain reads. Mounted once in the root
 * layout; server components stay server-rendered and only leaf client components
 * (connect control, write cards, live stats) consume these contexts.
 */

import {useState, type ReactNode} from "react";
import {WagmiProvider} from "wagmi";
import {QueryClient, QueryClientProvider} from "@tanstack/react-query";
import {wagmiConfig} from "@/lib/wagmi";

export function Providers({children}: {children: ReactNode}) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            // On-chain reads: staleTime keeps bursts cheap; refetch-on-focus makes
            // returning to the tab show current chain state (multicall-batched).
            staleTime: 15_000,
            refetchOnWindowFocus: true,
          },
        },
      }),
  );

  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
