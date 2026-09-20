import assert from "node:assert/strict";
import test from "node:test";
import {Keypair, PublicKey, SystemProgram} from "@solana/web3.js";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  associatedTokenAddress,
  createAssociatedTokenInstruction,
  initializeMint2Instruction,
  mintToInstruction,
  TOKEN_PROGRAM_ID,
} from "./token-client.js";

const mint = new PublicKey("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
const owner = SystemProgram.programId;

test("derives and builds the canonical associated-account instruction", () => {
  const account = associatedTokenAddress(mint, owner);
  assert.equal(account.toBase58(), "HJt8Tjdsc9ms9i4WCZEzhzr4oyf3ANcdzXrNdLPFqm3M");
  const ix = createAssociatedTokenInstruction(owner, mint, owner);
  assert(ix.programId.equals(ASSOCIATED_TOKEN_PROGRAM_ID));
  assert.deepEqual([...ix.data], [1]);
  assert.deepEqual(
    ix.keys.map((key) => [key.pubkey.toBase58(), key.isSigner, key.isWritable]),
    [
      [owner.toBase58(), true, true],
      [account.toBase58(), false, true],
      [owner.toBase58(), false, false],
      [mint.toBase58(), false, false],
      [SystemProgram.programId.toBase58(), false, false],
      [TOKEN_PROGRAM_ID.toBase58(), false, false],
    ],
  );
});

test("encodes InitializeMint2 and MintTo with exact classic SPL tags and fields", () => {
  const authority = Keypair.generate().publicKey;
  const init = initializeMint2Instruction(mint, 6, authority, null);
  assert.equal(init.data.length, 70);
  assert.equal(init.data[0], 20);
  assert.equal(init.data[1], 6);
  assert.deepEqual(init.data.subarray(2, 34), authority.toBuffer());
  assert.equal(init.data.readUInt32LE(34), 0);

  const destination = Keypair.generate().publicKey;
  const mintTo = mintToInstruction(mint, destination, authority, 12_345_678n);
  assert.equal(mintTo.data[0], 7);
  assert.equal(mintTo.data.readBigUInt64LE(1), 12_345_678n);
  assert.deepEqual(
    mintTo.keys.map((key) => [key.isSigner, key.isWritable]),
    [[false, true], [false, true], [true, false]],
  );
});

test("refuses token amounts outside u64", () => {
  const key = Keypair.generate().publicKey;
  assert.throws(() => mintToInstruction(mint, key, owner, -1n), /fit in u64/);
  assert.throws(
    () => mintToInstruction(mint, key, owner, 0x1_0000_0000_0000_0000n),
    /fit in u64/,
  );
});
