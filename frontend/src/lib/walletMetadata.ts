const CANONICAL_ORIGIN = "https://forestroadvault.com";

function appOrigin(explicit?: string): string {
  const candidate = explicit
    ?? (typeof window === "undefined" ? process.env.NEXT_PUBLIC_APP_ORIGIN : window.location.origin)
    ?? CANONICAL_ORIGIN;
  // Sandboxed and file-backed documents expose the opaque origin as the literal string `null`.
  // Wallet discovery should still render there; the canonical HTTPS origin is the only useful
  // metadata value until the page is opened from a normal web origin.
  if (candidate === "null") return CANONICAL_ORIGIN;
  const parsed = new URL(candidate);
  if ((parsed.protocol !== "https:" && parsed.protocol !== "http:") || parsed.username || parsed.password) {
    throw new Error("Wallet metadata origin must be an HTTP(S) origin");
  }
  return parsed.origin;
}

/** WalletConnect displays and validates this metadata against the page making the request. */
export function walletMetadata(origin?: string) {
  const url = appOrigin(origin);
  return {
    name: "Forest Road Vault",
    description: "On-chain access to Forest Road's private-credit vault.",
    url,
    icons: [`${url}/favicon.ico`],
  };
}
