import {describe, expect, it} from "vitest";
import {resolveVaultFeeAbi} from "./vaultFeeAbi";

const LEGACY_VAULT = "0xC6A6631f3434d08CBB98705076Fe8Fb22fdC268A";
const CURRENT_VAULT = "0x197bb3701e964bfb367449a6754C845Fc8f7d0F4";

describe("vault fee ABI configuration", () => {
  it("defaults the committed vault to ADR-0031", () => {
    expect(resolveVaultFeeAbi({isMainnet: false})).toEqual({
      version: "1",
      supportsFeeAccounting: true,
    });
  });

  it("requires an explicit address for ABI version 0", () => {
    expect(() =>
      resolveVaultFeeAbi({isMainnet: false, configuredVersion: "0"}),
    ).toThrow("requires an explicit legacy NEXT_PUBLIC_SUSDFR_ADDRESS");
  });

  it("accepts the known legacy vault only with explicit version 0", () => {
    expect(
      resolveVaultFeeAbi({
        isMainnet: false,
        configuredVersion: "0",
        configuredVaultAddress: LEGACY_VAULT,
      }),
    ).toEqual({version: "0", supportsFeeAccounting: false});

    expect(() =>
      resolveVaultFeeAbi({
        isMainnet: false,
        configuredVersion: "1",
        configuredVaultAddress: LEGACY_VAULT,
      }),
    ).toThrow("known legacy sUSDfr address");
  });

  it("never lets an explicit vault inherit the version default", () => {
    expect(() =>
      resolveVaultFeeAbi({
        isMainnet: false,
        configuredVaultAddress: LEGACY_VAULT,
      }),
    ).toThrow("is required whenever NEXT_PUBLIC_SUSDFR_ADDRESS is set");
  });

  it("rejects version 0 for the known ADR-0031 vault", () => {
    expect(() =>
      resolveVaultFeeAbi({
        isMainnet: false,
        configuredVersion: "0",
        configuredVaultAddress: CURRENT_VAULT,
      }),
    ).toThrow("known ADR-0031 sUSDfr address");
  });

  it("requires ADR-0031 on mainnet", () => {
    expect(() =>
      resolveVaultFeeAbi({
        isMainnet: true,
        configuredVersion: "0",
        configuredVaultAddress: LEGACY_VAULT,
      }),
    ).toThrow("must be 1 for mainnet");
  });

  it("rejects invalid version labels", () => {
    expect(() =>
      resolveVaultFeeAbi({isMainnet: false, configuredVersion: "2"}),
    ).toThrow("must be 0 (legacy) or 1 (ADR-0031)");
  });
});
