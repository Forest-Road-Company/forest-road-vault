# How to Use the App

This guide walks through every action in the [app](/app): getting USDfr, staking it for yield,
and getting back out. Every action is a transaction on Ethereum mainnet with real assets. Read the
[risk disclosures](/risk) and the [terms](/terms) first. Nothing here is legal, tax or investment
advice.

## The two tokens

- **USDfr** is the stablecoin. It is minted 1:1 against USDC and can be redeemed for USDC. Holding
  USDfr earns no yield, though it does earn [points](/points).
- **sUSDfr** is the yield-bearing vault share. Stake USDfr to receive sUSDfr. Its exchange rate
  rises as the loan book earns interest, net of fees. The rate is variable, never fixed, and it
  can fall: a credit loss larger than the curator and sGROVE layers ahead of it reduces sUSDfr
  principal.

## Before you start

You need:

- **An Ethereum wallet.** A browser-extension wallet, or a mobile wallet connected through
  WalletConnect.
- **ETH for gas.** Minting, staking and requesting a redemption each take two transactions: an
  approval that lets the contract move exactly the amount you entered, then the action itself.
- **USDC or USDfr.** Mint USDfr with USDC if your address is KYC-verified, or buy USDfr on the
  third-party Uniswap pool described below.

Reading needs no wallet. Supply, backing, the vault rate, the queue and the loan book are public
on the [transparency dashboard](/transparency).

## 1. Connect your wallet

Open the [app](/app) and press **Connect wallet**. Before it enables any action, the app checks
three things:

- **Network.** The app works only on Ethereum mainnet. If your wallet is on another network, a
  banner offers **Switch to Ethereum mainnet**; approve the switch in your wallet.
- **Wallet connection.** The app confirms that your wallet reads the same chain state it does. If
  your wallet uses a custom RPC or a fork, select the standard Ethereum network in your wallet
  and press **Check again**.
- **KYC status.** A badge shows **KYC verified** or **not KYC-verified** for the connected
  address.

## 2. Check what your address can do

The contracts enforce these rules on-chain; the app only mirrors them.

- **Needs a KYC-verified address:** minting USDfr with USDC, and redeeming USDfr for USDC.
- **Open to any address that is not blocked:** holding and transferring USDfr and sUSDfr,
  staking USDfr, requesting an sUSDfr redemption through the queue, and claiming it.

Every USDfr and sUSDfr transfer is screened. An address on the sanctions or jurisdiction
blocklist cannot send or receive either token, mint or redeem.

KYC applies per address. To have an address verified, email
[jevans@forestroad.com](mailto:jevans@forestroad.com) with the wallet address you want to use, and
Forest Road will guide you through onboarding. Use of the application remains subject to the
eligibility restrictions and agreements presented during onboarding.

## 3. Get USDfr

**Mint with USDC (KYC-verified addresses).** In **Deposit & mint**, enter a USDC amount,
press **Approve USDC** and confirm in your wallet, then press **Mint USDfr**. You receive
USDfr 1:1. Every mint is checked on-chain so that USDfr supply can never exceed its backing.

**Buy on Uniswap (any address).** USDfr trades against USDC in a Uniswap v4 pool:
[USDfr/USDC on Uniswap](https://app.uniswap.org/explore/pools/ethereum/0x72ef9130b1c7bd2daa49405e618b7ad27eb90e03c893629ba1d28a4562fc7b55).
Uniswap is independent of Forest Road. The pool's price is set by the market and can differ from
1:1, so check the quote and your slippage setting before you swap. The pool ID is on the
[deployed-addresses page](/docs/addresses).

## 4. Stake USDfr for yield

In **Stake**, enter a USDfr amount, press **Approve USDfr**, then press **Stake**.
The card shows the current exchange rate and how much sUSDfr you will receive. Staking needs no
KYC.

- Interest is recognized continuously as the loan book earns it, before the cash arrives.
- The protocol takes 10% of the interest each facility earns. The vault then charges a 10%
  performance fee on profit above one protocol-wide high-water mark, and no management fee.
  The vault's fees are paid by minting new sUSDfr shares, not by removing backing. The Stake card
  shows the live rates, and [How it works](/how-it-works) explains them in full.
- If the card warns that the queued-exit value is impaired or that performance-fee exposure is
  deferred, read the warning before you stake: it means new shares would currently exit for less
  than they cost, or could bear a fee on gains made before you joined.

## 5. Get back out

### sUSDfr to USDfr: the redemption queue

There is no instant unstake. Every sUSDfr exit goes through the redemption queue.

1. In **Redeem**, choose **sUSDfr** and enter the amount. The minimum request is worth 1 USDfr.
2. Tick the acknowledgement, press **Approve sUSDfr**, then press **Request redemption**.
3. Your request waits out a **21-day minimum hold**. After that it fills strictly first in,
   first out. Settlement runs daily, and each settlement can fill requests worth at most 1.67%
   of idle USDC reserves, so a large exit, or one behind a long queue, can take longer.
4. When it has filled, the request shows a **Claim** button under **Your queue positions**. Claim
   it to receive USDfr at the address that made the request.

Know before you request:

- **A request cannot be cancelled or withdrawn.**
- **It settles at the price when it fills, not when you request it.** Your shares stay exposed
  to the book until then. If a loan is in default, the fill price reflects a conservative
  impairment mark, which assumes zero recovery unless a professional recovery assessment has
  been published. See [Default recovery & exit pricing](/docs/recovery).
- The card lists your recent requests. To find an older one, enter its request ID in
  **Find any request by ID** under **Your queue positions**.

### USDfr to USDC

**KYC-verified addresses** can redeem USDfr for USDC instantly in **Redeem → USDfr**. It pays 1:1
while USDfr is fully backed, and is limited to the idle USDC held in reserve. USDC has six
decimals, so the amount is rounded down to the nearest 0.000001 USDC and any smaller remainder
stays in your wallet as USDfr.

**Any address** can instead sell USDfr on the Uniswap pool, at the market price.

## 6. Track your position

- The app's position panel shows your position, current expected yield, projected income,
  historical gain and the fees that apply.
- The [points page](/points) shows the participation points your wallet has accrued.
- The [transparency dashboard](/transparency) reconciles supply, backing, the loan book, the
  loss layers and the queue to on-chain state.
- To see the tokens in your wallet, add them by address from the
  [deployed-addresses page](/docs/addresses). USDfr uses 18 decimals and sUSDfr uses 24.

## If something goes wrong

- **The app shows an error instead of opening your wallet.** Every action is simulated first.
  If it would fail, the app shows the contract's own reason and sends nothing.
- **Mint and instant redeem are disabled.** The connected address is not KYC-verified. Staking,
  transfers and queue exits still work. Email
  [jevans@forestroad.com](mailto:jevans@forestroad.com) to begin onboarding.
- **Wrong network or RPC mismatch.** Use the switch banner, or select the standard Ethereum
  network in your wallet and press **Check again**.
- **A transfer to or from an address fails.** One side may be sanctions- or
  jurisdiction-blocked, or an emergency pause may be in effect. The
  [status page](/docs/status) reports operating conditions.
- **Something looks wrong with the protocol itself.** Report it privately as described under
  [Security & testing](/docs/security).
