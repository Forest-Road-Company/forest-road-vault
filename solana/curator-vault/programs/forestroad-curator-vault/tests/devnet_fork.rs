#![allow(clippy::result_large_err)]
//! Fork of the LIVE devnet vault into LiteSVM, fast-forwarded to the month boundaries devnet
//! itself has not reached: the coupon crank at 1 October, a rate change, the December crank
//! across two epochs, notice and withdrawal after ninety days, close. The program bytes are the
//! ones on chain (compared against the local build), the accounts are the snapshot taken by
//! `scripts/snapshot-devnet.ts`, and the authorities are the real devnet keys, so this is the
//! deployed state moved forward in time, not a fresh fixture.
//!
//! This evidence test is explicitly ignored by the ordinary unit-test command because it needs
//! the external devnet signer files. Run it with `--ignored`; once selected, every missing input,
//! hash mismatch or stale account layout is a hard failure.

use anchor_lang::prelude::Pubkey;
use anchor_lang::{AccountDeserialize, InstructionData, ToAccountMetas};
use base64::Engine;
use forestroad_curator_vault::state::{Config, Position};
use forestroad_curator_vault::{accounts as acc, instruction as ix, math, ID as PROGRAM};
use litesvm::types::FailedTransactionMetadata;
use litesvm::LiteSVM;
use litesvm_token::spl_token::state::Account as TokenAccountState;
use litesvm_token::{get_spl_account, TOKEN_ID};
use sha2::{Digest, Sha256};
use solana_account::Account;
use solana_address::Address;
use solana_clock::Clock;
use solana_instruction::{AccountMeta, Instruction};
use solana_keypair::Keypair;
use solana_message::Message;
use solana_signer::Signer;
use solana_transaction::Transaction;
use std::path::PathBuf;

const DAY: i64 = 86_400;
const USDC: u64 = 1_000_000;

fn addr(pk: Pubkey) -> Address {
    Address::new_from_array(pk.to_bytes())
}
fn pk(ad: Address) -> Pubkey {
    Pubkey::new_from_array(ad.to_bytes())
}
fn parse(s: &str) -> Address {
    s.parse().expect("base58 address")
}

fn ixn(accounts: impl ToAccountMetas, data: impl InstructionData) -> Instruction {
    Instruction {
        program_id: addr(PROGRAM),
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

fn home(rel: &str) -> PathBuf {
    PathBuf::from(std::env::var("HOME").expect("HOME")).join(rel)
}

fn load_keypair(rel: &str) -> Keypair {
    let path = home(rel);
    let bytes: Vec<u8> =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap_or_else(|error| {
            panic!("missing required devnet key {}: {error}", path.display())
        }))
        .unwrap_or_else(|error| panic!("invalid devnet key JSON {}: {error}", path.display()));
    Keypair::try_from(bytes.as_slice())
        .unwrap_or_else(|error| panic!("invalid devnet key bytes {}: {error}", path.display()))
}

struct Fork {
    svm: LiteSVM,
    deployer: Keypair,
    curator: Keypair,
    config: Pubkey,
    position: Pubkey,
    vault_ata: Pubkey,
    coupon_ata: Pubkey,
    curator_ata: Pubkey,
    treasury_ata: Pubkey,
}

impl Fork {
    fn send(
        &mut self,
        ixs: &[Instruction],
        signers: &[&Keypair],
    ) -> Result<(), FailedTransactionMetadata> {
        self.svm.expire_blockhash();
        let msg = Message::new(ixs, Some(&signers[0].pubkey()));
        let tx = Transaction::new(signers, msg, self.svm.latest_blockhash());
        self.svm.send_transaction(tx).map(|_| ())
    }
    fn warp(&mut self, ts: i64) {
        let mut clock: Clock = self.svm.get_sysvar();
        clock.unix_timestamp = ts;
        clock.slot += 1;
        self.svm.set_sysvar(&clock);
    }
    fn config(&self) -> Config {
        Config::try_deserialize(
            &mut self
                .svm
                .get_account(&addr(self.config))
                .unwrap()
                .data
                .as_slice(),
        )
        .unwrap()
    }
    fn position(&self) -> Position {
        Position::try_deserialize(
            &mut self
                .svm
                .get_account(&addr(self.position))
                .unwrap()
                .data
                .as_slice(),
        )
        .unwrap()
    }
    fn balance(&self, ata: Pubkey) -> u64 {
        get_spl_account::<TokenAccountState>(&self.svm, &addr(ata))
            .unwrap()
            .amount
    }
    fn assert_invariants(&self, when: &str) {
        let c = self.config();
        assert_eq!(
            self.balance(self.vault_ata) + c.drawn,
            c.total_principal,
            "I1 {when}"
        );
        assert!(c.drawn <= c.total_principal, "I2 {when}");
        assert_eq!(
            self.balance(self.coupon_ata),
            c.coupon_funded - c.coupon_paid,
            "I3 {when}"
        );
    }
    fn pay_coupon(&mut self) -> Result<(), FailedTransactionMetadata> {
        let i = ixn(
            acc::PayCoupon {
                cranker: pk(self.deployer.pubkey()),
                config: self.config,
                position: self.position,
                coupon_ata: self.coupon_ata,
                owner_ata: self.curator_ata,
                token_program: pk(TOKEN_ID),
            },
            ix::PayCoupon {},
        );
        let signer = self.deployer.insecure_clone();
        self.send(&[i], &[&signer])
    }
    /// The keeper's job: top the pool up from the treasury when it cannot cover `due`.
    fn ensure_pool(&mut self, due: u64) {
        let have = self.balance(self.coupon_ata);
        if have >= due {
            return;
        }
        let top_up = (due - have).max(1_000 * USDC);
        let i = ixn(
            acc::TreasuryPay {
                treasury_authority: pk(self.deployer.pubkey()),
                config: self.config,
                source: self.treasury_ata,
                destination: self.coupon_ata,
                token_program: pk(TOKEN_ID),
            },
            ix::FundCoupons { amount: top_up },
        );
        let signer = self.deployer.insecure_clone();
        self.send(&[i], &[&signer]).unwrap();
    }
    /// What the program will pay at `boundary`: owed so far plus accrual through the boundary.
    fn expected_at(&self, boundary: i64) -> u64 {
        let c = self.config();
        let p = self.position();
        let (whole, _) = math::accrue(
            p.principal,
            &c.epochs(),
            p.coupon_accrued_through,
            boundary,
            p.coupon_remainder,
        )
        .unwrap();
        p.coupon_owed + whole
    }
}

fn expect_error(result: Result<(), FailedTransactionMetadata>, code: &str) {
    match result {
        Ok(()) => panic!("expected {code}, succeeded"),
        Err(e) => assert!(
            e.meta.logs.join("\n").contains(code),
            "expected {code}; err {:?}",
            e.err
        ),
    }
}

struct BoundEvidence {
    snap: serde_json::Value,
    accounts: serde_json::Map<String, serde_json::Value>,
    elf: Vec<u8>,
}

/// Verifies all public deployment evidence before the selected lifecycle test asks for a signer.
/// This function is also exercised by an ordinary, keyless test below.
fn load_bound_evidence() -> BoundEvidence {
    let deployment_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../deployments");
    let snapshot_path = deployment_dir.join("devnet-snapshot.json");
    let text = std::fs::read_to_string(&snapshot_path).unwrap_or_else(|error| {
        panic!(
            "missing required devnet snapshot {}: {error}",
            snapshot_path.display()
        )
    });
    let snap: serde_json::Value = serde_json::from_str(&text).unwrap();
    let build: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(deployment_dir.join("build.json"))
            .expect("missing required clean build receipt"),
    )
    .expect("invalid clean build receipt");
    let deployment: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(deployment_dir.join("devnet.json"))
            .expect("missing required devnet deployment manifest"),
    )
    .expect("invalid devnet deployment manifest");
    assert_eq!(
        snap["programId"].as_str().unwrap(),
        PROGRAM.to_string(),
        "snapshot is for another program"
    );
    assert_eq!(snap["build"], build, "snapshot is for another build");
    assert_eq!(
        deployment["build"], build,
        "deployment is for another build"
    );
    assert_eq!(
        snap["deploymentSignature"], deployment["signatures"]["deployProgram"],
        "snapshot is not bound to the deployment transaction"
    );
    assert_eq!(
        snap["canonicalBuildActivationSignature"],
        deployment["signatures"]["canonicalBuildActivation"],
        "snapshot is not bound to the canonical build activation"
    );
    assert_eq!(
        snap["canonicalBuildActivatedAtSlot"], deployment["canonicalBuildActivatedAtSlot"],
        "snapshot records another build activation slot"
    );
    assert!(
        snap["takenAtSlot"].as_u64().unwrap() >= deployment["deployedAtSlot"].as_u64().unwrap(),
        "snapshot predates deployment"
    );
    assert!(
        snap["takenAtSlot"].as_u64().unwrap()
            >= deployment["canonicalBuildActivatedAtSlot"]
                .as_u64()
                .unwrap(),
        "snapshot predates canonical build activation"
    );
    let accounts = snap["accounts"].as_object().unwrap().clone();
    let b64 = base64::engine::general_purpose::STANDARD;
    // The executable bytes as deployed: the upgradeable loader's programdata carries a 45-byte
    // header (tag, slot, upgrade authority) before the ELF.
    let programdata = b64
        .decode(accounts["programData"]["data"].as_str().unwrap())
        .unwrap();
    let elf = &programdata[45..];
    let local = std::fs::read(deployment_dir.join("artifacts/forestroad_curator_vault.so"))
        .expect("missing committed canonical release ELF");
    let trimmed = &elf[..local.len().min(elf.len())];
    assert_eq!(
        Sha256::digest(trimmed)[..],
        Sha256::digest(&local)[..],
        "on-chain program differs from the local build"
    );
    assert!(
        elf[local.len()..].iter().all(|b| *b == 0),
        "on-chain program has trailing bytes beyond the local build"
    );
    BoundEvidence {
        snap,
        accounts,
        elf: trimmed.to_vec(),
    }
}

#[test]
fn committed_devnet_evidence_binds_without_private_signers() {
    let evidence = load_bound_evidence();
    assert!(!evidence.elf.is_empty(), "canonical program is empty");
    for name in [
        "config",
        "curatorPosition",
        "vaultAta",
        "couponAta",
        "curatorAta",
        "treasuryAta",
        "mint",
    ] {
        assert!(
            evidence.accounts.contains_key(name),
            "snapshot lacks {name}"
        );
    }
}

fn fork() -> Fork {
    let BoundEvidence {
        snap,
        accounts,
        elf,
    } = load_bound_evidence();
    let (deployer, curator) = (
        load_keypair(".config/solana/frv-devnet-deployer.json"),
        load_keypair(".config/solana/frv-devnet-curator.json"),
    );
    let b64 = base64::engine::general_purpose::STANDARD;
    let mut svm = LiteSVM::new();
    svm.add_program(addr(PROGRAM), &elf).unwrap();

    let mut key_of = |name: &str| -> Pubkey {
        let a = &accounts[name];
        let address = parse(a["address"].as_str().unwrap());
        let account = Account {
            lamports: a["lamports"].as_u64().unwrap(),
            data: b64.decode(a["data"].as_str().unwrap()).unwrap(),
            owner: parse(a["owner"].as_str().unwrap()),
            executable: a["executable"].as_bool().unwrap(),
            rent_epoch: 0,
        };
        svm.set_account(address, account).unwrap();
        pk(address)
    };
    let config = key_of("config");
    let position = key_of("curatorPosition");
    let vault_ata = key_of("vaultAta");
    let coupon_ata = key_of("couponAta");
    let curator_ata = key_of("curatorAta");
    let treasury_ata = key_of("treasuryAta");
    key_of("mint");
    for k in [&deployer, &curator] {
        svm.airdrop(&k.pubkey(), 10_000_000_000).unwrap();
    }
    // Start the fork's clock at the snapshot moment, then fast-forward per test.
    let taken = snap["takenAt"].as_str().unwrap();
    let taken_ts = parse_iso(taken);
    let mut clock: Clock = svm.get_sysvar();
    clock.unix_timestamp = taken_ts;
    svm.set_sysvar(&clock);
    Fork {
        svm,
        deployer,
        curator,
        config,
        position,
        vault_ata,
        coupon_ata,
        curator_ata,
        treasury_ata,
    }
}

/// "2026-09-18T07:50:12.345Z" to seconds, no dependency needed.
fn parse_iso(s: &str) -> i64 {
    let y: i64 = s[0..4].parse().unwrap();
    let m: u32 = s[5..7].parse().unwrap();
    let d: u32 = s[8..10].parse().unwrap();
    let hh: i64 = s[11..13].parse().unwrap();
    let mm: i64 = s[14..16].parse().unwrap();
    let ss: i64 = s[17..19].parse().unwrap();
    math::days_from_civil(y, m, d) * DAY + hh * 3_600 + mm * 60 + ss
}

#[test]
#[ignore = "explicit deployed-devnet evidence; run with --ignored and external devnet signers"]
fn devnet_fork_fast_forwarded_through_the_first_coupons_and_a_full_exit() {
    let mut f = fork();
    let curator = f.curator.insecure_clone();
    let deployer = f.deployer.insecure_clone();
    let c0 = f.config();
    let p0 = f.position();
    assert_eq!(
        c0.rate_epochs[0].bps, 1_250,
        "devnet vault carries the decided rate"
    );
    assert!(
        c0.principal_at_risk
            && c0.lock_seconds == 90 * DAY as u64
            && c0.notice_seconds == 90 * DAY as u64
    );
    assert!(
        p0.allowlisted && p0.principal > 0,
        "the rehearsal position is live in the snapshot"
    );
    f.assert_invariants("at the snapshot");
    eprintln!(
        "snapshot: principal {} owed {} accrued_through {} paid_through {} pool {}",
        p0.principal,
        p0.coupon_owed,
        p0.coupon_accrued_through,
        p0.coupon_paid_through,
        f.balance(f.coupon_ata)
    );

    // Before 1 October nothing is due, exactly as on devnet today.
    expect_error(f.pay_coupon(), "NothingDue");

    // ── 1 October: the first crank pays September's accrual from the deposit onward ──
    let oct1 = math::days_from_civil(2026, 10, 1) * DAY;
    f.warp(oct1 + 10);
    let expected_oct = f.expected_at(oct1);
    f.ensure_pool(expected_oct);
    let before = f.balance(f.curator_ata);
    f.pay_coupon().unwrap();
    assert_eq!(
        f.balance(f.curator_ata) - before,
        expected_oct,
        "October coupon equals the library's accrual"
    );
    let p = f.position();
    assert_eq!((p.coupon_owed, p.coupon_paid_through), (0, oct1));
    expect_error(f.pay_coupon(), "NothingDue");
    f.assert_invariants("after the October crank");
    eprintln!(
        "1 October crank paid {} base units ({} USDC)",
        expected_oct,
        expected_oct as f64 / USDC as f64
    );

    // ── a rate change from 15 November, cranked on 1 November and 1 December ──
    let nov1 = math::days_from_civil(2026, 11, 1) * DAY;
    let nov15 = math::days_from_civil(2026, 11, 15) * DAY;
    let dec1 = math::days_from_civil(2026, 12, 1) * DAY;
    f.warp(nov1 + 5);
    let set = ixn(
        acc::AdminOnly {
            admin: pk(deployer.pubkey()),
            config: f.config,
        },
        ix::SetRate {
            bps: 1_300,
            start_ts: nov15,
        },
    );
    f.send(&[set], &[&deployer]).unwrap();
    let expected_nov = f.expected_at(nov1);
    f.ensure_pool(expected_nov);
    let before = f.balance(f.curator_ata);
    f.pay_coupon().unwrap();
    assert_eq!(f.balance(f.curator_ata) - before, expected_nov);
    f.warp(dec1 + 5);
    let expected_dec = f.expected_at(dec1);
    let by_hand = (p.principal as u128 * (1_250u128 * 14 + 1_300u128 * 16) * DAY as u128)
        / math::SLICE_DENOMINATOR;
    assert!(
        expected_dec as u128 >= by_hand && (expected_dec as u128) - by_hand <= 1,
        "November at 12.5% then 13% from the 15th"
    );
    f.ensure_pool(expected_dec);
    let before = f.balance(f.curator_ata);
    f.pay_coupon().unwrap();
    assert_eq!(f.balance(f.curator_ata) - before, expected_dec);
    f.assert_invariants("after the December crank");

    // ── notice on 1 December, withdrawal after ninety days, tail coupon, close ──
    let notice = ixn(
        acc::CuratorAction {
            owner: pk(curator.pubkey()),
            config: f.config,
            position: f.position,
        },
        ix::RequestWithdrawal {},
    );
    f.send(&[notice], &[&curator]).unwrap();
    let eligible = f.position().withdrawal_eligible_at;
    assert_eq!(
        eligible,
        dec1 + 5 + 90 * DAY,
        "notice dominates the September lock"
    );
    let withdraw_all = |f: &Fork, amount: u64| {
        ixn(
            acc::CuratorTransfer {
                owner: pk(curator.pubkey()),
                config: f.config,
                position: f.position,
                vault_ata: f.vault_ata,
                owner_ata: f.curator_ata,
                token_program: pk(TOKEN_ID),
            },
            ix::Withdraw { amount },
        )
    };
    let principal = f.position().principal;
    let i = withdraw_all(&f, principal);
    expect_error(f.send(&[i], &[&curator]), "Locked");
    f.warp(eligible + 1);
    // Everything from December through March is payable in one crank at the March boundary.
    // The rehearsal's 500 test USDC pool cannot cover it, and the program says so before paying
    // anything; the treasury funds the pool (the keeper's monthly proposal) and the crank runs.
    let mar1 = math::month_start(eligible + 1);
    let expected_mar = f.expected_at(mar1);
    // Three months of accrual normally exceeds what the rehearsal left in the pool; when it does,
    // the program says so before paying anything, and the keeper's top-up makes it whole.
    if expected_mar > f.balance(f.coupon_ata) {
        expect_error(f.pay_coupon(), "InsufficientCouponPool");
    }
    f.ensure_pool(expected_mar);
    let before = f.balance(f.curator_ata);
    f.pay_coupon().unwrap();
    assert_eq!(f.balance(f.curator_ata) - before, expected_mar);
    // The treasury must have returned every draw before the curator can take the principal;
    // until it has, the program refuses with the liquidity error rather than paying short.
    let drawn = f.config().drawn;
    if drawn > 0 {
        let i = withdraw_all(&f, principal);
        expect_error(f.send(&[i], &[&curator]), "InsufficientVaultLiquidity");
        let ret = ixn(
            acc::ReturnPrincipal {
                treasury_authority: pk(deployer.pubkey()),
                config: f.config,
                position: f.position,
                source: f.treasury_ata,
                vault_ata: f.vault_ata,
                token_program: pk(TOKEN_ID),
            },
            ix::ReturnPrincipal { amount: drawn },
        );
        f.send(&[ret], &[&deployer]).unwrap();
        assert_eq!(f.config().drawn, 0);
        f.assert_invariants("after the return");
    }
    let i = withdraw_all(&f, principal);
    let before = f.balance(f.curator_ata);
    f.send(&[i], &[&curator]).unwrap();
    assert_eq!(
        f.balance(f.curator_ata) - before,
        principal,
        "full principal returned to the curator"
    );
    let p = f.position();
    assert_eq!(
        (p.principal, p.notice_requested_at, p.withdrawal_eligible_at),
        (0, 0, 0)
    );
    assert_eq!(f.config().total_principal, 0);
    f.assert_invariants("after the withdrawal");
    let close = ixn(
        acc::ClosePosition {
            owner: pk(curator.pubkey()),
            config: f.config,
            position: f.position,
        },
        ix::ClosePosition {},
    );
    assert!(
        p.coupon_owed > 0,
        "the withdrawal leaves a partial-month tail"
    );
    expect_error(
        f.send(std::slice::from_ref(&close), &[&curator]),
        "PositionNotEmpty",
    );
    let next_boundary = math::next_month_start(eligible + 1);
    f.warp(next_boundary + 1);
    let expected_tail = f.expected_at(next_boundary);
    f.ensure_pool(expected_tail);
    f.pay_coupon().unwrap();
    assert_eq!(f.position().coupon_owed, 0);
    f.send(&[close], &[&curator]).unwrap();
    assert!(
        f.svm
            .get_account(&addr(f.position))
            .map(|a| a.data.is_empty())
            .unwrap_or(true),
        "position closed"
    );
    eprintln!(
        "coupons paid on the fork: Oct {} Nov {} Dec {} Mar {} tail {} (base units)",
        expected_oct, expected_nov, expected_dec, expected_mar, expected_tail
    );
}
