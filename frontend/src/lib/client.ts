/** Read-only viem client for the single chain selected at build time. */

import {createPublicClient, type PublicClient} from "viem";
import {appTransport} from "@/lib/appRpc";
import {EXPECTED_CHAIN} from "@/lib/chain";

let cached: PublicClient | undefined;

/** Lazily-built public client on the build's read transport (the same-origin proxy on mainnet). */
export function publicClient(): PublicClient {
    if (cached) return cached;
    cached = createPublicClient({
        chain: EXPECTED_CHAIN,
        transport: appTransport(),
    });
    return cached;
}
