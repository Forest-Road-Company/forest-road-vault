/** Read-only viem client for the single chain selected at build time. */

import {createPublicClient, http, type PublicClient} from "viem";
import {RPC_URL} from "@/config/contracts";
import {EXPECTED_CHAIN} from "@/lib/chain";

let cached: PublicClient | undefined;

/** Lazily-built public client. Mainnet builds require an explicit public RPC. */
export function publicClient(): PublicClient {
    if (cached) return cached;
    cached = createPublicClient({
        chain: EXPECTED_CHAIN,
        transport: http(RPC_URL || undefined),
    });
    return cached;
}
