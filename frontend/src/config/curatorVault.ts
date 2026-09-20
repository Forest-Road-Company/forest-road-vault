/**
 * Curator subscription vault (Solana) configuration for the /curators page.
 *
 * Nothing here is inferred. The program id, the mint and the cluster come from build-time
 * environment variables; when they are absent the page renders the programme copy and the
 * register-interest form and no wallet surface at all. Devnet is the only cluster wired until
 * the mainnet ceremony (spec section 12).
 */

export type CuratorVaultCluster = "devnet" | "mainnet-beta";

const cluster = process.env.NEXT_PUBLIC_CURATOR_VAULT_CLUSTER;
const programId = process.env.NEXT_PUBLIC_CURATOR_VAULT_PROGRAM_ID;
const mint = process.env.NEXT_PUBLIC_CURATOR_VAULT_MINT;
const rpcUrl = process.env.NEXT_PUBLIC_SOLANA_RPC_URL;

if (cluster && cluster !== "devnet" && cluster !== "mainnet-beta") {
  throw new Error("NEXT_PUBLIC_CURATOR_VAULT_CLUSTER must be devnet or mainnet-beta");
}

export const CURATOR_VAULT = {
  /** True when every variable the wallet surface needs is present. */
  configured: Boolean(cluster && programId && mint),
  cluster: (cluster ?? "devnet") as CuratorVaultCluster,
  isDevnet: cluster !== "mainnet-beta",
  programId: programId ?? "",
  mint: mint ?? "",
  rpcUrl:
    rpcUrl ?? (cluster === "mainnet-beta" ? "https://api.mainnet-beta.solana.com" : "https://api.devnet.solana.com"),
  /** USDC has six decimals on Solana; the devnet test mint is created with six as well. */
  decimals: 6,
  explorer: (address: string) =>
    `https://explorer.solana.com/address/${address}${cluster === "mainnet-beta" ? "" : "?cluster=devnet"}`,
  explorerTx: (sig: string) =>
    `https://explorer.solana.com/tx/${sig}${cluster === "mainnet-beta" ? "" : "?cluster=devnet"}`,
} as const;
