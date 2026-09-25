# Corrovera review of the Solana curator vault

## Result

The review and its two remediation verifications closed the four confirmed Medium source and
test-assurance findings. The final package also corrected the notice/draw regression introduced by
the first remediation. No High or Medium program-source or test-assurance finding remains in the
current devnet release.

This result applies to the Solana curator vault and its website paths. It does not review the
Ethereum V2 credit contracts, and it does not authorize Solana mainnet deployment.

## Evidence that changed the verdict

The final package added field-level decoding for every event, a complete instruction/error/event
surface census, a stateful campaign that records every result and reaches real withdrawals, and
compiled mutation controls that also make the campaign fail. The release build pins its container,
Solana version, SBF architecture and platform tools.

The canonical 475,824-byte ELF has SHA-256
`c3f365f888cda2daf06bbf8339c7e8ea89cd090b2dac030367f346e78f3b450e`. It is active on devnet at
program `3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh`, and the verifier matched the deployed
ProgramData bytes and published IDL exactly. State accounts remained byte-identical across the
artifact activation.

## Remaining boundary

The production Vercel release must expose and verify its exact commit on every promotion. Solana
mainnet still requires counsel approval, a reviewed 2-of-4 Squads, a separately chosen emergency
signer, specialist Solana review and a human deployment ceremony.
