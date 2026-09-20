#![allow(clippy::result_large_err)] // LiteSVM's failure type carries the logs; that is the point
//! Lifecycle and invariant tests against the compiled program in LiteSVM: allowlist, deposit,
//! lock and notice, treasury draw and return, monthly coupons across a rate change, loss
//! recognition, withdrawal, close and pause. The accounting, withdrawal and authority properties
//! in the specification are asserted after every state-changing campaign step. Run
//! `anchor build` first; the test loads
//! `target/deploy/forestroad_curator_vault.so`.

use anchor_lang::prelude::borsh::BorshDeserialize;
use anchor_lang::prelude::Pubkey;
use anchor_lang::{
    AccountDeserialize, AccountSerialize, Discriminator, InstructionData, Space, ToAccountMetas,
};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use forestroad_curator_vault::events;
use forestroad_curator_vault::instructions::admin::InitializeParams;
use forestroad_curator_vault::state::{Config, Position};
use forestroad_curator_vault::{accounts as acc, instruction as ix, math, ID as PROGRAM};
use litesvm::types::FailedTransactionMetadata;
use litesvm::LiteSVM;
use litesvm_token::spl_token::instruction::AuthorityType;
use litesvm_token::spl_token::state::Account as TokenAccountState;
use litesvm_token::{
    get_spl_account, CreateAccount as CreateTokenAccount, CreateAssociatedTokenAccount, CreateMint,
    MintTo, SetAuthority, TOKEN_ID,
};
use solana_address::Address;
use solana_clock::Clock;
use solana_instruction::{AccountMeta, Instruction};
use solana_keypair::Keypair;
use solana_message::Message;
use solana_signer::Signer;
use solana_transaction::Transaction;

const USDC: u64 = 1_000_000;
const DAY: i64 = 86_400;
const LOCK: u64 = 90 * DAY as u64;
const NOTICE: u64 = 90 * DAY as u64;
const RATE_BPS: u16 = 800;

// ── glue between Anchor's SDK 1.x types and LiteSVM's 2.x types ─────────────

fn addr(pk: Pubkey) -> Address {
    Address::new_from_array(pk.to_bytes())
}
fn pk(ad: Address) -> Pubkey {
    Pubkey::new_from_array(ad.to_bytes())
}
fn program() -> Address {
    addr(PROGRAM)
}
fn system_program() -> Pubkey {
    Pubkey::new_from_array([0u8; 32])
}
fn token_program() -> Pubkey {
    pk(TOKEN_ID)
}

fn ixn(accounts: impl ToAccountMetas, data: impl InstructionData) -> Instruction {
    Instruction {
        program_id: program(),
        accounts: accounts
            .to_account_metas(None)
            .into_iter()
            .map(|m| AccountMeta {
                pubkey: addr(m.pubkey),
                is_signer: m.is_signer,
                is_writable: m.is_writable,
            })
            .collect(),
        data: data.data(),
    }
}

struct World {
    svm: LiteSVM,
    admin: Keypair,
    allowlist_authority: Keypair,
    treasury_authority: Keypair,
    emergency_authority: Keypair,
    curator: Keypair,
    stranger: Keypair,
    third: Keypair,
    mint: Address,
    curator_ata: Address,
    treasury_ata: Address,
    stranger_ata: Address,
    third_ata: Address,
    config: Pubkey,
    vault_ata: Pubkey,
    coupon_ata: Pubkey,
    event_payloads: Vec<Vec<u8>>,
}

impl World {
    fn send(
        &mut self,
        ixs: &[Instruction],
        signers: &[&Keypair],
    ) -> Result<(), FailedTransactionMetadata> {
        // A fresh blockhash per transaction: two identical calls in a row are otherwise the same
        // signature, which the ledger rejects as already processed before the program runs.
        self.svm.expire_blockhash();
        let payer = signers[0];
        let msg = Message::new(ixs, Some(&payer.pubkey()));
        let tx = Transaction::new(signers, msg, self.svm.latest_blockhash());
        match self.svm.send_transaction(tx) {
            Ok(meta) => {
                for log in &meta.logs {
                    let Some(encoded) = log.strip_prefix("Program data: ") else {
                        continue;
                    };
                    if let Ok(payload) = BASE64.decode(encoded) {
                        self.event_payloads.push(payload);
                    }
                }
                Ok(())
            }
            Err(error) => Err(error),
        }
    }

    fn now(&self) -> i64 {
        self.svm.get_sysvar::<Clock>().unix_timestamp
    }

    fn warp(&mut self, ts: i64) {
        let mut clock: Clock = self.svm.get_sysvar();
        clock.unix_timestamp = ts;
        clock.slot += 1;
        self.svm.set_sysvar(&clock);
        self.svm.expire_blockhash();
    }

    fn config(&self) -> Config {
        let data = self
            .svm
            .get_account(&addr(self.config))
            .expect("config")
            .data;
        Config::try_deserialize(&mut data.as_slice()).expect("config layout")
    }

    /// Writes a deliberately malformed config for must-revert tests. Each caller owns a fresh
    /// LiteSVM book; production instructions never expose an equivalent mutation surface.
    fn set_config_for_negative_test(&mut self, config: &Config) {
        let mut account = self.svm.get_account(&addr(self.config)).expect("config");
        let mut destination = account.data.as_mut_slice();
        config
            .try_serialize(&mut destination)
            .expect("serialize config");
        self.svm
            .set_account(addr(self.config), account)
            .expect("replace config");
    }

    /// Models an out-of-band token-account discrepancy without changing the program ledger.
    fn set_token_amount_for_negative_test(&mut self, account_key: Pubkey, amount: u64) {
        let mut account = self
            .svm
            .get_account(&addr(account_key))
            .expect("token account");
        // Classic SPL Token account layout: mint [0..32], owner [32..64], amount [64..72].
        account.data[64..72].copy_from_slice(&amount.to_le_bytes());
        self.svm
            .set_account(addr(account_key), account)
            .expect("replace token account");
    }

    fn position_key(&self, owner: Pubkey) -> Pubkey {
        Pubkey::find_program_address(&[b"position", owner.as_ref()], &PROGRAM).0
    }

    fn position(&self, owner: Pubkey) -> Position {
        let data = self
            .svm
            .get_account(&addr(self.position_key(owner)))
            .expect("position")
            .data;
        Position::try_deserialize(&mut data.as_slice()).expect("position layout")
    }

    fn balance(&self, ata: Address) -> u64 {
        get_spl_account::<TokenAccountState>(&self.svm, &ata)
            .expect("token account")
            .amount
    }

    fn last_event<T>(&self) -> T
    where
        T: BorshDeserialize + Discriminator,
    {
        self.event_payloads
            .iter()
            .rev()
            .find_map(|payload| {
                let body = payload.strip_prefix(T::DISCRIMINATOR)?;
                T::try_from_slice(body).ok()
            })
            .unwrap_or_else(|| panic!("event {} was not emitted", std::any::type_name::<T>()))
    }

    /// I1-I4 and I8 state predicates: conservation (allowing unsolicited surplus), draw caps,
    /// coupon funding/liabilities, and coherent withdrawal eligibility.
    fn assert_invariants(&self, when: &str) {
        let c = self.config();
        assert!(
            self.balance(addr(self.vault_ata)) + c.drawn >= c.total_principal,
            "I1 conservation {when}"
        );
        assert!(c.drawn <= c.total_principal, "I2 draw cap {when}");
        assert!(
            c.coupon_paid <= c.coupon_funded,
            "I3 paid within funded {when}"
        );
        assert!(
            self.balance(addr(self.coupon_ata)) >= c.coupon_funded - c.coupon_paid,
            "I3 pool balance {when}"
        );
        let mut owed_sum = 0u64;
        let mut drawn_sum = 0u64;
        let mut principal_sum = 0u64;
        for owner in [
            pk(self.curator.pubkey()),
            pk(self.stranger.pubkey()),
            pk(self.third.pubkey()),
        ] {
            if let Some(account) = self.svm.get_account(&addr(self.position_key(owner))) {
                if account.data.is_empty() {
                    continue;
                }
                let p = Position::try_deserialize(&mut account.data.as_slice())
                    .expect("position layout");
                assert!(p.drawn <= p.principal, "position draw cap {when}");
                assert!(p.coupon_payable <= p.coupon_owed, "payable subset {when}");
                if p.notice_requested_at == 0 {
                    assert_eq!(
                        p.withdrawal_eligible_at, 0,
                        "I4 no eligibility without notice {when}"
                    );
                } else {
                    assert!(
                        p.withdrawal_eligible_at >= p.lock_end,
                        "I4 eligibility never precedes lock {when}"
                    );
                }
                owed_sum = owed_sum.checked_add(p.coupon_owed).expect("owed sum");
                drawn_sum = drawn_sum.checked_add(p.drawn).expect("drawn sum");
                principal_sum = principal_sum
                    .checked_add(p.principal)
                    .expect("principal sum");
            }
        }
        assert_eq!(
            c.coupon_owed_total, owed_sum,
            "aggregate coupon liability {when}"
        );
        assert_eq!(c.drawn, drawn_sum, "aggregate position draws {when}");
        assert_eq!(
            c.total_principal, principal_sum,
            "aggregate principal {when}"
        );
    }

    // ── instruction builders ────────────────────────────────────────────

    fn curator_transfer(&self, owner: &Keypair, owner_ata: Address) -> acc::CuratorTransfer {
        acc::CuratorTransfer {
            owner: pk(owner.pubkey()),
            config: self.config,
            position: self.position_key(pk(owner.pubkey())),
            vault_ata: self.vault_ata,
            owner_ata: pk(owner_ata),
            token_program: token_program(),
        }
    }

    fn curator_action(&self, owner: &Keypair) -> acc::CuratorAction {
        acc::CuratorAction {
            owner: pk(owner.pubkey()),
            config: self.config,
            position: self.position_key(pk(owner.pubkey())),
        }
    }

    fn deposit(
        &mut self,
        owner: &Keypair,
        owner_ata: Address,
        amount: u64,
    ) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            self.curator_transfer(owner, owner_ata),
            ix::Deposit { amount },
        );
        self.send(&[i], &[owner])
    }

    fn withdraw(
        &mut self,
        owner: &Keypair,
        owner_ata: Address,
        amount: u64,
    ) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            self.curator_transfer(owner, owner_ata),
            ix::Withdraw { amount },
        );
        self.send(&[i], &[owner])
    }

    fn request_withdrawal(&mut self, owner: &Keypair) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(self.curator_action(owner), ix::RequestWithdrawal {});
        self.send(&[i], &[owner])
    }

    fn cancel_withdrawal(&mut self, owner: &Keypair) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(self.curator_action(owner), ix::CancelWithdrawal {});
        self.send(&[i], &[owner])
    }

    fn allowlist(
        &mut self,
        signer: &Keypair,
        owner: Pubkey,
        hash: [u8; 32],
    ) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            acc::Allowlist {
                allowlist_authority: pk(signer.pubkey()),
                config: self.config,
                owner,
                position: self.position_key(owner),
                system_program: system_program(),
            },
            ix::Allowlist {
                agreement_hash: hash,
            },
        );
        self.send(&[i], &[signer])
    }

    fn draw(&mut self, signer: &Keypair, amount: u64) -> Result<(), FailedTransactionMetadata> {
        self.draw_for(signer, pk(self.curator.pubkey()), amount)
    }

    fn draw_for(
        &mut self,
        signer: &Keypair,
        owner: Pubkey,
        amount: u64,
    ) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            acc::DrawToTreasury {
                treasury_authority: pk(signer.pubkey()),
                config: self.config,
                position: self.position_key(owner),
                vault_ata: self.vault_ata,
                treasury_ata: pk(self.treasury_ata),
                token_program: token_program(),
            },
            ix::DrawToTreasury { amount },
        );
        self.send(&[i], &[signer])
    }

    fn treasury_pay(
        &mut self,
        destination: Pubkey,
        data: impl InstructionData,
    ) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            acc::TreasuryPay {
                treasury_authority: pk(self.treasury_authority.pubkey()),
                config: self.config,
                source: pk(self.treasury_ata),
                destination,
                token_program: token_program(),
            },
            data,
        );
        let signer = self.treasury_authority.insecure_clone();
        self.send(&[i], &[&signer])
    }

    fn return_principal(
        &mut self,
        owner: Pubkey,
        amount: u64,
    ) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            acc::ReturnPrincipal {
                treasury_authority: pk(self.treasury_authority.pubkey()),
                config: self.config,
                position: self.position_key(owner),
                source: pk(self.treasury_ata),
                vault_ata: self.vault_ata,
                token_program: token_program(),
            },
            ix::ReturnPrincipal { amount },
        );
        let signer = self.treasury_authority.insecure_clone();
        self.send(&[i], &[&signer])
    }

    fn pay_coupon(
        &mut self,
        cranker: &Keypair,
        owner: Pubkey,
        owner_ata: Address,
    ) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            acc::PayCoupon {
                cranker: pk(cranker.pubkey()),
                config: self.config,
                position: self.position_key(owner),
                coupon_ata: self.coupon_ata,
                owner_ata: pk(owner_ata),
                token_program: token_program(),
            },
            ix::PayCoupon {},
        );
        self.send(&[i], &[cranker])
    }

    fn admin_only(&mut self, data: impl InstructionData) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            acc::AdminOnly {
                admin: pk(self.admin.pubkey()),
                config: self.config,
            },
            data,
        );
        let signer = self.admin.insecure_clone();
        self.send(&[i], &[&signer])
    }

    fn record_loss(
        &mut self,
        owner: Pubkey,
        amount: u64,
        hash: [u8; 32],
    ) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            acc::RecordLoss {
                admin: pk(self.admin.pubkey()),
                config: self.config,
                position: self.position_key(owner),
            },
            ix::RecordLoss {
                amount,
                evidence_hash: hash,
            },
        );
        let signer = self.admin.insecure_clone();
        self.send(&[i], &[&signer])
    }

    fn sweep_principal_surplus(
        &mut self,
        signer: &Keypair,
        amount: u64,
    ) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            acc::SweepPrincipalSurplus {
                treasury_authority: pk(signer.pubkey()),
                config: self.config,
                vault_ata: self.vault_ata,
                treasury_ata: pk(self.treasury_ata),
                token_program: token_program(),
            },
            ix::SweepPrincipalSurplus { amount },
        );
        self.send(&[i], &[signer])
    }

    fn sweep_coupons(
        &mut self,
        signer: &Keypair,
        amount: u64,
    ) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            acc::SweepCoupons {
                treasury_authority: pk(signer.pubkey()),
                config: self.config,
                coupon_ata: self.coupon_ata,
                treasury_ata: pk(self.treasury_ata),
                token_program: token_program(),
            },
            ix::SweepCoupons { amount },
        );
        self.send(&[i], &[signer])
    }

    fn withdraw_unused_coupon_funding(
        &mut self,
        signer: &Keypair,
        amount: u64,
    ) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            acc::SweepCoupons {
                treasury_authority: pk(signer.pubkey()),
                config: self.config,
                coupon_ata: self.coupon_ata,
                treasury_ata: pk(self.treasury_ata),
                token_program: token_program(),
            },
            ix::WithdrawUnusedCouponFunding { amount },
        );
        self.send(&[i], &[signer])
    }

    /// Expected coupon for a position from the config's epochs, computed with the library the
    /// program uses. The test asserts the program pays exactly this.
    fn expected_coupon(&self, principal: u64, from: i64, to: i64, remainder: u128) -> (u64, u128) {
        math::accrue(principal, &self.config().epochs(), from, to, remainder).unwrap()
    }
}

fn expect_error(result: Result<(), FailedTransactionMetadata>, code: &str) {
    match result {
        Ok(()) => panic!("expected {code}, transaction succeeded"),
        Err(e) => {
            let logs = e.meta.logs.join("\n");
            assert!(
                logs.contains(code),
                "expected {code}; err: {:?}; logs:\n{logs}",
                e.err
            );
        }
    }
}

/// The upgradeable loader's programdata account for the program, as the loader derives it.
fn program_data() -> Pubkey {
    let loader = Pubkey::new_from_array(solana_sdk_ids::bpf_loader_upgradeable::ID.to_bytes());
    Pubkey::find_program_address(&[PROGRAM.as_ref()], &loader).0
}

/// LiteSVM installs programs with no upgrade authority; `initialize` requires the admin to be
/// that authority, so the harness writes it into the programdata header (tag, slot, Some(key)).
fn set_upgrade_authority(svm: &mut LiteSVM, authority: Pubkey) {
    let pd = addr(program_data());
    let mut account = svm.get_account(&pd).expect("programdata");
    account.data[12] = 1;
    account.data[13..45].copy_from_slice(&authority.to_bytes());
    svm.set_account(pd, account).unwrap();
}

fn setup(principal_at_risk: bool) -> World {
    let mut svm = LiteSVM::new();
    svm.add_program_from_file(program(), "../../target/deploy/forestroad_curator_vault.so")
        .expect("run `anchor build` first");
    let admin = Keypair::new();
    set_upgrade_authority(&mut svm, pk(admin.pubkey()));
    let allowlist_authority = Keypair::new();
    let treasury_authority = Keypair::new();
    let emergency_authority = Keypair::new();
    let curator = Keypair::new();
    let stranger = Keypair::new();
    let third = Keypair::new();
    for k in [
        &admin,
        &allowlist_authority,
        &treasury_authority,
        &emergency_authority,
        &curator,
        &stranger,
        &third,
    ] {
        svm.airdrop(&k.pubkey(), 10_000_000_000).unwrap();
    }
    // 2026-09-18T01:00:00Z
    let start = math::days_from_civil(2026, 9, 18) * DAY + 3_600;
    let mut clock: Clock = svm.get_sysvar();
    clock.unix_timestamp = start;
    svm.set_sysvar(&clock);

    let mint = CreateMint::new(&mut svm, &admin)
        .decimals(6)
        .authority(&admin.pubkey())
        .send()
        .unwrap();
    let curator_ata = CreateAssociatedTokenAccount::new(&mut svm, &admin, &mint)
        .owner(&curator.pubkey())
        .send()
        .unwrap();
    let treasury_ata = CreateAssociatedTokenAccount::new(&mut svm, &admin, &mint)
        .owner(&treasury_authority.pubkey())
        .send()
        .unwrap();
    let stranger_ata = CreateAssociatedTokenAccount::new(&mut svm, &admin, &mint)
        .owner(&stranger.pubkey())
        .send()
        .unwrap();
    let third_ata = CreateAssociatedTokenAccount::new(&mut svm, &admin, &mint)
        .owner(&third.pubkey())
        .send()
        .unwrap();
    MintTo::new(&mut svm, &admin, &mint, &curator_ata, 1_000_000 * USDC)
        .send()
        .unwrap();
    MintTo::new(&mut svm, &admin, &mint, &treasury_ata, 1_000_000 * USDC)
        .send()
        .unwrap();
    MintTo::new(&mut svm, &admin, &mint, &stranger_ata, 1_000_000 * USDC)
        .send()
        .unwrap();
    MintTo::new(&mut svm, &admin, &mint, &third_ata, 1_000_000 * USDC)
        .send()
        .unwrap();

    let config = Pubkey::find_program_address(&[b"config"], &PROGRAM).0;
    let vault_ata = Pubkey::find_program_address(&[b"vault"], &PROGRAM).0;
    let coupon_ata = Pubkey::find_program_address(&[b"coupon"], &PROGRAM).0;

    let mut w = World {
        svm,
        admin,
        allowlist_authority,
        treasury_authority,
        emergency_authority,
        curator,
        stranger,
        third,
        mint,
        curator_ata,
        treasury_ata,
        stranger_ata,
        third_ata,
        config,
        vault_ata,
        coupon_ata,
        event_payloads: Vec::new(),
    };
    let init = ixn(
        acc::Initialize {
            admin: pk(w.admin.pubkey()),
            program: PROGRAM,
            program_data: program_data(),
            config,
            usdc_mint: pk(w.mint),
            vault_ata,
            coupon_ata,
            treasury_ata: pk(w.treasury_ata),
            token_program: token_program(),
            system_program: system_program(),
        },
        ix::Initialize {
            params: InitializeParams {
                allowlist_authority: pk(w.allowlist_authority.pubkey()),
                treasury_authority: pk(w.treasury_authority.pubkey()),
                emergency_authority: pk(w.emergency_authority.pubkey()),
                lock_seconds: LOCK,
                notice_seconds: NOTICE,
                principal_at_risk,
                initial_bps: RATE_BPS,
            },
        },
    );
    let admin = w.admin.insecure_clone();
    w.send(&[init], &[&admin]).expect("initialize");
    w
}

#[test]
fn initialize_pins_the_terms_and_the_first_rate_epoch() {
    let w = setup(true);
    assert_eq!(8 + Config::INIT_SPACE, 650, "Config allocation drift");
    assert_eq!(8 + Position::INIT_SPACE, 260, "Position allocation drift");
    assert_eq!(
        w.svm.get_account(&addr(w.config)).unwrap().data.len(),
        650,
        "initialized Config allocation"
    );
    let c = w.config();
    assert_eq!(c.admin, pk(w.admin.pubkey()));
    assert_eq!(c.usdc_mint, pk(w.mint));
    assert_eq!(c.vault_ata, w.vault_ata);
    assert_eq!(c.coupon_ata, w.coupon_ata);
    assert_eq!(c.treasury_ata, pk(w.treasury_ata));
    assert_eq!((c.lock_seconds, c.notice_seconds), (LOCK, NOTICE));
    assert!(c.principal_at_risk && !c.paused);
    assert_eq!(c.rate_epoch_count, 1);
    assert_eq!(c.rate_epochs[0].bps, RATE_BPS);
    assert_eq!(c.rate_epochs[0].start_ts, w.now());
    assert_eq!(
        (c.total_principal, c.drawn, c.coupon_funded, c.coupon_paid),
        (0, 0, 0, 0)
    );
    w.assert_invariants("after initialize");
}

#[test]
fn every_event_reports_the_complete_committed_transition() {
    let mut w = setup(true);
    let admin = w.admin.insecure_clone();
    let allowlister = w.allowlist_authority.insecure_clone();
    let treasurer = w.treasury_authority.insecure_clone();
    let emergency = w.emergency_authority.insecure_clone();
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let stranger = w.stranger.insecure_clone();
    let stranger_pk = pk(stranger.pubkey());
    let t0 = w.now();

    let initialized = w.last_event::<events::Initialized>();
    assert_eq!(initialized.version, 1);
    assert_eq!(initialized.admin, pk(admin.pubkey()));
    assert_eq!(initialized.allowlist_authority, pk(allowlister.pubkey()));
    assert_eq!(initialized.treasury_authority, pk(treasurer.pubkey()));
    assert_eq!(initialized.emergency_authority, pk(emergency.pubkey()));
    assert_eq!(initialized.usdc_mint, pk(w.mint));
    assert_eq!(initialized.vault_ata, w.vault_ata);
    assert_eq!(initialized.coupon_ata, w.coupon_ata);
    assert_eq!(initialized.treasury_ata, pk(w.treasury_ata));
    assert_eq!(initialized.lock_seconds, LOCK);
    assert_eq!(initialized.notice_seconds, NOTICE);
    assert!(initialized.principal_at_risk);
    assert_eq!(initialized.initial_bps, RATE_BPS);

    let agreement_hash = [31u8; 32];
    w.allowlist(&allowlister, curator_pk, agreement_hash)
        .unwrap();
    let allowlisted = w.last_event::<events::Allowlisted>();
    assert_eq!(allowlisted.owner, curator_pk);
    assert_eq!(allowlisted.agreement_hash, agreement_hash);
    assert_eq!(allowlisted.ts, t0);

    w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    let deposited = w.last_event::<events::Deposited>();
    assert_eq!(deposited.owner, curator_pk);
    assert_eq!(deposited.amount, 100_000 * USDC);
    assert_eq!(deposited.principal_after, 100_000 * USDC);
    assert_eq!(deposited.lock_end, t0 + LOCK as i64);
    assert_eq!(deposited.total_principal, 100_000 * USDC);
    assert_eq!(deposited.position_drawn, 0);
    assert_eq!(deposited.coupon_owed, 0);
    assert_eq!(deposited.coupon_payable, 0);
    assert_eq!(deposited.coupon_accrued_through, t0);
    assert_eq!(deposited.ts, t0);

    w.request_withdrawal(&curator).unwrap();
    let requested = w.last_event::<events::WithdrawalRequested>();
    assert_eq!(requested.owner, curator_pk);
    assert_eq!(requested.eligible_at, t0 + NOTICE as i64);
    assert_eq!(requested.ts, t0);
    w.cancel_withdrawal(&curator).unwrap();
    let cancelled = w.last_event::<events::WithdrawalCancelled>();
    assert_eq!(cancelled.owner, curator_pk);
    assert_eq!(cancelled.ts, t0);

    w.admin_only(ix::SetTerms {
        lock_seconds: 120 * DAY as u64,
        notice_seconds: 150 * DAY as u64,
    })
    .unwrap();
    let terms = w.last_event::<events::TermsChanged>();
    assert_eq!(terms.lock_seconds, 120 * DAY as u64);
    assert_eq!(terms.notice_seconds, 150 * DAY as u64);
    let next_rate = t0 + DAY;
    w.admin_only(ix::SetRate {
        bps: 900,
        start_ts: next_rate,
    })
    .unwrap();
    let rate = w.last_event::<events::RateEpochAdded>();
    assert_eq!(rate.index, 1);
    assert_eq!(rate.start_ts, next_rate);
    assert_eq!(rate.bps, 900);

    let set_authorities = ixn(
        acc::SetAuthorities {
            admin: pk(admin.pubkey()),
            config: w.config,
            treasury_ata: pk(w.treasury_ata),
        },
        ix::SetAuthorities {
            allowlist_authority: pk(allowlister.pubkey()),
            treasury_authority: pk(treasurer.pubkey()),
            emergency_authority: pk(emergency.pubkey()),
        },
    );
    w.send(&[set_authorities], &[&admin]).unwrap();
    let authorities = w.last_event::<events::AuthoritiesChanged>();
    assert_eq!(authorities.allowlist_authority, pk(allowlister.pubkey()));
    assert_eq!(authorities.treasury_authority, pk(treasurer.pubkey()));
    assert_eq!(authorities.emergency_authority, pk(emergency.pubkey()));
    assert_eq!(authorities.treasury_ata, pk(w.treasury_ata));

    w.admin_only(ix::SetPaused { paused: true }).unwrap();
    let paused = w.last_event::<events::PauseChanged>();
    assert!(paused.paused);
    assert_eq!(paused.actor, pk(admin.pubkey()));
    assert_eq!(paused.ts, t0);
    let emergency_pause = ixn(
        acc::EmergencyOnly {
            emergency_authority: pk(emergency.pubkey()),
            config: w.config,
        },
        ix::EmergencyPause {},
    );
    w.send(&[emergency_pause], &[&emergency]).unwrap();
    let paused = w.last_event::<events::PauseChanged>();
    assert!(paused.paused);
    assert_eq!(paused.actor, pk(emergency.pubkey()));
    assert_eq!(paused.ts, t0);
    w.admin_only(ix::SetPaused { paused: false }).unwrap();

    let halt = |w: &World, halted: bool| {
        ixn(
            acc::RevokeAllowlist {
                allowlist_authority: pk(allowlister.pubkey()),
                config: w.config,
                position: w.position_key(curator_pk),
            },
            ix::SetPayoutHalt { halted },
        )
    };
    let set_halt = halt(&w, true);
    w.send(&[set_halt], &[&allowlister]).unwrap();
    let payout_halt = w.last_event::<events::PayoutHaltChanged>();
    assert_eq!(payout_halt.owner, curator_pk);
    assert!(payout_halt.halted);
    assert_eq!(payout_halt.actor, pk(allowlister.pubkey()));
    assert_eq!(payout_halt.ts, t0);
    let clear_halt = halt(&w, false);
    w.send(&[clear_halt], &[&allowlister]).unwrap();
    let emergency_halt = ixn(
        acc::EmergencyHalt {
            emergency_authority: pk(emergency.pubkey()),
            config: w.config,
            position: w.position_key(curator_pk),
        },
        ix::EmergencyHalt {},
    );
    w.send(&[emergency_halt], &[&emergency]).unwrap();
    let payout_halt = w.last_event::<events::PayoutHaltChanged>();
    assert_eq!(payout_halt.owner, curator_pk);
    assert!(payout_halt.halted);
    assert_eq!(payout_halt.actor, pk(emergency.pubkey()));
    assert_eq!(payout_halt.ts, t0);
    let clear_halt = halt(&w, false);
    w.send(&[clear_halt], &[&allowlister]).unwrap();
    let payout_halt = w.last_event::<events::PayoutHaltChanged>();
    assert!(!payout_halt.halted);
    assert_eq!(payout_halt.actor, pk(allowlister.pubkey()));

    w.draw(&treasurer, 20_000 * USDC).unwrap();
    let draw = w.last_event::<events::TreasuryDraw>();
    assert_eq!(draw.owner, curator_pk);
    assert_eq!(draw.amount, 20_000 * USDC);
    assert_eq!(draw.drawn_after, 20_000 * USDC);
    assert_eq!(draw.position_drawn_after, 20_000 * USDC);
    assert_eq!(draw.ts, t0);
    w.return_principal(curator_pk, 5_000 * USDC).unwrap();
    let returned = w.last_event::<events::PrincipalReturned>();
    assert_eq!(returned.owner, curator_pk);
    assert_eq!(returned.amount, 5_000 * USDC);
    assert_eq!(returned.drawn_after, 15_000 * USDC);
    assert_eq!(returned.position_drawn_after, 15_000 * USDC);
    assert_eq!(returned.ts, t0);
    let evidence_hash = [32u8; 32];
    w.record_loss(curator_pk, 5_000 * USDC, evidence_hash)
        .unwrap();
    let loss = w.last_event::<events::LossRecorded>();
    assert_eq!(loss.owner, curator_pk);
    assert_eq!(loss.amount, 5_000 * USDC);
    assert_eq!(loss.principal_after, 95_000 * USDC);
    assert_eq!(loss.position_drawn_after, 10_000 * USDC);
    assert_eq!(loss.coupon_owed, 0);
    assert_eq!(loss.coupon_payable, 0);
    assert_eq!(loss.coupon_accrued_through, t0);
    assert_eq!(loss.evidence_hash, evidence_hash);
    assert_eq!(loss.ts, t0);

    w.treasury_pay(
        w.coupon_ata,
        ix::FundCoupons {
            amount: 10_000 * USDC,
        },
    )
    .unwrap();
    let funded = w.last_event::<events::CouponsFunded>();
    assert_eq!(funded.amount, 10_000 * USDC);
    assert_eq!(funded.coupon_funded, 10_000 * USDC);
    assert_eq!(funded.ts, t0);

    let boundary = math::next_month_start(t0) + 1;
    w.warp(boundary);
    w.pay_coupon(&stranger, curator_pk, w.curator_ata).unwrap();
    let paid = w.last_event::<events::CouponPaid>();
    let position = w.position(curator_pk);
    assert_eq!(paid.owner, curator_pk);
    assert_eq!(paid.period_end, math::month_start(boundary));
    assert!(paid.amount > 0);
    assert_eq!(paid.coupon_paid, w.config().coupon_paid);
    assert_eq!(paid.coupon_owed_after, position.coupon_owed);
    assert_eq!(paid.coupon_payable_after, position.coupon_payable);
    assert_eq!(paid.coupon_accrued_through, position.coupon_accrued_through);
    assert_eq!(paid.surplus_recognized, 0);
    assert_eq!(paid.ts, boundary);

    MintTo::new(&mut w.svm, &admin, &w.mint, &addr(w.coupon_ata), 3 * USDC)
        .send()
        .unwrap();
    w.sweep_coupons(&treasurer, 3 * USDC).unwrap();
    let swept = w.last_event::<events::CouponsSwept>();
    assert_eq!(swept.amount, 3 * USDC);
    assert_eq!(swept.coupon_funded, w.config().coupon_funded);
    assert_eq!(swept.ts, boundary);
    MintTo::new(&mut w.svm, &admin, &w.mint, &addr(w.vault_ata), 4 * USDC)
        .send()
        .unwrap();
    w.sweep_principal_surplus(&treasurer, 4 * USDC).unwrap();
    let swept = w.last_event::<events::PrincipalSurplusSwept>();
    assert_eq!(swept.amount, 4 * USDC);
    assert_eq!(swept.ts, boundary);

    w.return_principal(curator_pk, 10_000 * USDC).unwrap();
    w.request_withdrawal(&curator).unwrap();
    let eligible = w.position(curator_pk).withdrawal_eligible_at;
    w.warp(eligible);
    w.withdraw(&curator, w.curator_ata, USDC).unwrap();
    let withdrawn = w.last_event::<events::Withdrawn>();
    let position = w.position(curator_pk);
    assert_eq!(withdrawn.owner, curator_pk);
    assert_eq!(withdrawn.amount, USDC);
    assert_eq!(withdrawn.principal_after, position.principal);
    assert_eq!(withdrawn.total_principal, w.config().total_principal);
    assert_eq!(withdrawn.position_drawn, position.drawn);
    assert_eq!(withdrawn.coupon_owed, position.coupon_owed);
    assert_eq!(withdrawn.coupon_payable, position.coupon_payable);
    assert_eq!(
        withdrawn.coupon_accrued_through,
        position.coupon_accrued_through
    );
    assert_eq!(withdrawn.ts, eligible);

    let revoke = ixn(
        acc::RevokeAllowlist {
            allowlist_authority: pk(allowlister.pubkey()),
            config: w.config,
            position: w.position_key(curator_pk),
        },
        ix::RevokeAllowlist {},
    );
    w.send(&[revoke], &[&allowlister]).unwrap();
    let revoked = w.last_event::<events::AllowlistRevoked>();
    assert_eq!(revoked.owner, curator_pk);
    assert_eq!(revoked.ts, eligible);

    w.allowlist(&allowlister, stranger_pk, [33u8; 32]).unwrap();
    let close = ixn(
        acc::ClosePosition {
            owner: stranger_pk,
            config: w.config,
            position: w.position_key(stranger_pk),
        },
        ix::ClosePosition {},
    );
    w.send(&[close], &[&stranger]).unwrap();
    let closed = w.last_event::<events::PositionClosed>();
    assert_eq!(closed.owner, stranger_pk);
    assert_eq!(closed.ts, eligible);

    let new_admin = Keypair::new();
    w.svm.airdrop(&new_admin.pubkey(), 1_000_000_000).unwrap();
    w.admin_only(ix::ProposeAdmin {
        new_admin: pk(new_admin.pubkey()),
    })
    .unwrap();
    let proposed = w.last_event::<events::AdminTransferProposed>();
    assert_eq!(proposed.admin, pk(admin.pubkey()));
    assert_eq!(proposed.pending_admin, pk(new_admin.pubkey()));
    let accept = ixn(
        acc::AcceptAdmin {
            pending_admin: pk(new_admin.pubkey()),
            config: w.config,
        },
        ix::AcceptAdmin {},
    );
    w.send(&[accept], &[&new_admin]).unwrap();
    let accepted = w.last_event::<events::AdminTransferAccepted>();
    assert_eq!(accepted.previous_admin, pk(admin.pubkey()));
    assert_eq!(accepted.admin, pk(new_admin.pubkey()));
    w.assert_invariants("after event assertions");
}

#[test]
fn full_lifecycle_with_invariants() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let stranger = w.stranger.insecure_clone();
    let allowlister = w.allowlist_authority.insecure_clone();
    let treasurer = w.treasury_authority.insecure_clone();
    let t0 = w.now();

    // ── allowlist ───────────────────────────────────────────────────────
    expect_error(
        w.deposit(&curator, w.curator_ata, 1),
        "AccountNotInitialized",
    );
    expect_error(
        w.allowlist(&stranger, curator_pk, [7u8; 32]),
        "ConstraintHasOne",
    );
    expect_error(w.allowlist(&allowlister, curator_pk, [0u8; 32]), "ZeroHash");
    w.allowlist(&allowlister, curator_pk, [7u8; 32]).unwrap();
    assert_eq!(
        w.svm
            .get_account(&addr(w.position_key(curator_pk)))
            .unwrap()
            .data
            .len(),
        260,
        "initialized Position allocation"
    );
    expect_error(
        w.allowlist(&allowlister, curator_pk, [8u8; 32]),
        "AlreadyAllowlisted",
    );
    let p = w.position(curator_pk);
    assert!(p.allowlisted && p.owner == curator_pk && p.agreement_hash == [7u8; 32]);
    assert_eq!(w.config().positions, 1);

    // ── deposit: lock set, accrual starts now, I1 holds ──────────────────
    expect_error(w.deposit(&curator, w.curator_ata, 0), "ZeroAmount");
    expect_error(
        w.deposit(&stranger, w.stranger_ata, 1),
        "AccountNotInitialized",
    );
    w.deposit(&curator, w.curator_ata, 500_000 * USDC).unwrap();
    let p = w.position(curator_pk);
    assert_eq!(p.principal, 500_000 * USDC);
    assert_eq!(p.lock_end, t0 + LOCK as i64);
    assert_eq!(p.deposited_at, t0);
    assert_eq!(p.coupon_accrued_through, t0);
    assert_eq!(
        p.coupon_paid_through,
        math::month_start(t0),
        "opened mid-month: paid through this month's boundary"
    );
    assert_eq!(w.balance(addr(w.vault_ata)), 500_000 * USDC);
    w.assert_invariants("after first deposit");

    // ── lock and notice ─────────────────────────────────────────────────
    expect_error(w.withdraw(&curator, w.curator_ata, 1), "Locked");
    expect_error(w.cancel_withdrawal(&curator), "NoNotice");
    w.request_withdrawal(&curator).unwrap();
    expect_error(w.request_withdrawal(&curator), "NoticePending");
    expect_error(w.deposit(&curator, w.curator_ata, 1), "NoticePending");
    let p = w.position(curator_pk);
    assert_eq!(p.notice_requested_at, t0);
    assert_eq!(
        p.withdrawal_eligible_at,
        t0 + NOTICE as i64,
        "notice and lock coincide at t0"
    );
    expect_error(w.withdraw(&curator, w.curator_ata, 1), "Locked");
    w.cancel_withdrawal(&curator).unwrap();
    assert_eq!(w.position(curator_pk).withdrawal_eligible_at, 0);

    // A top-up ten days later relocks the whole position from the top-up.
    w.warp(t0 + 10 * DAY);
    w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    let p = w.position(curator_pk);
    assert_eq!(p.principal, 600_000 * USDC);
    assert_eq!(p.lock_end, t0 + 10 * DAY + LOCK as i64);
    let (owed_10d, rem_10d) = w.expected_coupon(500_000 * USDC, t0, t0 + 10 * DAY, 0);
    assert_eq!(
        p.coupon_owed, owed_10d,
        "ten days on the first tranche were settled before the top-up"
    );
    assert_eq!(p.coupon_remainder, rem_10d);
    w.assert_invariants("after top-up");

    // ── treasury draw ───────────────────────────────────────────────────
    expect_error(w.draw(&stranger, 1), "ConstraintHasOne");
    expect_error(
        w.draw(&treasurer, 600_000 * USDC + 1),
        "DrawExceedsPrincipal",
    );
    w.draw(&treasurer, 400_000 * USDC).unwrap();
    assert_eq!(w.config().drawn, 400_000 * USDC);
    assert_eq!(w.balance(addr(w.vault_ata)), 200_000 * USDC);
    assert_eq!(w.balance(w.treasury_ata), 1_400_000 * USDC);
    w.assert_invariants("after draw");
    expect_error(
        w.draw(&treasurer, 200_000 * USDC + 1),
        "DrawExceedsPrincipal",
    );

    // ── first coupon month: nothing due before the boundary, exact amount after it ──
    expect_error(
        w.pay_coupon(&stranger, curator_pk, w.curator_ata),
        "NothingDue",
    );
    let oct1 = math::days_from_civil(2026, 10, 1) * DAY;
    w.warp(oct1 + 10);
    expect_error(
        w.pay_coupon(&stranger, curator_pk, w.curator_ata),
        "InsufficientCouponPool",
    );
    w.treasury_pay(
        w.coupon_ata,
        ix::FundCoupons {
            amount: 20_000 * USDC,
        },
    )
    .unwrap();
    expect_error(
        w.treasury_pay(w.vault_ata, ix::FundCoupons { amount: 1 }),
        "WrongTokenAccount",
    );
    let before = w.balance(w.curator_ata);
    let (owed_rest, _) = w.expected_coupon(600_000 * USDC, t0 + 10 * DAY, oct1, rem_10d);
    let expected_first = owed_10d + owed_rest;
    w.pay_coupon(&stranger, curator_pk, w.curator_ata).unwrap();
    assert_eq!(
        w.balance(w.curator_ata) - before,
        expected_first,
        "first coupon equals the library's accrual"
    );
    let p = w.position(curator_pk);
    assert_eq!(
        (
            p.coupon_owed,
            p.coupon_paid_through,
            p.coupon_accrued_through
        ),
        (0, oct1, oct1)
    );
    assert_eq!(w.config().coupon_paid, expected_first);
    expect_error(
        w.pay_coupon(&stranger, curator_pk, w.curator_ata),
        "NothingDue",
    );
    w.assert_invariants("after first coupon");

    // ── rate change from November, paid in December across both epochs ──
    let nov1 = math::days_from_civil(2026, 11, 1) * DAY;
    let dec1 = math::days_from_civil(2026, 12, 1) * DAY;
    expect_error(
        w.admin_only(ix::SetRate {
            bps: 0,
            start_ts: nov1,
        }),
        "BadRate",
    );
    expect_error(
        w.admin_only(ix::SetRate {
            bps: 1_000,
            start_ts: t0,
        }),
        "RateNotForward",
    );
    w.admin_only(ix::SetRate {
        bps: 1_000,
        start_ts: nov1,
    })
    .unwrap();
    assert_eq!(w.config().rate_epoch_count, 2);
    w.warp(dec1 + 5);
    let before = w.balance(w.curator_ata);
    let (expected_second, rem_dec) =
        w.expected_coupon(600_000 * USDC, oct1, dec1, p.coupon_remainder);
    let by_hand = 600_000u128 * USDC as u128 * (800 * 31 + 1_000 * 30) as u128 * DAY as u128
        / math::SLICE_DENOMINATOR;
    assert_eq!(
        expected_second as u128, by_hand,
        "October at 8% plus November at 10%, Actual/360"
    );
    w.pay_coupon(&curator, curator_pk, w.curator_ata).unwrap();
    assert_eq!(w.balance(w.curator_ata) - before, expected_second);
    assert_eq!(w.position(curator_pk).coupon_remainder, rem_dec);
    w.assert_invariants("after second coupon");

    // ── loss recognition: only against drawn capital, principal at risk ─
    expect_error(w.record_loss(curator_pk, 0, [1u8; 32]), "ZeroAmount");
    expect_error(w.record_loss(curator_pk, 1, [0u8; 32]), "ZeroHash");
    expect_error(
        w.record_loss(curator_pk, 400_000 * USDC + 1, [1u8; 32]),
        "LossExceedsDrawn",
    );
    w.record_loss(curator_pk, 50_000 * USDC, [1u8; 32]).unwrap();
    let p = w.position(curator_pk);
    assert_eq!(
        (p.principal, p.losses_recorded),
        (550_000 * USDC, 50_000 * USDC)
    );
    assert_eq!(
        (w.config().total_principal, w.config().drawn),
        (550_000 * USDC, 350_000 * USDC)
    );
    assert_eq!(
        p.coupon_accrued_through,
        dec1 + 5,
        "accrual settled on the old principal before the loss"
    );
    w.assert_invariants("after loss");

    // ── notice, liquidity, return, withdrawal ───────────────────────────
    w.request_withdrawal(&curator).unwrap();
    let eligible = w.position(curator_pk).withdrawal_eligible_at;
    assert_eq!(
        eligible,
        dec1 + 5 + NOTICE as i64,
        "notice dominates the lock by December"
    );
    w.warp(eligible - 1);
    expect_error(w.withdraw(&curator, w.curator_ata, 1), "Locked");
    w.warp(eligible + 1);
    expect_error(
        w.withdraw(&curator, w.curator_ata, 550_000 * USDC + 1),
        "AmountExceedsPrincipal",
    );
    expect_error(
        w.withdraw(&curator, w.curator_ata, 550_000 * USDC),
        "PositionCapitalDrawn",
    );
    expect_error(
        w.return_principal(curator_pk, 350_000 * USDC + 1),
        "ReturnExceedsDrawn",
    );
    w.return_principal(curator_pk, 350_000 * USDC).unwrap();
    assert_eq!(w.config().drawn, 0);
    w.assert_invariants("after return");
    let before = w.balance(w.curator_ata);
    w.withdraw(&curator, w.curator_ata, 550_000 * USDC).unwrap();
    assert_eq!(w.balance(w.curator_ata) - before, 550_000 * USDC);
    let p = w.position(curator_pk);
    assert_eq!(
        (
            p.principal,
            p.lock_end,
            p.notice_requested_at,
            p.withdrawal_eligible_at
        ),
        (0, 0, 0, 0)
    );
    assert_eq!(w.config().total_principal, 0);
    w.assert_invariants("after withdrawal");

    // ── the final partial-month coupon, then close ──────────────────────
    let close = ixn(
        acc::ClosePosition {
            owner: curator_pk,
            config: w.config,
            position: w.position_key(curator_pk),
        },
        ix::ClosePosition {},
    );
    expect_error(
        w.send(std::slice::from_ref(&close), &[&curator]),
        "PositionNotEmpty",
    );
    // December to the withdrawal at 10% on 550,000, settled by the withdrawal itself.
    let p = w.position(curator_pk);
    // Five seconds on 600,000 before the loss was recorded, then 550,000 to the withdrawal.
    let (pre_loss, rem_loss) = w.expected_coupon(600_000 * USDC, dec1, dec1 + 5, rem_dec);
    let (post_loss, _) = w.expected_coupon(550_000 * USDC, dec1 + 5, eligible + 1, rem_loss);
    let expected_last = pre_loss + post_loss;
    assert_eq!(
        p.coupon_owed, expected_last,
        "the withdrawal settled the final accrual"
    );
    let payable_now = p.coupon_payable;
    let deferred = p.coupon_owed - payable_now;
    assert!(
        deferred > 0,
        "accrual after the March boundary waits for April"
    );
    expect_error(
        w.pay_coupon(&stranger, curator_pk, w.curator_ata),
        "InsufficientCouponPool",
    );
    w.treasury_pay(
        w.coupon_ata,
        ix::FundCoupons {
            amount: 20_000 * USDC,
        },
    )
    .unwrap();
    let before = w.balance(w.curator_ata);
    w.pay_coupon(&stranger, curator_pk, w.curator_ata).unwrap();
    assert_eq!(w.balance(w.curator_ata) - before, payable_now);
    assert_eq!(w.position(curator_pk).coupon_owed, deferred);
    expect_error(
        w.send(std::slice::from_ref(&close), &[&curator]),
        "PositionNotEmpty",
    );
    w.warp(math::next_month_start(w.now()) + 1);
    let before = w.balance(w.curator_ata);
    w.pay_coupon(&stranger, curator_pk, w.curator_ata).unwrap();
    assert_eq!(w.balance(w.curator_ata) - before, deferred);
    assert_eq!(w.position(curator_pk).coupon_owed, 0);
    w.send(&[close], &[&curator]).unwrap();
    assert!(w
        .svm
        .get_account(&addr(w.position_key(curator_pk)))
        .map(|a| a.data.is_empty())
        .unwrap_or(true));
    assert_eq!(w.config().positions, 0);
    w.assert_invariants("after close");
}

#[test]
fn pause_blocks_deposits_and_draws_but_never_exits_or_coupons() {
    let mut w = setup(false);
    let admin = w.admin.insecure_clone();
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let treasurer = w.treasury_authority.insecure_clone();
    let stranger = w.stranger.insecure_clone();
    w.allowlist(&allowlister, curator_pk, [9u8; 32]).unwrap();
    w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    w.request_withdrawal(&curator).unwrap();

    w.admin_only(ix::SetPaused { paused: true }).unwrap();
    expect_error(w.deposit(&curator, w.curator_ata, 1), "Paused"); // the pause is checked first
    w.cancel_withdrawal(&curator).unwrap();
    expect_error(w.deposit(&curator, w.curator_ata, 1), "Paused");
    expect_error(w.draw(&treasurer, 1), "Paused");

    // The operational pause stops new curator exposure and treasury deployment. It does not
    // strand direct token donations: either surplus sweep remains available to the treasury.
    MintTo::new(&mut w.svm, &admin, &w.mint, &addr(w.coupon_ata), USDC)
        .send()
        .unwrap();
    MintTo::new(&mut w.svm, &admin, &w.mint, &addr(w.vault_ata), USDC)
        .send()
        .unwrap();
    w.sweep_coupons(&treasurer, USDC).unwrap();
    w.sweep_principal_surplus(&treasurer, USDC).unwrap();

    // I8: exits and coupons keep working while paused.
    w.request_withdrawal(&curator).unwrap();
    let eligible = w.position(curator_pk).withdrawal_eligible_at;
    let boundary = math::next_month_start(eligible) + 1;
    w.warp(boundary);
    w.treasury_pay(
        w.coupon_ata,
        ix::FundCoupons {
            amount: 10_000 * USDC,
        },
    )
    .unwrap();
    w.pay_coupon(&stranger, curator_pk, w.curator_ata).unwrap();
    w.withdraw(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    assert_eq!(w.position(curator_pk).principal, 0);
    w.assert_invariants("paused exit");

    // record_loss is unreachable when principal is not at risk
    expect_error(
        w.record_loss(curator_pk, 1, [1u8; 32]),
        "PrincipalNotAtRisk",
    );
    w.admin_only(ix::SetPaused { paused: false }).unwrap();
    assert!(!w.config().paused);
}

#[test]
fn admin_surface_is_admin_only_and_bounded() {
    let mut w = setup(true);
    let stranger = w.stranger.insecure_clone();
    let bad = ixn(
        acc::AdminOnly {
            admin: pk(stranger.pubkey()),
            config: w.config,
        },
        ix::SetPaused { paused: true },
    );
    expect_error(w.send(&[bad], &[&stranger]), "ConstraintHasOne");
    expect_error(
        w.admin_only(ix::SetTerms {
            lock_seconds: 3_600,
            notice_seconds: NOTICE,
        }),
        "BadTerms",
    );
    expect_error(
        w.admin_only(ix::SetTerms {
            lock_seconds: LOCK,
            notice_seconds: 731 * DAY as u64,
        }),
        "BadTerms",
    );
    w.admin_only(ix::SetTerms {
        lock_seconds: 30 * DAY as u64,
        notice_seconds: 60 * DAY as u64,
    })
    .unwrap();
    let c = w.config();
    assert_eq!(
        (c.lock_seconds, c.notice_seconds),
        (30 * DAY as u64, 60 * DAY as u64)
    );
    // sixteen epochs is the ceiling
    let now = w.now();
    for k in 1..math::MAX_RATE_EPOCHS as i64 {
        w.admin_only(ix::SetRate {
            bps: 100,
            start_ts: now + k * DAY,
        })
        .unwrap();
    }
    expect_error(
        w.admin_only(ix::SetRate {
            bps: 100,
            start_ts: now + 400 * DAY,
        }),
        "RateEpochsFull",
    );
}

#[test]
fn initialize_is_bound_to_the_upgrade_authority() {
    let mut svm = LiteSVM::new();
    svm.add_program_from_file(program(), "../../target/deploy/forestroad_curator_vault.so")
        .unwrap();
    let authority = Keypair::new();
    let impostor = Keypair::new();
    for k in [&authority, &impostor] {
        svm.airdrop(&k.pubkey(), 10_000_000_000).unwrap();
    }
    set_upgrade_authority(&mut svm, pk(authority.pubkey()));
    let mint = CreateMint::new(&mut svm, &authority)
        .decimals(6)
        .authority(&authority.pubkey())
        .send()
        .unwrap();
    let treasury_ata = CreateAssociatedTokenAccount::new(&mut svm, &authority, &mint)
        .owner(&authority.pubkey())
        .send()
        .unwrap();
    let config = Pubkey::find_program_address(&[b"config"], &PROGRAM).0;
    let build = |admin: &Keypair, allowlist: Pubkey, emergency: Pubkey| {
        ixn(
            acc::Initialize {
                admin: pk(admin.pubkey()),
                program: PROGRAM,
                program_data: program_data(),
                config,
                usdc_mint: pk(mint),
                vault_ata: Pubkey::find_program_address(&[b"vault"], &PROGRAM).0,
                coupon_ata: Pubkey::find_program_address(&[b"coupon"], &PROGRAM).0,
                treasury_ata: pk(treasury_ata),
                token_program: token_program(),
                system_program: system_program(),
            },
            ix::Initialize {
                params: InitializeParams {
                    allowlist_authority: allowlist,
                    treasury_authority: pk(authority.pubkey()),
                    emergency_authority: emergency,
                    lock_seconds: LOCK,
                    notice_seconds: NOTICE,
                    principal_at_risk: true,
                    initial_bps: 1_250,
                },
            },
        )
    };
    // Whoever is not the upgrade authority cannot claim the singleton, even as first caller.
    let msg = Message::new(
        &[build(
            &impostor,
            pk(authority.pubkey()),
            pk(authority.pubkey()),
        )],
        Some(&impostor.pubkey()),
    );
    let tx = Transaction::new(&[&impostor], msg, svm.latest_blockhash());
    let err = match svm.send_transaction(tx) {
        Ok(_) => panic!("impostor was not refused"),
        Err(e) => e,
    };
    assert!(
        err.meta.logs.join("\n").contains("Unauthorized"),
        "{:?}",
        err.err
    );
    // Zero ceremony authorities fail before the singleton can be claimed.
    svm.expire_blockhash();
    let msg = Message::new(
        &[build(&authority, Pubkey::default(), pk(authority.pubkey()))],
        Some(&authority.pubkey()),
    );
    let tx = Transaction::new(&[&authority], msg, svm.latest_blockhash());
    let err = svm.send_transaction(tx).unwrap_err();
    assert!(err.meta.logs.join("\n").contains("ZeroAuthority"));
    svm.expire_blockhash();
    let msg = Message::new(
        &[build(&authority, pk(authority.pubkey()), Pubkey::default())],
        Some(&authority.pubkey()),
    );
    let tx = Transaction::new(&[&authority], msg, svm.latest_blockhash());
    let err = svm.send_transaction(tx).unwrap_err();
    assert!(err.meta.logs.join("\n").contains("ZeroAuthority"));
    // The upgrade authority can.
    svm.expire_blockhash();
    let msg = Message::new(
        &[build(
            &authority,
            pk(authority.pubkey()),
            pk(authority.pubkey()),
        )],
        Some(&authority.pubkey()),
    );
    let tx = Transaction::new(&[&authority], msg, svm.latest_blockhash());
    svm.send_transaction(tx).unwrap();
    let c = Config::try_deserialize(&mut svm.get_account(&addr(config)).unwrap().data.as_slice())
        .unwrap();
    assert_eq!(c.admin, pk(authority.pubkey()));
}

#[test]
fn payout_halt_stops_only_the_crank_and_keeps_accrual() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let stranger = w.stranger.insecure_clone();
    w.allowlist(&allowlister, curator_pk, [3u8; 32]).unwrap();
    w.deposit(&curator, w.curator_ata, 50_000 * USDC).unwrap();
    let t0 = w.now();
    w.treasury_pay(
        w.coupon_ata,
        ix::FundCoupons {
            amount: 5_000 * USDC,
        },
    )
    .unwrap();
    let halt = |w: &World, halted: bool| {
        ixn(
            acc::RevokeAllowlist {
                allowlist_authority: pk(allowlister.pubkey()),
                config: w.config,
                position: w.position_key(curator_pk),
            },
            ix::SetPayoutHalt { halted },
        )
    };
    let bad = ixn(
        acc::RevokeAllowlist {
            allowlist_authority: pk(stranger.pubkey()),
            config: w.config,
            position: w.position_key(curator_pk),
        },
        ix::SetPayoutHalt { halted: true },
    );
    expect_error(w.send(&[bad], &[&stranger]), "ConstraintHasOne");
    let i = halt(&w, true);
    w.send(&[i], &[&allowlister]).unwrap();
    assert!(w.position(curator_pk).payout_halted);
    let oct1 = math::days_from_civil(2026, 10, 1) * DAY;
    w.warp(oct1 + 10);
    expect_error(
        w.pay_coupon(&stranger, curator_pk, w.curator_ata),
        "PayoutHalted",
    );
    // Withdrawal rights are untouched by the halt.
    w.request_withdrawal(&curator).unwrap();
    w.cancel_withdrawal(&curator).unwrap();
    // Lifting the halt pays everything accrued since the deposit, nothing was lost.
    let i = halt(&w, false);
    w.send(&[i], &[&allowlister]).unwrap();
    let (expected, _) = w.expected_coupon(50_000 * USDC, t0, oct1, 0);
    let before = w.balance(w.curator_ata);
    w.pay_coupon(&stranger, curator_pk, w.curator_ata).unwrap();
    assert_eq!(w.balance(w.curator_ata) - before, expected);
    w.assert_invariants("after halt and release");
}

#[test]
fn sweep_recovers_only_unaccounted_coupon_donations() {
    let mut w = setup(true);
    let treasurer = w.treasury_authority.insecure_clone();
    let stranger = w.stranger.insecure_clone();
    w.treasury_pay(
        w.coupon_ata,
        ix::FundCoupons {
            amount: 10_000 * USDC,
        },
    )
    .unwrap();
    let sweep = |w: &World, signer: &Keypair, amount: u64| {
        ixn(
            acc::SweepCoupons {
                treasury_authority: pk(signer.pubkey()),
                config: w.config,
                coupon_ata: w.coupon_ata,
                treasury_ata: pk(w.treasury_ata),
                token_program: token_program(),
            },
            ix::SweepCoupons { amount },
        )
    };
    let i = sweep(&w, &stranger, 1);
    expect_error(w.send(&[i], &[&stranger]), "ConstraintHasOne");
    let i = sweep(&w, &treasurer, 1);
    expect_error(w.send(&[i], &[&treasurer]), "CouponLiabilityReserved");
    let admin = w.admin.insecure_clone();
    MintTo::new(
        &mut w.svm,
        &admin,
        &w.mint,
        &addr(w.coupon_ata),
        4_000 * USDC,
    )
    .send()
    .unwrap();
    let before = w.balance(w.treasury_ata);
    let i = sweep(&w, &treasurer, 4_000 * USDC);
    w.send(&[i], &[&treasurer]).unwrap();
    assert_eq!(w.balance(w.treasury_ata) - before, 4_000 * USDC);
    assert_eq!(w.balance(addr(w.coupon_ata)), 10_000 * USDC);
    assert_eq!(w.config().coupon_funded, 10_000 * USDC);
    w.assert_invariants("after sweep");
}

#[test]
fn unused_coupon_funding_is_withdrawable_only_after_every_position_closes() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let treasurer = w.treasury_authority.insecure_clone();
    let stranger = w.stranger.insecure_clone();
    let t0 = w.now();
    w.treasury_pay(
        w.coupon_ata,
        ix::FundCoupons {
            amount: 10_000 * USDC,
        },
    )
    .unwrap();

    expect_error(
        w.withdraw_unused_coupon_funding(&stranger, USDC),
        "ConstraintHasOne",
    );
    w.allowlist(&allowlister, curator_pk, [30u8; 32]).unwrap();
    expect_error(
        w.withdraw_unused_coupon_funding(&treasurer, USDC),
        "VaultNotEmpty",
    );

    let close = ixn(
        acc::ClosePosition {
            owner: curator_pk,
            config: w.config,
            position: w.position_key(curator_pk),
        },
        ix::ClosePosition {},
    );
    w.send(&[close], &[&curator]).unwrap();
    assert_eq!(w.config().positions, 0);
    w.admin_only(ix::SetPaused { paused: true }).unwrap();
    expect_error(
        w.withdraw_unused_coupon_funding(&treasurer, USDC),
        "Paused",
    );
    w.admin_only(ix::SetPaused { paused: false }).unwrap();
    expect_error(
        w.withdraw_unused_coupon_funding(&treasurer, 10_000 * USDC + 1),
        "CouponLiabilityReserved",
    );

    let treasury_before = w.balance(w.treasury_ata);
    w.withdraw_unused_coupon_funding(&treasurer, 4_000 * USDC)
        .unwrap();
    assert_eq!(w.balance(w.treasury_ata) - treasury_before, 4_000 * USDC);
    assert_eq!(w.balance(addr(w.coupon_ata)), 6_000 * USDC);
    assert_eq!(w.config().coupon_funded, 6_000 * USDC);
    let withdrawn = w.last_event::<events::CouponFundingWithdrawn>();
    assert_eq!(withdrawn.amount, 4_000 * USDC);
    assert_eq!(withdrawn.coupon_funded, 6_000 * USDC);
    assert_eq!(withdrawn.ts, t0);

    w.withdraw_unused_coupon_funding(&treasurer, 6_000 * USDC)
        .unwrap();
    assert_eq!(w.balance(addr(w.coupon_ata)), 0);
    assert_eq!(w.config().coupon_funded, w.config().coupon_paid);
    w.assert_invariants("after terminal coupon-funding withdrawal");
}

#[test]
fn treasury_draws_continue_during_lock_and_stop_at_the_exit_window() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let treasurer = w.treasury_authority.insecure_clone();
    w.allowlist(&allowlister, curator_pk, [31u8; 32]).unwrap();
    w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    w.request_withdrawal(&curator).unwrap();

    // Notice and lock may overlap. Capital remains usable while the contractual lock is live.
    w.draw(&treasurer, USDC).unwrap();
    assert_eq!(w.config().drawn, USDC);
    assert_eq!(w.position(curator_pk).drawn, USDC);
    w.return_principal(curator_pk, USDC).unwrap();

    // At the lock deadline, the pending notice enters the exit window and new exposure stops.
    w.warp(w.position(curator_pk).lock_end);
    let vault_before = w.balance(addr(w.vault_ata));
    let treasury_before = w.balance(w.treasury_ata);
    expect_error(w.draw(&treasurer, USDC), "NoticePending");
    assert_eq!(w.balance(addr(w.vault_ata)), vault_before);
    assert_eq!(w.balance(w.treasury_ata), treasury_before);
    assert_eq!(w.config().drawn, 0);
    assert_eq!(w.position(curator_pk).drawn, 0);

    w.cancel_withdrawal(&curator).unwrap();
    w.draw(&treasurer, USDC).unwrap();
    assert_eq!(w.config().drawn, USDC);
    assert_eq!(w.position(curator_pk).drawn, USDC);
    w.assert_invariants("after exit-window notice cancellation and draw");
}

#[test]
fn admin_rotation_and_bounded_rate_epochs_and_treasury_account_rules() {
    let mut w = setup(true);
    let old_admin = w.admin.insecure_clone();
    let new_admin = Keypair::new();
    w.svm.airdrop(&new_admin.pubkey(), 1_000_000_000).unwrap();
    let now = w.now();
    // a far-future epoch is refused; one within two years is not
    expect_error(
        w.admin_only(ix::SetRate {
            bps: 100,
            start_ts: now + 731 * DAY,
        }),
        "RateTooFar",
    );
    w.admin_only(ix::SetRate {
        bps: 100,
        start_ts: now + 30 * DAY,
    })
    .unwrap();
    // the zero authority is refused; a treasury account not owned by the treasury authority is refused
    expect_error(
        w.send(
            &[ixn(
                acc::SetAuthorities {
                    admin: pk(old_admin.pubkey()),
                    config: w.config,
                    treasury_ata: pk(w.treasury_ata),
                },
                ix::SetAuthorities {
                    allowlist_authority: Pubkey::default(),
                    treasury_authority: pk(w.treasury_authority.pubkey()),
                    emergency_authority: pk(w.emergency_authority.pubkey()),
                },
            )],
            &[&old_admin],
        ),
        "ZeroAuthority",
    );
    expect_error(
        w.send(
            &[ixn(
                acc::SetAuthorities {
                    admin: pk(old_admin.pubkey()),
                    config: w.config,
                    treasury_ata: pk(w.curator_ata),
                },
                ix::SetAuthorities {
                    allowlist_authority: pk(w.allowlist_authority.pubkey()),
                    treasury_authority: pk(w.treasury_authority.pubkey()),
                    emergency_authority: pk(w.emergency_authority.pubkey()),
                },
            )],
            &[&old_admin],
        ),
        "WrongTokenAccount",
    );
    // Admin rotation is two-step: the old key remains active until the proposed key accepts.
    expect_error(
        w.admin_only(ix::ProposeAdmin {
            new_admin: Pubkey::default(),
        }),
        "ZeroAuthority",
    );
    w.admin_only(ix::ProposeAdmin {
        new_admin: pk(new_admin.pubkey()),
    })
    .unwrap();
    assert_eq!(w.config().admin, pk(old_admin.pubkey()));
    assert_eq!(w.config().pending_admin, pk(new_admin.pubkey()));
    let stranger = w.stranger.insecure_clone();
    let bad_accept = ixn(
        acc::AcceptAdmin {
            pending_admin: pk(stranger.pubkey()),
            config: w.config,
        },
        ix::AcceptAdmin {},
    );
    expect_error(w.send(&[bad_accept], &[&stranger]), "NotPendingAdmin");
    let accept = ixn(
        acc::AcceptAdmin {
            pending_admin: pk(new_admin.pubkey()),
            config: w.config,
        },
        ix::AcceptAdmin {},
    );
    w.send(&[accept], &[&new_admin]).unwrap();
    assert_eq!(w.config().admin, pk(new_admin.pubkey()));
    assert_eq!(w.config().pending_admin, Pubkey::default());
    expect_error(
        w.admin_only(ix::SetPaused { paused: true }),
        "ConstraintHasOne",
    );
    let i = ixn(
        acc::AdminOnly {
            admin: pk(new_admin.pubkey()),
            config: w.config,
        },
        ix::SetPaused { paused: true },
    );
    w.send(&[i], &[&new_admin]).unwrap();
    assert!(w.config().paused);
}

#[test]
fn a_loss_that_wipes_a_position_preserves_the_curators_notice() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let treasurer = w.treasury_authority.insecure_clone();
    let t0 = w.now();
    w.allowlist(&allowlister, curator_pk, [4u8; 32]).unwrap();
    w.deposit(&curator, w.curator_ata, 1_000 * USDC).unwrap();
    w.draw(&treasurer, 1_000 * USDC).unwrap();
    w.request_withdrawal(&curator).unwrap();
    w.record_loss(curator_pk, 1_000 * USDC, [5u8; 32]).unwrap();
    let p = w.position(curator_pk);
    assert_eq!(
        (
            p.principal,
            p.lock_end,
            p.notice_requested_at,
            p.withdrawal_eligible_at
        ),
        (0, t0 + LOCK as i64, t0, t0 + NOTICE as i64)
    );
    assert_eq!((w.config().total_principal, w.config().drawn), (0, 0));
    w.assert_invariants("after a wipe-out");
    // Only the curator decides to give up that notice before opening a fresh position.
    expect_error(
        w.deposit(&curator, w.curator_ata, 10 * USDC),
        "NoticePending",
    );
    w.cancel_withdrawal(&curator).unwrap();
    w.deposit(&curator, w.curator_ata, 10 * USDC).unwrap();
    assert_eq!(w.position(curator_pk).lock_end, w.now() + LOCK as i64);
}

#[test]
fn midmonth_checkpoints_never_pay_coupon_past_the_completed_boundary() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let stranger = w.stranger.insecure_clone();
    w.allowlist(&allowlister, curator_pk, [10u8; 32]).unwrap();
    w.deposit(&curator, w.curator_ata, 500_000 * USDC).unwrap();

    let oct1 = math::days_from_civil(2026, 10, 1) * DAY;
    let oct15 = math::days_from_civil(2026, 10, 15) * DAY;
    w.warp(oct15);
    // A principal change checkpoints both sides of 1 October. Only the first side matures.
    w.deposit(&curator, w.curator_ata, USDC).unwrap();
    let before_payment = w.position(curator_pk);
    assert!(before_payment.coupon_payable > 0);
    assert!(before_payment.coupon_owed > before_payment.coupon_payable);
    assert_eq!(before_payment.coupon_accrued_through, oct15);
    let deferred = before_payment.coupon_owed - before_payment.coupon_payable;
    w.treasury_pay(
        w.coupon_ata,
        ix::FundCoupons {
            amount: 100_000 * USDC,
        },
    )
    .unwrap();
    let before = w.balance(w.curator_ata);
    w.pay_coupon(&stranger, curator_pk, w.curator_ata).unwrap();
    assert_eq!(
        w.balance(w.curator_ata) - before,
        before_payment.coupon_payable
    );
    assert_eq!(w.position(curator_pk).coupon_owed, deferred);
    assert_eq!(w.position(curator_pk).coupon_paid_through, oct1);
    expect_error(
        w.pay_coupon(&stranger, curator_pk, w.curator_ata),
        "NothingDue",
    );

    let nov1 = math::days_from_civil(2026, 11, 1) * DAY;
    let p = w.position(curator_pk);
    let (later, _) = w.expected_coupon(
        p.principal,
        p.coupon_accrued_through,
        nov1,
        p.coupon_remainder,
    );
    w.warp(nov1 + 1);
    let before = w.balance(w.curator_ata);
    w.pay_coupon(&stranger, curator_pk, w.curator_ata).unwrap();
    assert_eq!(w.balance(w.curator_ata) - before, deferred + later);
    assert_eq!(w.position(curator_pk).coupon_owed, 0);
    w.assert_invariants("after separated boundary payments");
}

#[test]
fn reopened_position_gets_a_fresh_payment_boundary_and_current_terms() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let stranger = w.stranger.insecure_clone();
    w.allowlist(&allowlister, curator_pk, [11u8; 32]).unwrap();
    w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    w.request_withdrawal(&curator).unwrap();
    let eligible = w.position(curator_pk).withdrawal_eligible_at;
    w.warp(eligible);
    w.withdraw(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    let january = math::next_month_start(w.now()) + 1;
    w.warp(january);
    w.treasury_pay(
        w.coupon_ata,
        ix::FundCoupons {
            amount: 100_000 * USDC,
        },
    )
    .unwrap();
    w.pay_coupon(&stranger, curator_pk, w.curator_ata).unwrap();
    assert_eq!(w.position(curator_pk).coupon_owed, 0);

    w.admin_only(ix::SetTerms {
        lock_seconds: 120 * DAY as u64,
        notice_seconds: 150 * DAY as u64,
    })
    .unwrap();
    let march5 = math::days_from_civil(2027, 3, 5) * DAY;
    w.warp(march5);
    w.deposit(&curator, w.curator_ata, 50_000 * USDC).unwrap();
    let reopened = w.position(curator_pk);
    assert_eq!(
        (reopened.lock_seconds, reopened.notice_seconds),
        (120 * DAY as u64, 150 * DAY as u64)
    );
    assert_eq!(reopened.coupon_paid_through, math::month_start(march5));
    w.warp(math::days_from_civil(2027, 3, 20) * DAY);
    w.deposit(&curator, w.curator_ata, USDC).unwrap();
    expect_error(
        w.pay_coupon(&stranger, curator_pk, w.curator_ata),
        "NothingDue",
    );
}

#[test]
fn draws_returns_losses_and_withdrawals_are_attributed_per_position() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let second = w.stranger.insecure_clone();
    let second_pk = pk(second.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let treasurer = w.treasury_authority.insecure_clone();
    w.allowlist(&allowlister, curator_pk, [12u8; 32]).unwrap();
    w.allowlist(&allowlister, second_pk, [13u8; 32]).unwrap();
    w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    w.deposit(&second, w.stranger_ata, 100_000 * USDC).unwrap();

    w.draw_for(&treasurer, curator_pk, 100_000 * USDC).unwrap();
    expect_error(w.record_loss(second_pk, 1, [1u8; 32]), "LossExceedsDrawn");
    w.request_withdrawal(&curator).unwrap();
    w.warp(w.position(curator_pk).withdrawal_eligible_at);
    expect_error(
        w.withdraw(&curator, w.curator_ata, 1),
        "PositionCapitalDrawn",
    );
    w.return_principal(curator_pk, 100_000 * USDC).unwrap();
    w.withdraw(&curator, w.curator_ata, 100_000 * USDC).unwrap();

    w.draw_for(&treasurer, second_pk, 40_000 * USDC).unwrap();
    w.record_loss(second_pk, 40_000 * USDC, [2u8; 32]).unwrap();
    let p2 = w.position(second_pk);
    assert_eq!((p2.principal, p2.drawn), (60_000 * USDC, 0));
    assert_eq!(
        (w.config().total_principal, w.config().drawn),
        (60_000 * USDC, 0)
    );
    w.assert_invariants("after position-attributed draw and loss");
}

#[test]
fn direct_token_donations_are_accounted_or_recoverable_without_touching_obligations() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let treasurer = w.treasury_authority.insecure_clone();
    let stranger = w.stranger.insecure_clone();
    let admin = w.admin.insecure_clone();
    w.allowlist(&allowlister, curator_pk, [14u8; 32]).unwrap();
    w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    let boundary = math::next_month_start(w.now()) + 1;
    w.warp(boundary);

    MintTo::new(
        &mut w.svm,
        &admin,
        &w.mint,
        &addr(w.coupon_ata),
        10_000 * USDC,
    )
    .send()
    .unwrap();
    let before = w.balance(w.curator_ata);
    w.pay_coupon(&stranger, curator_pk, w.curator_ata).unwrap();
    let paid = w.balance(w.curator_ata) - before;
    assert!(paid > 0);
    assert_eq!(w.config().coupon_funded, paid);
    assert_eq!(w.config().coupon_paid, paid);
    let donation_left = w.balance(addr(w.coupon_ata));
    let sweep = ixn(
        acc::SweepCoupons {
            treasury_authority: pk(treasurer.pubkey()),
            config: w.config,
            coupon_ata: w.coupon_ata,
            treasury_ata: pk(w.treasury_ata),
            token_program: token_program(),
        },
        ix::SweepCoupons {
            amount: donation_left,
        },
    );
    w.send(&[sweep], &[&treasurer]).unwrap();
    assert_eq!(w.balance(addr(w.coupon_ata)), 0);
    assert_eq!(w.config().coupon_funded, paid);

    MintTo::new(
        &mut w.svm,
        &admin,
        &w.mint,
        &addr(w.vault_ata),
        5_000 * USDC,
    )
    .send()
    .unwrap();
    let treasury_before = w.balance(w.treasury_ata);
    let sweep_principal = ixn(
        acc::SweepPrincipalSurplus {
            treasury_authority: pk(treasurer.pubkey()),
            config: w.config,
            vault_ata: w.vault_ata,
            treasury_ata: pk(w.treasury_ata),
            token_program: token_program(),
        },
        ix::SweepPrincipalSurplus {
            amount: 5_000 * USDC,
        },
    );
    w.send(&[sweep_principal], &[&treasurer]).unwrap();
    assert_eq!(w.balance(w.treasury_ata) - treasury_before, 5_000 * USDC);
    w.assert_invariants("after donation recovery");
}

#[test]
fn emergency_authority_is_one_way_and_existing_positions_keep_their_terms() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let emergency = w.emergency_authority.insecure_clone();
    let stranger = w.stranger.insecure_clone();
    let t0 = w.now();
    w.allowlist(&allowlister, curator_pk, [15u8; 32]).unwrap();
    w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    w.admin_only(ix::SetTerms {
        lock_seconds: 730 * DAY as u64,
        notice_seconds: 730 * DAY as u64,
    })
    .unwrap();
    w.request_withdrawal(&curator).unwrap();
    assert_eq!(
        w.position(curator_pk).withdrawal_eligible_at,
        t0 + NOTICE as i64
    );

    let bad_pause = ixn(
        acc::EmergencyOnly {
            emergency_authority: pk(stranger.pubkey()),
            config: w.config,
        },
        ix::EmergencyPause {},
    );
    expect_error(w.send(&[bad_pause], &[&stranger]), "ConstraintHasOne");
    let pause = ixn(
        acc::EmergencyOnly {
            emergency_authority: pk(emergency.pubkey()),
            config: w.config,
        },
        ix::EmergencyPause {},
    );
    w.send(&[pause], &[&emergency]).unwrap();
    assert!(w.config().paused);
    w.admin_only(ix::SetPaused { paused: false }).unwrap();

    let bad_halt = ixn(
        acc::EmergencyHalt {
            emergency_authority: pk(stranger.pubkey()),
            config: w.config,
            position: w.position_key(curator_pk),
        },
        ix::EmergencyHalt {},
    );
    expect_error(w.send(&[bad_halt], &[&stranger]), "ConstraintHasOne");
    let halt = ixn(
        acc::EmergencyHalt {
            emergency_authority: pk(emergency.pubkey()),
            config: w.config,
            position: w.position_key(curator_pk),
        },
        ix::EmergencyHalt {},
    );
    w.send(&[halt], &[&emergency]).unwrap();
    assert!(w.position(curator_pk).payout_halted);
    let clear = ixn(
        acc::RevokeAllowlist {
            allowlist_authority: pk(allowlister.pubkey()),
            config: w.config,
            position: w.position_key(curator_pk),
        },
        ix::SetPayoutHalt { halted: false },
    );
    w.send(&[clear], &[&allowlister]).unwrap();
    assert!(!w.position(curator_pk).payout_halted);
}

#[test]
fn associated_accounts_reallowlisting_and_live_treasury_ownership_are_enforced() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let treasurer = w.treasury_authority.insecure_clone();
    let stranger = w.stranger.insecure_clone();
    expect_error(
        w.allowlist(&allowlister, Pubkey::default(), [16u8; 32]),
        "ZeroAuthority",
    );
    w.allowlist(&allowlister, curator_pk, [16u8; 32]).unwrap();

    let non_ata = CreateTokenAccount::new(&mut w.svm, &w.admin, &w.mint)
        .owner(&curator.pubkey())
        .send()
        .unwrap();
    expect_error(
        w.deposit(&curator, non_ata, USDC),
        "WrongAssociatedTokenAccount",
    );
    w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    let revoke = ixn(
        acc::RevokeAllowlist {
            allowlist_authority: pk(allowlister.pubkey()),
            config: w.config,
            position: w.position_key(curator_pk),
        },
        ix::RevokeAllowlist {},
    );
    w.send(&[revoke], &[&allowlister]).unwrap();
    expect_error(
        w.allowlist(&allowlister, curator_pk, [17u8; 32]),
        "AgreementChangeWithBalance",
    );
    w.allowlist(&allowlister, curator_pk, [16u8; 32]).unwrap();
    assert_eq!(w.config().positions, 1);

    let boundary = math::next_month_start(w.now()) + 1;
    w.warp(boundary);
    w.treasury_pay(
        w.coupon_ata,
        ix::FundCoupons {
            amount: 10_000 * USDC,
        },
    )
    .unwrap();
    expect_error(
        w.pay_coupon(&stranger, curator_pk, non_ata),
        "WrongAssociatedTokenAccount",
    );

    SetAuthority::new(
        &mut w.svm,
        &treasurer,
        &w.treasury_ata,
        AuthorityType::AccountOwner,
    )
    .new_authority(&stranger.pubkey())
    .send()
    .unwrap();
    expect_error(w.draw(&treasurer, 1), "WrongTokenAccount");
}

#[test]
fn treasury_destination_owner_is_rechecked_by_every_sweep() {
    let mut w = setup(true);
    let admin = w.admin.insecure_clone();
    let treasurer = w.treasury_authority.insecure_clone();
    let stranger = w.stranger.insecure_clone();

    // Give each pool an unaccounted unit, so removing the live destination-owner constraint
    // makes both transfers succeed. That makes this a direct regression for the account guard,
    // rather than a test that happens to revert later for lack of surplus.
    MintTo::new(&mut w.svm, &admin, &w.mint, &addr(w.coupon_ata), USDC)
        .send()
        .unwrap();
    MintTo::new(&mut w.svm, &admin, &w.mint, &addr(w.vault_ata), USDC)
        .send()
        .unwrap();
    SetAuthority::new(
        &mut w.svm,
        &treasurer,
        &w.treasury_ata,
        AuthorityType::AccountOwner,
    )
    .new_authority(&stranger.pubkey())
    .send()
    .unwrap();

    expect_error(w.sweep_coupons(&treasurer, USDC), "WrongTokenAccount");
    expect_error(
        w.sweep_principal_surplus(&treasurer, USDC),
        "WrongTokenAccount",
    );
}

#[test]
fn declared_accounting_and_authorization_failures_revert_with_their_named_errors() {
    // Revocation reaches the program's allowlist refusal (rather than failing because the
    // position account does not exist), and a valid owner account for another mint is refused.
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let treasurer = w.treasury_authority.insecure_clone();
    let admin = w.admin.insecure_clone();
    w.allowlist(&allowlister, curator_pk, [22u8; 32]).unwrap();
    let revoke = ixn(
        acc::RevokeAllowlist {
            allowlist_authority: pk(allowlister.pubkey()),
            config: w.config,
            position: w.position_key(curator_pk),
        },
        ix::RevokeAllowlist {},
    );
    w.send(&[revoke], &[&allowlister]).unwrap();
    expect_error(w.deposit(&curator, w.curator_ata, USDC), "NotAllowlisted");
    w.allowlist(&allowlister, curator_pk, [22u8; 32]).unwrap();
    let other_mint = CreateMint::new(&mut w.svm, &admin)
        .decimals(6)
        .authority(&admin.pubkey())
        .send()
        .unwrap();
    let wrong_mint_ata = CreateAssociatedTokenAccount::new(&mut w.svm, &admin, &other_mint)
        .owner(&curator.pubkey())
        .send()
        .unwrap();
    expect_error(w.deposit(&curator, wrong_mint_ata, USDC), "WrongMint");

    w.deposit(&curator, w.curator_ata, 100 * USDC).unwrap();
    expect_error(
        w.record_loss(curator_pk, 101 * USDC, [23u8; 32]),
        "LossExceedsPrincipal",
    );
    expect_error(w.sweep_principal_surplus(&treasurer, 1), "SweepExceedsPool");

    w.request_withdrawal(&curator).unwrap();
    w.warp(w.position(curator_pk).withdrawal_eligible_at);
    w.set_token_amount_for_negative_test(w.vault_ata, 0);
    expect_error(
        w.withdraw(&curator, w.curator_ata, 1),
        "InsufficientVaultLiquidity",
    );

    // A stored layout version from a future program is refused before any state mutation.
    let mut version_book = setup(true);
    let mut bad_version = version_book.config();
    bad_version.version = bad_version.version.saturating_add(1);
    version_book.set_config_for_negative_test(&bad_version);
    expect_error(
        version_book.admin_only(ix::SetPaused { paused: true }),
        "UnsupportedVersion",
    );
    assert!(!version_book.config().paused);

    // Arithmetic overflow is tested against a deliberately corrupted near-maximum aggregate;
    // the failed transaction must roll the preceding SPL transfer and position addition back.
    let mut overflow_book = setup(true);
    let overflow_owner = overflow_book.curator.insecure_clone();
    let overflow_allowlister = overflow_book.allowlist_authority.insecure_clone();
    let overflow_owner_pk = pk(overflow_owner.pubkey());
    overflow_book
        .allowlist(&overflow_allowlister, overflow_owner_pk, [24u8; 32])
        .unwrap();
    let before_tokens = overflow_book.balance(overflow_book.curator_ata);
    let mut corrupted = overflow_book.config();
    corrupted.total_principal = u64::MAX;
    overflow_book.set_config_for_negative_test(&corrupted);
    expect_error(
        overflow_book.deposit(&overflow_owner, overflow_book.curator_ata, 1),
        "Overflow",
    );
    assert_eq!(
        overflow_book.balance(overflow_book.curator_ata),
        before_tokens
    );
    assert_eq!(overflow_book.position(overflow_owner_pk).principal, 0);

    // A physical coupon deficit relative to the funding ledger fails loudly.
    let mut mismatch_book = setup(true);
    let mismatch_treasurer = mismatch_book.treasury_authority.insecure_clone();
    mismatch_book
        .treasury_pay(mismatch_book.coupon_ata, ix::FundCoupons { amount: USDC })
        .unwrap();
    mismatch_book.set_token_amount_for_negative_test(mismatch_book.coupon_ata, 0);
    let sweep = ixn(
        acc::SweepCoupons {
            treasury_authority: pk(mismatch_treasurer.pubkey()),
            config: mismatch_book.config,
            coupon_ata: mismatch_book.coupon_ata,
            treasury_ata: pk(mismatch_book.treasury_ata),
            token_program: token_program(),
        },
        ix::SweepCoupons { amount: 1 },
    );
    expect_error(
        mismatch_book.send(&[sweep], &[&mismatch_treasurer]),
        "AccountingMismatch",
    );
}

#[test]
fn partial_withdrawals_keep_notice_and_cross_position_accounts_are_refused() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let second = w.stranger.insecure_clone();
    let second_pk = pk(second.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    w.allowlist(&allowlister, curator_pk, [25u8; 32]).unwrap();
    w.allowlist(&allowlister, second_pk, [26u8; 32]).unwrap();
    w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    w.deposit(&second, w.stranger_ata, 100_000 * USDC).unwrap();

    let crossed = ixn(
        acc::CuratorTransfer {
            owner: curator_pk,
            config: w.config,
            position: w.position_key(second_pk),
            vault_ata: w.vault_ata,
            owner_ata: pk(w.curator_ata),
            token_program: token_program(),
        },
        ix::Deposit { amount: USDC },
    );
    expect_error(w.send(&[crossed], &[&curator]), "ConstraintSeeds");

    w.request_withdrawal(&curator).unwrap();
    let before = w.position(curator_pk);
    w.warp(before.withdrawal_eligible_at);
    w.withdraw(&curator, w.curator_ata, 40_000 * USDC).unwrap();
    let partial = w.position(curator_pk);
    assert_eq!(partial.principal, 60_000 * USDC);
    assert_eq!(partial.notice_requested_at, before.notice_requested_at);
    assert_eq!(
        partial.withdrawal_eligible_at,
        before.withdrawal_eligible_at
    );
    w.withdraw(&curator, w.curator_ata, 60_000 * USDC).unwrap();
    let closed = w.position(curator_pk);
    assert_eq!(closed.principal, 0);
    assert_eq!(closed.notice_requested_at, 0);
    assert_eq!(closed.withdrawal_eligible_at, 0);
    w.assert_invariants("after partial and final withdrawal");
}

#[test]
fn accrued_coupon_is_reserved_against_every_sweep() {
    let mut w = setup(true);
    let curator = w.curator.insecure_clone();
    let curator_pk = pk(curator.pubkey());
    let allowlister = w.allowlist_authority.insecure_clone();
    let treasurer = w.treasury_authority.insecure_clone();
    let stranger = w.stranger.insecure_clone();
    w.allowlist(&allowlister, curator_pk, [18u8; 32]).unwrap();
    w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
    w.warp(math::next_month_start(w.now()) + 10 * DAY);
    w.deposit(&curator, w.curator_ata, USDC).unwrap();
    let owed = w.config().coupon_owed_total;
    assert!(owed > 0);
    w.treasury_pay(
        w.coupon_ata,
        ix::FundCoupons {
            amount: 10_000 * USDC,
        },
    )
    .unwrap();
    let sweep = |w: &World, amount: u64| {
        ixn(
            acc::SweepCoupons {
                treasury_authority: pk(treasurer.pubkey()),
                config: w.config,
                coupon_ata: w.coupon_ata,
                treasury_ata: pk(w.treasury_ata),
                token_program: token_program(),
            },
            ix::SweepCoupons { amount },
        )
    };
    let i = sweep(&w, 10_000 * USDC);
    expect_error(w.send(&[i], &[&treasurer]), "CouponLiabilityReserved");
    let i = sweep(&w, 1);
    expect_error(w.send(&[i], &[&treasurer]), "CouponLiabilityReserved");
    let admin = w.admin.insecure_clone();
    MintTo::new(&mut w.svm, &admin, &w.mint, &addr(w.coupon_ata), 123)
        .send()
        .unwrap();
    let i = sweep(&w, 123);
    w.send(&[i], &[&treasurer]).unwrap();
    assert_eq!(w.balance(addr(w.coupon_ata)), 10_000 * USDC);
    assert_eq!(w.config().coupon_funded, 10_000 * USDC);
    w.pay_coupon(&stranger, curator_pk, w.curator_ata).unwrap();
    assert_eq!(
        w.config().coupon_owed_total,
        w.position(curator_pk).coupon_owed
    );
}

#[test]
fn authority_rotation_changes_every_live_gate_together() {
    let mut w = setup(true);
    let old_admin = w.admin.insecure_clone();
    let old_allowlister = w.allowlist_authority.insecure_clone();
    let old_treasurer = w.treasury_authority.insecure_clone();
    let old_emergency = w.emergency_authority.insecure_clone();
    let new_allowlister = Keypair::new();
    let new_treasurer = Keypair::new();
    let new_emergency = Keypair::new();
    for key in [&new_allowlister, &new_treasurer, &new_emergency] {
        w.svm.airdrop(&key.pubkey(), 10_000_000_000).unwrap();
    }
    let new_treasury_ata = CreateAssociatedTokenAccount::new(&mut w.svm, &old_admin, &w.mint)
        .owner(&new_treasurer.pubkey())
        .send()
        .unwrap();
    MintTo::new(
        &mut w.svm,
        &old_admin,
        &w.mint,
        &new_treasury_ata,
        100_000 * USDC,
    )
    .send()
    .unwrap();
    let rotate = ixn(
        acc::SetAuthorities {
            admin: pk(old_admin.pubkey()),
            config: w.config,
            treasury_ata: pk(new_treasury_ata),
        },
        ix::SetAuthorities {
            allowlist_authority: pk(new_allowlister.pubkey()),
            treasury_authority: pk(new_treasurer.pubkey()),
            emergency_authority: pk(new_emergency.pubkey()),
        },
    );
    w.send(&[rotate], &[&old_admin]).unwrap();
    let owner = pk(w.curator.pubkey());
    expect_error(
        w.allowlist(&old_allowlister, owner, [19u8; 32]),
        "ConstraintHasOne",
    );
    w.allowlist(&new_allowlister, owner, [19u8; 32]).unwrap();
    let curator = w.curator.insecure_clone();
    w.deposit(&curator, w.curator_ata, 1_000 * USDC).unwrap();
    expect_error(w.draw(&old_treasurer, 1), "ConstraintHasOne");
    let draw = ixn(
        acc::DrawToTreasury {
            treasury_authority: pk(new_treasurer.pubkey()),
            config: w.config,
            position: w.position_key(owner),
            vault_ata: w.vault_ata,
            treasury_ata: pk(new_treasury_ata),
            token_program: token_program(),
        },
        ix::DrawToTreasury { amount: USDC },
    );
    w.send(&[draw], &[&new_treasurer]).unwrap();
    let old_pause = ixn(
        acc::EmergencyOnly {
            emergency_authority: pk(old_emergency.pubkey()),
            config: w.config,
        },
        ix::EmergencyPause {},
    );
    expect_error(w.send(&[old_pause], &[&old_emergency]), "ConstraintHasOne");
    let new_pause = ixn(
        acc::EmergencyOnly {
            emergency_authority: pk(new_emergency.pubkey()),
            config: w.config,
        },
        ix::EmergencyPause {},
    );
    w.send(&[new_pause], &[&new_emergency]).unwrap();
    assert!(w.config().paused);
}

fn campaign_next(state: &mut u64) -> u64 {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    *state
}

/// Exercises the guards represented by the committed program mutations from inside the stateful
/// campaign. Each case has a deterministic expected outcome, so a defective build cannot retain
/// the same campaign statistics merely because random generation avoided its changed branch.
fn assert_campaign_guard_oracles() -> usize {
    let mut checked_outcomes = 0usize;

    // Completed-month accounting must leave the current partial month owed but not payable.
    {
        let mut w = setup(true);
        let curator = w.curator.insecure_clone();
        let owner = pk(curator.pubkey());
        let allowlister = w.allowlist_authority.insecure_clone();
        w.allowlist(&allowlister, owner, [40u8; 32]).unwrap();
        w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
        w.warp(math::days_from_civil(2026, 10, 15) * DAY);
        w.deposit(&curator, w.curator_ata, USDC).unwrap();
        let position = w.position(owner);
        assert!(
            position.coupon_owed > position.coupon_payable,
            "campaign oracle: partial-month coupon became payable early"
        );
        checked_outcomes += 1;
    }

    // A draw attributed to one position cannot support a loss against another position.
    {
        let mut w = setup(true);
        let first = w.curator.insecure_clone();
        let second = w.stranger.insecure_clone();
        let first_pk = pk(first.pubkey());
        let second_pk = pk(second.pubkey());
        let allowlister = w.allowlist_authority.insecure_clone();
        let treasurer = w.treasury_authority.insecure_clone();
        w.allowlist(&allowlister, first_pk, [41u8; 32]).unwrap();
        w.allowlist(&allowlister, second_pk, [42u8; 32]).unwrap();
        w.deposit(&first, w.curator_ata, 100_000 * USDC).unwrap();
        w.deposit(&second, w.stranger_ata, 100_000 * USDC).unwrap();
        w.draw_for(&treasurer, first_pk, USDC).unwrap();
        expect_error(w.record_loss(second_pk, 1, [43u8; 32]), "LossExceedsDrawn");
        checked_outcomes += 1;
    }

    // Accounted coupon funding is never donation surplus.
    {
        let mut w = setup(true);
        let treasurer = w.treasury_authority.insecure_clone();
        w.treasury_pay(
            w.coupon_ata,
            ix::FundCoupons {
                amount: 10_000 * USDC,
            },
        )
        .unwrap();
        expect_error(w.sweep_coupons(&treasurer, 1), "CouponLiabilityReserved");
        checked_outcomes += 1;
    }

    // The emergency path accepts only the configured one-way authority.
    {
        let mut w = setup(true);
        let stranger = w.stranger.insecure_clone();
        let bad_pause = ixn(
            acc::EmergencyOnly {
                emergency_authority: pk(stranger.pubkey()),
                config: w.config,
            },
            ix::EmergencyPause {},
        );
        expect_error(w.send(&[bad_pause], &[&stranger]), "ConstraintHasOne");
        checked_outcomes += 1;
    }

    // Existing principal keeps its snapshotted notice term after global terms change.
    {
        let mut w = setup(true);
        let curator = w.curator.insecure_clone();
        let owner = pk(curator.pubkey());
        let allowlister = w.allowlist_authority.insecure_clone();
        let requested_at = w.now();
        w.allowlist(&allowlister, owner, [44u8; 32]).unwrap();
        w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
        w.admin_only(ix::SetTerms {
            lock_seconds: 730 * DAY as u64,
            notice_seconds: 730 * DAY as u64,
        })
        .unwrap();
        w.request_withdrawal(&curator).unwrap();
        assert_eq!(
            w.position(owner).withdrawal_eligible_at,
            requested_at + NOTICE as i64,
            "campaign oracle: mutable global notice changed an existing position"
        );
        checked_outcomes += 1;
    }

    // Both sweep paths re-check the live owner of the pinned treasury token account.
    {
        let mut w = setup(true);
        let admin = w.admin.insecure_clone();
        let treasurer = w.treasury_authority.insecure_clone();
        let stranger = w.stranger.insecure_clone();
        MintTo::new(&mut w.svm, &admin, &w.mint, &addr(w.coupon_ata), USDC)
            .send()
            .unwrap();
        SetAuthority::new(
            &mut w.svm,
            &treasurer,
            &w.treasury_ata,
            AuthorityType::AccountOwner,
        )
        .new_authority(&stranger.pubkey())
        .send()
        .unwrap();
        expect_error(w.sweep_coupons(&treasurer, USDC), "WrongTokenAccount");
        checked_outcomes += 1;
    }

    // Accounted coupon funding cannot leave while any position account remains.
    {
        let mut w = setup(true);
        let curator = w.curator.insecure_clone();
        let owner = pk(curator.pubkey());
        let allowlister = w.allowlist_authority.insecure_clone();
        let treasurer = w.treasury_authority.insecure_clone();
        w.allowlist(&allowlister, owner, [45u8; 32]).unwrap();
        w.treasury_pay(
            w.coupon_ata,
            ix::FundCoupons {
                amount: 10_000 * USDC,
            },
        )
        .unwrap();
        expect_error(
            w.withdraw_unused_coupon_funding(&treasurer, USDC),
            "VaultNotEmpty",
        );
        checked_outcomes += 1;
    }

    // Notice does not idle capital during the lock, then blocks new exposure at the lock deadline.
    {
        let mut w = setup(true);
        let curator = w.curator.insecure_clone();
        let owner = pk(curator.pubkey());
        let allowlister = w.allowlist_authority.insecure_clone();
        let treasurer = w.treasury_authority.insecure_clone();
        w.allowlist(&allowlister, owner, [46u8; 32]).unwrap();
        w.deposit(&curator, w.curator_ata, 100_000 * USDC).unwrap();
        w.request_withdrawal(&curator).unwrap();
        w.draw(&treasurer, USDC).unwrap();
        w.return_principal(owner, USDC).unwrap();
        w.warp(w.position(owner).lock_end);
        expect_error(w.draw(&treasurer, USDC), "NoticePending");
        checked_outcomes += 1;
    }

    // The global pause also covers the terminal treasury outflow of unused coupon funding.
    {
        let mut w = setup(true);
        let treasurer = w.treasury_authority.insecure_clone();
        w.treasury_pay(
            w.coupon_ata,
            ix::FundCoupons {
                amount: 10_000 * USDC,
            },
        )
        .unwrap();
        w.admin_only(ix::SetPaused { paused: true }).unwrap();
        expect_error(
            w.withdraw_unused_coupon_funding(&treasurer, USDC),
            "Paused",
        );
        checked_outcomes += 1;
    }

    checked_outcomes
}

#[test]
fn stateful_instruction_sequences_preserve_the_program_invariants() {
    // Thirty-two independent books, 96 randomized steps each. Every transaction outcome is
    // asserted: admissible actions must succeed and deliberately invalid actions must return the
    // named error. Each book also completes a real post-lock withdrawal before randomization, so
    // the campaign cannot silently spend all of its time in the Locked branch.
    let guard_oracle_checks = assert_campaign_guard_oracles();
    let mut state_checks = 0usize;
    let mut successful_transactions = 0usize;
    let mut rejected_transactions = 0usize;
    let mut successful_withdrawals = 0usize;
    let mut eligible_states_observed = 0usize;
    for seed in 1u64..=32 {
        let mut w = setup(true);
        let curator = w.curator.insecure_clone();
        let second = w.stranger.insecure_clone();
        let third = w.third.insecure_clone();
        let mint_authority = w.admin.insecure_clone();
        let curator_pk = pk(curator.pubkey());
        let second_pk = pk(second.pubkey());
        let third_pk = pk(third.pubkey());
        let allowlister = w.allowlist_authority.insecure_clone();
        let treasurer = w.treasury_authority.insecure_clone();
        w.allowlist(&allowlister, curator_pk, [20u8; 32]).unwrap();
        w.allowlist(&allowlister, second_pk, [21u8; 32]).unwrap();
        w.allowlist(&allowlister, third_pk, [22u8; 32]).unwrap();
        w.deposit(&curator, w.curator_ata, (20_000 + seed) * USDC)
            .unwrap();
        w.deposit(&second, w.stranger_ata, (30_000 + seed) * USDC)
            .unwrap();
        w.deposit(&third, w.third_ata, (40_000 + seed) * USDC)
            .unwrap();
        w.treasury_pay(
            w.coupon_ata,
            ix::FundCoupons {
                amount: 100_000 * USDC,
            },
        )
        .unwrap();
        successful_transactions += 8; // initialize, three allowlists, three deposits and funding

        // Guaranteed reachable success on the withdrawal path for every independent book.
        w.request_withdrawal(&curator).unwrap();
        successful_transactions += 1;
        let eligible = w.position(curator_pk).withdrawal_eligible_at;
        w.warp(eligible);
        eligible_states_observed += 1;
        w.withdraw(&curator, w.curator_ata, USDC).unwrap();
        successful_transactions += 1;
        successful_withdrawals += 1;
        w.cancel_withdrawal(&curator).unwrap();
        successful_transactions += 1;
        w.assert_invariants(&format!("campaign seed {seed}, guaranteed withdrawal"));

        let mut random = seed.wrapping_mul(0x9e37_79b9_7f4a_7c15);
        for step in 0..96 {
            let value = campaign_next(&mut random);
            let selected = (value % 3) as u8;
            let (owner, owner_key, owner_ata, agreement_hash) = match selected {
                0 => (curator_pk, &curator, w.curator_ata, [20u8; 32]),
                1 => (second_pk, &second, w.stranger_ata, [21u8; 32]),
                _ => (third_pk, &third, w.third_ata, [22u8; 32]),
            };
            match (value >> 2) % 18 {
                0 => {
                    w.warp(w.now() + ((value % 45) as i64 + 1) * DAY);
                }
                1 => {
                    let position = w.position(owner);
                    if w.config().paused {
                        w.admin_only(ix::SetPaused { paused: false }).unwrap();
                        successful_transactions += 1;
                    }
                    if position.notice_requested_at != 0 {
                        w.cancel_withdrawal(owner_key).unwrap();
                        successful_transactions += 1;
                    }
                    if !w.position(owner).allowlisted {
                        w.allowlist(&allowlister, owner, agreement_hash).unwrap();
                        successful_transactions += 1;
                    }
                    w.deposit(owner_key, owner_ata, (value % 25 + 1) * USDC)
                        .unwrap();
                    successful_transactions += 1;
                }
                2 => {
                    if w.position(owner).notice_requested_at == 0 {
                        w.request_withdrawal(owner_key).unwrap();
                    } else {
                        w.cancel_withdrawal(owner_key).unwrap();
                    }
                    successful_transactions += 1;
                }
                3 => {
                    if w.config().paused {
                        w.admin_only(ix::SetPaused { paused: false }).unwrap();
                        successful_transactions += 1;
                    }
                    let mut position = w.position(owner);
                    if position.notice_requested_at != 0 {
                        w.cancel_withdrawal(owner_key).unwrap();
                        successful_transactions += 1;
                        position = w.position(owner);
                    }
                    let available = position.principal.saturating_sub(position.drawn);
                    let amount = available
                        .min(w.balance(addr(w.vault_ata)))
                        .min((value % 50 + 1) * USDC);
                    if amount > 0 {
                        w.draw_for(&treasurer, owner, amount).unwrap();
                        successful_transactions += 1;
                    } else if position.drawn > 0 {
                        let amount = position.drawn.min((value % 50 + 1) * USDC);
                        w.return_principal(owner, amount).unwrap();
                        successful_transactions += 1;
                    }
                }
                4 => {
                    let mut position = w.position(owner);
                    if position.drawn == 0 {
                        if w.config().paused {
                            w.admin_only(ix::SetPaused { paused: false }).unwrap();
                            successful_transactions += 1;
                        }
                        if position.notice_requested_at != 0 {
                            w.cancel_withdrawal(owner_key).unwrap();
                            successful_transactions += 1;
                            position = w.position(owner);
                        }
                        let amount = position
                            .principal
                            .min(w.balance(addr(w.vault_ata)))
                            .min((value % 50 + 1) * USDC);
                        assert!(amount > 0, "campaign always retains principal");
                        w.draw_for(&treasurer, owner, amount).unwrap();
                        successful_transactions += 1;
                    }
                    let position = w.position(owner);
                    let amount = position.drawn.min((value % 50 + 1) * USDC);
                    assert!(amount > 0);
                    w.return_principal(owner, amount).unwrap();
                    successful_transactions += 1;
                }
                5 => {
                    let position = w.position(owner);
                    let loss_capacity = position.drawn.min(position.principal.saturating_sub(USDC));
                    let amount = loss_capacity.min((value % 10 + 1) * USDC);
                    if amount == 0 {
                        if w.config().paused {
                            w.admin_only(ix::SetPaused { paused: false }).unwrap();
                            successful_transactions += 1;
                        }
                        if w.position(owner).notice_requested_at != 0 {
                            w.cancel_withdrawal(owner_key).unwrap();
                            successful_transactions += 1;
                        }
                        if !w.position(owner).allowlisted {
                            w.allowlist(&allowlister, owner, agreement_hash).unwrap();
                            successful_transactions += 1;
                        }
                        w.deposit(owner_key, owner_ata, 2 * USDC).unwrap();
                        successful_transactions += 1;
                    } else {
                        let mut hash = [0u8; 32];
                        hash[..8].copy_from_slice(&(seed * 100 + step).to_le_bytes());
                        w.record_loss(owner, amount, hash).unwrap();
                        successful_transactions += 1;
                    }
                }
                6 => {
                    // Move to a new completed month and fund immediately before the crank. The
                    // call must succeed; NothingDue is never accepted as campaign progress.
                    w.warp(math::next_month_start(w.now()) + 1);
                    w.treasury_pay(
                        w.coupon_ata,
                        ix::FundCoupons {
                            amount: 10_000 * USDC,
                        },
                    )
                    .unwrap();
                    successful_transactions += 1;
                    w.pay_coupon(&curator, owner, owner_ata).unwrap();
                    successful_transactions += 1;
                }
                7 => {
                    w.admin_only(ix::SetPaused {
                        paused: value & 0x100 != 0,
                    })
                    .unwrap();
                    successful_transactions += 1;
                }
                8 => {
                    let mut position = w.position(owner);
                    if position.principal <= USDC {
                        if position.notice_requested_at != 0 {
                            w.cancel_withdrawal(owner_key).unwrap();
                            successful_transactions += 1;
                        }
                        if w.config().paused {
                            w.admin_only(ix::SetPaused { paused: false }).unwrap();
                            successful_transactions += 1;
                        }
                        if !w.position(owner).allowlisted {
                            w.allowlist(&allowlister, owner, agreement_hash).unwrap();
                            successful_transactions += 1;
                        }
                        w.deposit(owner_key, owner_ata, 10 * USDC).unwrap();
                        successful_transactions += 1;
                        position = w.position(owner);
                    }
                    if position.notice_requested_at == 0 {
                        w.request_withdrawal(owner_key).unwrap();
                        successful_transactions += 1;
                        position = w.position(owner);
                    }
                    if position.drawn > 0 {
                        w.return_principal(owner, position.drawn).unwrap();
                        successful_transactions += 1;
                    }
                    w.warp(position.withdrawal_eligible_at.max(w.now()));
                    eligible_states_observed += 1;
                    let amount = position
                        .principal
                        .saturating_sub(USDC)
                        .min((value % 20 + 1) * USDC);
                    assert!(amount > 0);
                    w.withdraw(owner_key, owner_ata, amount).unwrap();
                    successful_transactions += 1;
                    successful_withdrawals += 1;
                }
                9 => {
                    let revoke = ixn(
                        acc::RevokeAllowlist {
                            allowlist_authority: pk(allowlister.pubkey()),
                            config: w.config,
                            position: w.position_key(owner),
                        },
                        ix::RevokeAllowlist {},
                    );
                    w.send(&[revoke], &[&allowlister]).unwrap();
                    successful_transactions += 1;
                    w.allowlist(&allowlister, owner, agreement_hash).unwrap();
                    successful_transactions += 1;
                }
                10 => {
                    w.admin_only(ix::SetTerms {
                        lock_seconds: ((value % 365) + 1) * DAY as u64,
                        notice_seconds: (((value >> 9) % 365) + 1) * DAY as u64,
                    })
                    .unwrap();
                    successful_transactions += 1;
                }
                11 => {
                    let config = w.config();
                    if (config.rate_epoch_count as usize) < math::MAX_RATE_EPOCHS {
                        let last =
                            config.rate_epochs[config.rate_epoch_count as usize - 1].start_ts;
                        w.admin_only(ix::SetRate {
                            bps: ((value % 10_000) + 1) as u16,
                            start_ts: w.now().max(last) + DAY,
                        })
                        .unwrap();
                        successful_transactions += 1;
                    } else {
                        expect_error(
                            w.admin_only(ix::SetRate {
                                bps: 100,
                                start_ts: w.now() + DAY,
                            }),
                            "RateEpochsFull",
                        );
                        rejected_transactions += 1;
                    }
                }
                12 => {
                    let amount = (value % 5 + 1) * USDC;
                    MintTo::new(
                        &mut w.svm,
                        &mint_authority,
                        &w.mint,
                        &addr(w.coupon_ata),
                        amount,
                    )
                    .send()
                    .unwrap();
                    MintTo::new(
                        &mut w.svm,
                        &mint_authority,
                        &w.mint,
                        &addr(w.vault_ata),
                        amount,
                    )
                    .send()
                    .unwrap();
                    w.sweep_coupons(&treasurer, amount).unwrap();
                    w.sweep_principal_surplus(&treasurer, amount).unwrap();
                    successful_transactions += 2;
                }
                13 => {
                    let admin = w.admin.insecure_clone();
                    let set_authorities = ixn(
                        acc::SetAuthorities {
                            admin: pk(admin.pubkey()),
                            config: w.config,
                            treasury_ata: pk(w.treasury_ata),
                        },
                        ix::SetAuthorities {
                            allowlist_authority: pk(allowlister.pubkey()),
                            treasury_authority: pk(treasurer.pubkey()),
                            emergency_authority: pk(w.emergency_authority.pubkey()),
                        },
                    );
                    w.send(&[set_authorities], &[&admin]).unwrap();
                    successful_transactions += 1;
                }
                14 => {
                    let emergency = w.emergency_authority.insecure_clone();
                    let pause = ixn(
                        acc::EmergencyOnly {
                            emergency_authority: pk(emergency.pubkey()),
                            config: w.config,
                        },
                        ix::EmergencyPause {},
                    );
                    w.send(&[pause], &[&emergency]).unwrap();
                    w.admin_only(ix::SetPaused { paused: false }).unwrap();
                    successful_transactions += 2;
                }
                15 => {
                    let emergency = w.emergency_authority.insecure_clone();
                    let halt = ixn(
                        acc::EmergencyHalt {
                            emergency_authority: pk(emergency.pubkey()),
                            config: w.config,
                            position: w.position_key(owner),
                        },
                        ix::EmergencyHalt {},
                    );
                    w.send(&[halt], &[&emergency]).unwrap();
                    let clear = ixn(
                        acc::RevokeAllowlist {
                            allowlist_authority: pk(allowlister.pubkey()),
                            config: w.config,
                            position: w.position_key(owner),
                        },
                        ix::SetPayoutHalt { halted: false },
                    );
                    w.send(&[clear], &[&allowlister]).unwrap();
                    successful_transactions += 2;
                }
                16 => {
                    let transient = Keypair::new();
                    w.svm.airdrop(&transient.pubkey(), 1_000_000_000).unwrap();
                    let transient_pk = pk(transient.pubkey());
                    w.allowlist(&allowlister, transient_pk, [23u8; 32]).unwrap();
                    let close = ixn(
                        acc::ClosePosition {
                            owner: transient_pk,
                            config: w.config,
                            position: w.position_key(transient_pk),
                        },
                        ix::ClosePosition {},
                    );
                    w.send(&[close], &[&transient]).unwrap();
                    successful_transactions += 2;
                }
                _ => {
                    // Two deliberately invalid calls with deterministic, named outcomes. They
                    // prove the campaign distinguishes a rejected transaction from a success.
                    if value & 0x200 == 0 {
                        if w.position(owner).notice_requested_at != 0 {
                            w.cancel_withdrawal(owner_key).unwrap();
                            successful_transactions += 1;
                        }
                        expect_error(w.withdraw(owner_key, owner_ata, USDC), "Locked");
                    } else {
                        expect_error(w.draw_for(&second, owner, USDC), "ConstraintHasOne");
                    }
                    rejected_transactions += 1;
                }
            }
            w.assert_invariants(&format!("campaign seed {seed}, step {step}"));
            state_checks += 1;
        }
    }
    eprintln!(
        "campaign: {state_checks} checked steps, {successful_transactions} successful transactions, \
         {rejected_transactions} asserted reverts, {successful_withdrawals} successful withdrawals, \
         {eligible_states_observed} eligible states"
    );
    assert_eq!(state_checks, 32 * 96);
    assert_eq!(guard_oracle_checks, 9);
    assert!(successful_transactions > 3_000);
    assert!(rejected_transactions > 100);
    assert!(successful_withdrawals >= 32);
    assert!(eligible_states_observed >= 32);
}
