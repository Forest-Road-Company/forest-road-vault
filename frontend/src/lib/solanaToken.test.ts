// @vitest-environment node

import {PublicKey, SystemProgram} from "@solana/web3.js";
import {describe, expect, it} from "vitest";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  createAssociatedTokenAccountIdempotentInstruction,
  getAssociatedTokenAddressSync,
  TOKEN_PROGRAM_ID,
} from "./solanaToken";

const MAINNET_USDC = new PublicKey("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
const OWNER = SystemProgram.programId;
const EXPECTED_ATA = "HJt8Tjdsc9ms9i4WCZEzhzr4oyf3ANcdzXrNdLPFqm3M";

describe("Solana token helpers", () => {
  it("derives the canonical associated account for a fixed mainnet USDC vector", () => {
    expect(getAssociatedTokenAddressSync(MAINNET_USDC, OWNER, true).toBase58()).toBe(
      EXPECTED_ATA,
    );
  });

  it("refuses an off-curve owner unless the caller explicitly permits it", () => {
    const offCurveOwner = PublicKey.findProgramAddressSync(
      [Buffer.from("off-curve-owner")],
      ASSOCIATED_TOKEN_PROGRAM_ID,
    )[0];
    expect(() => getAssociatedTokenAddressSync(MAINNET_USDC, offCurveOwner)).toThrow(
      "owner is off curve",
    );
    expect(() => getAssociatedTokenAddressSync(MAINNET_USDC, offCurveOwner, true)).not.toThrow();
  });

  it("builds the canonical idempotent associated-account instruction", () => {
    const ata = new PublicKey(EXPECTED_ATA);
    const instruction = createAssociatedTokenAccountIdempotentInstruction(
      OWNER,
      ata,
      OWNER,
      MAINNET_USDC,
    );

    expect(instruction.programId.equals(ASSOCIATED_TOKEN_PROGRAM_ID)).toBe(true);
    expect([...instruction.data]).toEqual([1]);
    expect(
      instruction.keys.map(({pubkey, isSigner, isWritable}) => ({
        key: pubkey.toBase58(),
        isSigner,
        isWritable,
      })),
    ).toEqual([
      {key: OWNER.toBase58(), isSigner: true, isWritable: true},
      {key: EXPECTED_ATA, isSigner: false, isWritable: true},
      {key: OWNER.toBase58(), isSigner: false, isWritable: false},
      {key: MAINNET_USDC.toBase58(), isSigner: false, isWritable: false},
      {key: SystemProgram.programId.toBase58(), isSigner: false, isWritable: false},
      {key: TOKEN_PROGRAM_ID.toBase58(), isSigner: false, isWritable: false},
    ]);
  });
});
