export type VaultFeeAbiVersion = "0" | "1";

const LEGACY_VAULTS = new Set([
  // Archived pre-ADR-0031 Sepolia deployment.
  "0xc6a6631f3434d08cbb98705076fe8fb22fdc268a",
]);

const ADR_0031_VAULTS = new Set([
  // Canonical Ethereum mainnet deployment (mainnet-v1, block 25768251, manifest
  // 1-production-v1.json). Pinned by address so a mainnet build cannot be pointed at
  // this vault while declaring the pre-ADR-0031 fee ABI.
  "0x4761995f4f6daddf7886acd9d16e119ef2fb4132",
  // Canonical Sepolia deployment.
  "0x197bb3701e964bfb367449a6754c845fc8f7d0f4",
  // Canonical local deployment manifest.
  "0xfae80c13d4311d389b7a63dcd10b67c2b897b896",
]);

type VaultFeeAbiConfig = {
  isMainnet: boolean;
  configuredVersion?: string;
  configuredVaultAddress?: string;
};

/**
 * Resolve the vault ABI version without allowing an explicit address to inherit an
 * unrelated default. Known historical/current addresses are checked in both directions;
 * unknown test deployments must still state their version explicitly.
 */
export function resolveVaultFeeAbi({
  isMainnet,
  configuredVersion,
  configuredVaultAddress,
}: VaultFeeAbiConfig): {version: VaultFeeAbiVersion; supportsFeeAccounting: boolean} {
  const hasExplicitVault = Boolean(configuredVaultAddress);
  if (hasExplicitVault && configuredVersion === undefined) {
    throw new Error(
      "NEXT_PUBLIC_SUSDFR_FEE_ABI_VERSION is required whenever NEXT_PUBLIC_SUSDFR_ADDRESS is set.",
    );
  }

  const version = configuredVersion ?? "1";
  if (version !== "0" && version !== "1") {
    throw new Error(
      "NEXT_PUBLIC_SUSDFR_FEE_ABI_VERSION must be 0 (legacy) or 1 (ADR-0031).",
    );
  }
  if (isMainnet && version !== "1") {
    throw new Error("NEXT_PUBLIC_SUSDFR_FEE_ABI_VERSION must be 1 for mainnet.");
  }
  if (version === "0" && !hasExplicitVault) {
    throw new Error(
      "NEXT_PUBLIC_SUSDFR_FEE_ABI_VERSION=0 requires an explicit legacy NEXT_PUBLIC_SUSDFR_ADDRESS.",
    );
  }

  const normalizedVault = configuredVaultAddress?.toLowerCase();
  if (normalizedVault && LEGACY_VAULTS.has(normalizedVault) && version !== "0") {
    throw new Error(
      "The known legacy sUSDfr address requires NEXT_PUBLIC_SUSDFR_FEE_ABI_VERSION=0.",
    );
  }
  if (normalizedVault && ADR_0031_VAULTS.has(normalizedVault) && version !== "1") {
    throw new Error(
      "The known ADR-0031 sUSDfr address requires NEXT_PUBLIC_SUSDFR_FEE_ABI_VERSION=1.",
    );
  }

  return {version, supportsFeeAccounting: version === "1"};
}
