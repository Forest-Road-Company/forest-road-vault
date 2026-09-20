import {
  Connection,
  Keypair,
  PublicKey,
  sendAndConfirmTransaction,
  SystemProgram,
  Transaction,
  TransactionInstruction,
  type Signer,
} from "@solana/web3.js";

export const TOKEN_PROGRAM_ID = new PublicKey(
  "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
);
export const ASSOCIATED_TOKEN_PROGRAM_ID = new PublicKey(
  "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL",
);
export const MINT_SIZE = 82;
export const TOKEN_ACCOUNT_SIZE = 165;

export function associatedTokenAddress(mint: PublicKey, owner: PublicKey): PublicKey {
  return PublicKey.findProgramAddressSync(
    [owner.toBuffer(), TOKEN_PROGRAM_ID.toBuffer(), mint.toBuffer()],
    ASSOCIATED_TOKEN_PROGRAM_ID,
  )[0];
}

export function initializeMint2Instruction(
  mint: PublicKey,
  decimals: number,
  mintAuthority: PublicKey,
  freezeAuthority: PublicKey | null,
): TransactionInstruction {
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 255) {
    throw new Error("mint decimals must fit in u8");
  }
  // SPL TokenInstruction::InitializeMint2 = 20. COption<Pubkey> is a u32 tag plus 32 bytes.
  const data = Buffer.alloc(70);
  data[0] = 20;
  data[1] = decimals;
  mintAuthority.toBuffer().copy(data, 2);
  data.writeUInt32LE(freezeAuthority ? 1 : 0, 34);
  if (freezeAuthority) freezeAuthority.toBuffer().copy(data, 38);
  return new TransactionInstruction({
    programId: TOKEN_PROGRAM_ID,
    keys: [{pubkey: mint, isSigner: false, isWritable: true}],
    data,
  });
}

export function createAssociatedTokenInstruction(
  payer: PublicKey,
  mint: PublicKey,
  owner: PublicKey,
): TransactionInstruction {
  const associated = associatedTokenAddress(mint, owner);
  return new TransactionInstruction({
    programId: ASSOCIATED_TOKEN_PROGRAM_ID,
    keys: [
      {pubkey: payer, isSigner: true, isWritable: true},
      {pubkey: associated, isSigner: false, isWritable: true},
      {pubkey: owner, isSigner: false, isWritable: false},
      {pubkey: mint, isSigner: false, isWritable: false},
      {pubkey: SystemProgram.programId, isSigner: false, isWritable: false},
      {pubkey: TOKEN_PROGRAM_ID, isSigner: false, isWritable: false},
    ],
    // Associated Token instruction 1 is CreateIdempotent.
    data: Buffer.from([1]),
  });
}

export function mintToInstruction(
  mint: PublicKey,
  destination: PublicKey,
  authority: PublicKey,
  amount: bigint,
): TransactionInstruction {
  if (amount < 0n || amount > 0xffff_ffff_ffff_ffffn) {
    throw new Error("mint amount must fit in u64");
  }
  // SPL TokenInstruction::MintTo = 7.
  const data = Buffer.alloc(9);
  data[0] = 7;
  data.writeBigUInt64LE(amount, 1);
  return new TransactionInstruction({
    programId: TOKEN_PROGRAM_ID,
    keys: [
      {pubkey: mint, isSigner: false, isWritable: true},
      {pubkey: destination, isSigner: false, isWritable: true},
      {pubkey: authority, isSigner: true, isWritable: false},
    ],
    data,
  });
}

async function send(
  connection: Connection,
  payer: Keypair,
  instructions: TransactionInstruction[],
  signers: Signer[] = [],
): Promise<string> {
  return sendAndConfirmTransaction(
    connection,
    new Transaction().add(...instructions),
    [payer, ...signers],
    {commitment: "finalized"},
  );
}

export async function createTestMint(
  connection: Connection,
  payer: Keypair,
  mintAuthority: PublicKey,
  decimals: number,
): Promise<{mint: PublicKey; signature: string}> {
  const mint = Keypair.generate();
  const lamports = await connection.getMinimumBalanceForRentExemption(MINT_SIZE);
  const signature = await send(
    connection,
    payer,
    [
      SystemProgram.createAccount({
        fromPubkey: payer.publicKey,
        newAccountPubkey: mint.publicKey,
        lamports,
        space: MINT_SIZE,
        programId: TOKEN_PROGRAM_ID,
      }),
      initializeMint2Instruction(mint.publicKey, decimals, mintAuthority, null),
    ],
    [mint],
  );
  return {mint: mint.publicKey, signature};
}

export async function ensureAssociatedTokenAccount(
  connection: Connection,
  payer: Keypair,
  mint: PublicKey,
  owner: PublicKey,
): Promise<{account: PublicKey; signature: string | null}> {
  const account = associatedTokenAddress(mint, owner);
  if (await connection.getAccountInfo(account, "finalized")) return {account, signature: null};
  const signature = await send(connection, payer, [
    createAssociatedTokenInstruction(payer.publicKey, mint, owner),
  ]);
  return {account, signature};
}

export async function mintToAccount(
  connection: Connection,
  payer: Keypair,
  mint: PublicKey,
  destination: PublicKey,
  authority: Keypair,
  amount: bigint,
): Promise<string> {
  const extra = payer.publicKey.equals(authority.publicKey) ? [] : [authority];
  return send(
    connection,
    payer,
    [mintToInstruction(mint, destination, authority.publicKey, amount)],
    extra,
  );
}

export async function tokenAmount(
  connection: Connection,
  account: PublicKey,
  expectedMint: PublicKey,
  expectedOwner?: PublicKey,
): Promise<bigint> {
  const info = await connection.getAccountInfo(account, "finalized");
  if (!info || !info.owner.equals(TOKEN_PROGRAM_ID) || info.data.length !== TOKEN_ACCOUNT_SIZE) {
    throw new Error(`invalid classic SPL token account ${account.toBase58()}`);
  }
  if (!new PublicKey(info.data.subarray(0, 32)).equals(expectedMint)) {
    throw new Error(`wrong mint for token account ${account.toBase58()}`);
  }
  if (expectedOwner && !new PublicKey(info.data.subarray(32, 64)).equals(expectedOwner)) {
    throw new Error(`wrong owner for token account ${account.toBase58()}`);
  }
  return info.data.readBigUInt64LE(64);
}
