# Optara — User Guide

*Options on Monad, explained like a stock. No prediction-market language — this is a financial market.*

> **The guarantee:** Whatever is locked in the vault stays there until settlement is complete. Trading activity cannot change what the vault owes.

---

## What is an option?

An **option is a standardized contract** that lets you gain exposure to a price move without buying the underlying outright — similar to how a call on AAPL gives you upside if the stock rises, without owning 100 shares.

You pay a **premium** today. At **expiry** you have a right to a **payout** if the market moved in your direction. If it did not, the contract expires worthless — you lose only the premium.

### Call vs put

| Type | You expect | Pays when | Stock analogy |
|:---|:---|:---|:---|
| **Call** | Price will **rise** | `Settlement price > Strike` | Long stock — you profit when the stock goes up |
| **Put** | Price will **fall** | `Settlement price < Strike` | Short stock / protective put — you profit when the stock goes down |

**Example — WMON $10 strike, expiry Friday 08:00 UTC, 1 WMON per contract:**

- **Call:** If WMON settles at **$12**, a Call with $10 strike pays `floor(1 × (12-10)/12) = 0.166… WMON` per contract. At **$9** it pays $0.
- **Put:** If WMON settles at **$8**, a Put with $10 strike pays `10-8 = $2` per WMON in USDC. At **$12** it pays $0.

Neither requires you to own the underlying. You are buying *exposure*, not the asset itself.

### Key terms

| Term | Meaning | Example |
|:---|:---|:---|
| **Underlying** | Asset your contract references | `WMON` |
| **Quote** | Asset the price is measured in | `USDC` |
| **Strike (K)** | Reference price for settlement | `$10` |
| **Expiry** | When minting stops and settlement becomes eligible | `Friday 08:00 UTC` |
| **Premium** | Price you pay (or receive) today for the contract | `$0.40` per contract on Kuru |
| **Collateral** | Assets the writer locks to guarantee settlement | `1 WMON` per Call, `Strike × 1 WMON` in USDC per Put |
| **Vault** | Contract that holds collateral and is itself the ERC-20 | `Optara WMON/USDC Call #1` |

> Think of a Call like buying upside exposure to a stock you expect to appreciate, and a Put like buying downside protection or a short position — with the difference that your maximum loss as a buyer is the premium, and every contract is fully collateralized.

---

## How you earn

There are two roles. You can take either, or both at different times. Same market, opposite market views.

### As a writer — earn premium for taking the other side

Writers *sell* contracts. You collect premium up front. In exchange, you lock collateral and take on the settlement obligation. This is similar to a **covered call** on stocks: you hold the asset (or quote) and sell upside (or downside) exposure.

**How it works:**

1. Lock collateral — e.g., `5 WMON` for 5 Calls (or `5 × $10 = $50,000 USDC` for 5 $10k-strike Puts scaled to 1 WMON notional).
2. Sell the 5 contracts on Kuru for a total premium — e.g., `5 × $0.40 = $2.00`.
3. At expiry, settlement determines payouts.

**Worked example — 5 Calls, K=$10, expiry Friday:**

| Settlement price (S) | Payout per contract | Total payout to buyers | You keep (5 WMON vault) | Your P&L vs premium |
|:---|:---|:---|:---|:---|
| **$9** (below strike) | `0 WMON` | `0` | **5.000 WMON** | **+ $2.00** (all premium retained) |
| **$10** (at strike) | `0` | `0` | **5.000 WMON** | **+ $2.00** |
| **$12** (above) | `0.166… WMON` (`(12-10)/12`) | `0.833… WMON` | **4.167 WMON** | **+ $2.00 premium − 0.833 WMON settlement** — net depends on WMON price, but premium cushions |

Writers earn most when the market stays on their side of the strike. Premium is income; settlement is the cost if the market moves against you. Maximum loss is capped: Calls = `1 WMON` per contract minus premium; Puts = `Strike` value per contract minus premium. No leverage or liquidation beyond locked collateral.

> **Stock parallel:** Like selling a covered call on 5 shares of a $10 stock for $0.40 — if the stock closes ≤$10 you keep the premium; if it closes at $12 you keep the premium but owe the upside above $10.

### As a buyer — pay premium for leveraged exposure

Buyers *buy* contracts to gain exposure without buying the full notional. Similar to buying a call on a stock instead of the stock itself.

**How it works:**

1. Pay premium on Kuru — e.g., `5 × $0.40 = $2.00`.
2. Hold until expiry, or sell the contract early on Kuru if the market moves favorably before expiry (contracts are ERC-20s, tradable at any time before expiry).
3. After settlement, redeem for payout if in-the-money.

**Worked example — same 5 Calls, K=$10, you paid $2.00:**

| Settlement (S) | Payout per contract | Net payout (5 contracts, 0.25% fee) | Your P&L | Return vs $2.00 |
|:---|:---|:---|:---|:---|
| **$9** | `0` | `0` | **−$2.00** | Premium lost |
| **$12** | `0.166… WMON` | `0.831 WMON` (≈ $9.97 at $12) | **≈ +$7.97** | **~4×** capital vs buying 0.2 WMON outright |
| **$15** | `0.333… WMON` | `1.662 WMON` (≈ $24.93 at $15) | **≈ +$22.93** | **~11×** |
| **$25** | `0.60 WMON` | `2.99 WMON` (≈ $74.8 at $25) | **≈ +$72.8** | Large upside, still only $2.00 risk |

The point: **5 Calls cost $2.00 but control 5 WMON notional ($50 at $10).** That capital efficiency is why traders use options instead of spot — similar to buying a $0.40 call on a $10 stock instead of buying the $10 stock.

> You can also realize P&L before expiry. If WMON rises to $11 on Wednesday, the market price of your $10 Calls will have risen — you can sell on Kuru for more than $0.40 without waiting for Friday.

### Quick comparison

| Position | Market view | Profits when | Max profit | Max loss | Capital |
|:---|:---|:---|:---|:---|:---|
| **Sell Call** | Neutral / flat | `S ≤ K` | Premium | `1 WMON − premium` per contract | Lock 1 WMON |
| **Buy Call** | Bullish (higher) | `S > K` | Unbounded as price rises | Premium | Pay premium only |
| **Sell Put** | Neutral / higher | `S ≥ K` | Premium | `K − premium` in USDC | Lock K USDC |
| **Buy Put** | Bearish (lower) | `S < K` | Up to strike value | Premium | Pay premium only |

---

## How to use Optara — step by step

### 1 — Select a series

In the app, select:

- **Call** (higher) or **Put** (lower)
- **Strike** — e.g., `$10`
- **Expiry** — e.g., `Next Friday 08:00 UTC`

The app lists only official series, e.g., *WMON/USDC $10 Call — Friday*. Check the registry status — names alone do not prove authenticity.

### 2 — Open a position

**To sell (writer):**

- The app quotes required collateral — e.g., *Lock 5 WMON + 0.005 fee for 5 Calls*. Approve the collateral asset, then `Mint`.
- You receive **5 contracts** (ERC-20) in your wallet. Your short is recorded. You may hold or list them on Kuru.

**To buy (taker):**

- Open the Kuru market linked on the series page (e.g., `OPT-WMON-USDC-C-1 / USDC`).
- Choose quantity, review **all-in cost** (quoted price + Kuru venue fee), set a maximum cost, and buy. The vault is not involved.

### 3 — Manage before expiry

- Hold, or sell early on Kuru to lock a gain or limit a loss.
- Trading transfers ownership only. The vault’s locked collateral does not change.

### 4 — Expiry — Friday 08:00 UTC

- Minting stops. No new contracts can be created.
- The Chainlink price **at this second** is the settlement anchor — even if `settle()` is called later.

### 5 — After settlement — settle and redeem

Settlement is triggered by anyone (keeper bot or you) once Chainlink has published one update **after** expiry (usually ≤1 hour). Then:

- **Holders:** `Redeem` — contracts are burned, payout is sent (`WMON` for Calls, `USDC` for Puts). Any positive payout incurs a 0.25% exercise fee from the gross.
- **Writers:** `Claim` — residual collateral (`1 − payout rate` per contract) is returned. No fee on residual.

A keeper can batch this for many accounts, but it always pays the owner — never the caller.

---

## What does it cost?

| Fee | Who pays | How much | When |
|:---|:---|:---|:---|
| To create contracts | Writer | **0.10%** of collateral | Added on top — e.g., 5 + 0.005 WMON |
| To settle in-the-money | Holder | **0.25%** of payout | Deducted from payout only if `payout > 0` |
| Kuru trading fee | Both sides | Venue-determined | Shown separately on Kuru — not Optara revenue |

- No fee to reclaim residual as a writer (paid at mint).
- No fee if a contract expires out-of-the-money — you still burn the token to clear the balance, payout $0.

Every contract is **fully collateralized** and European (redeemable only after settlement) — no margin, no liquidation, no early exercise.

---

## Get started — wallet in 2 minutes

**You need:** a wallet on Monad, a small amount of `MON` for gas, and `WMON` + `USDC`.

### 1 — Add Monad to your wallet

MetaMask / Rabby / Phantom → Add Network:

| Field | Testnet value |
|:---|:---|
| Network name | `Monad Testnet` |
| RPC URL | `https://testnet-rpc.monad.xyz` *(placeholder — see deployments)* |
| Chain ID | `*TBD*` |
| Currency symbol | `MON` |
| Explorer | `https://testnet-explorer.monad.xyz` |

Mainnet values will be published at launch — same steps.

### 2 — Get test MON

- Use the Monad faucet (link in app header when live) → paste address → receive MON.
- You need MON for gas only. Collateral is WMON.

### 3 — Wrap MON → WMON

Optara uses WMON (ERC-20) for predictable behavior.

- In app: **Wrap** → 5 MON → Wrap, or call `WMON.deposit()` with 5 MON.
- Keep ~0.1 MON unwrapped for gas.

### 4 — Get USDC

- Calls need WMON; Puts need USDC; all premiums on Kuru are in USDC.
- Testnet: in-app USDC faucet or `MockUSDC.mint(you, 100_000e6)`. Import USDC by address (6 decimals).

Then approve WMON or USDC when prompted — one approval per token.

---

## Profit calculator — how to estimate

You need two numbers: **premium** and **price at expiry**. The formulas are:

- **Call:** `If S ≤ K: payout = 0` · `If S > K: payout = (S − K) / S × 1 WMON` per contract
- **Put:** `If S ≥ K: payout = 0` · `If S < K: payout = (K − S)` in USDC per 1 WMON
- **Profit = Payout − Premium** (minus 0.25% fee only if payout > 0)

### Scenarios — K=$10, 1 WMON per contract, 5 contracts

| Position | Premium | Expiry price (S) | Payout per contract | Fee (0.25%) | Net payout (5 contracts) | P&L | Outcome |
|:---|---:|---:|---:|---:|---:|---:|:---:|
| Buy Call | $0.40 | $9 | $0 | $0 | $0 | **−$2.00** | Expires worthless |
| Buy Call | $0.40 | $10 | $0 | $0 | $0 | **−$2.00** | At strike — still $0 |
| Buy Call | $0.40 | $12 | 0.166 WMON ≈ $1.99 | ≈$0.005 | ≈$9.93 | **+$7.93** | **4.9×** vs premium |
| Buy Call | $0.40 | $15 | 0.333 WMON ≈ $5.00 | ≈$0.012 | ≈$24.94 | **+$22.94** | 12× |
| Sell Call | +$0.40 (received) | $9 | 0 (retain all) | — | retain 5 WMON | **+$2.00** | Keep premium |
| Sell Call | +$0.40 | $12 | 0.166 WMON to buyer | — | retain 4.17 WMON | **+$2.00 − 0.83 WMON** | Premium offsets settlement |
| Buy Put | $1,200 | $55k (K=$60k) | $5,000 | $12.5 | $24,937.5 | **+$18,937** | Downside exposure without shorting spot |
| Buy Put | $1,200 | $61k | $0 | $0 | $0 | **−$6,000** | Expires worthless |

Use the in-app slider to drag **S** and see payout and profit update live with exact `UQ_SCALE` math and fees.

---

## Risks — read before you use

1. **You may not be able to sell before expiry.** Kuru needs a counterparty. If a series is illiquid, you hold until settlement. Settlement and redemption still work even if Kuru is empty.
2. **Settlement is not instant.** It waits for Chainlink’s first update after expiry (≤ ~1 hour). The settlement price is already fixed at expiry — the wait does not change it.
3. **Quoted premium is not fair value.** The price on Kuru is what counterparties will pay — it can be thin or stale. Use the app’s safety range and do not rely on last-traded price alone.

> **Not audited.** The contracts are built and tested (286 tests) but have not had an independent audit. Do not risk more than you can afford to lose. This is not financial advice.

---

## FAQ

**Which earns more — buying or selling?**

Selling collects premium frequently — small, consistent, like writing covered calls. Buying costs premium but offers larger, less frequent upside. Many participants do both at different times and hedge spot holdings.

**Can I lose more than I put in?**

- **Buyer:** No. Maximum loss = premium paid.
- **Writer:** Maximum loss = collateral locked minus premium (1 WMON per Call, Strike value per Put). No leverage beyond locked collateral.

**Do I have to wait until expiry?**

No. Sell the contract on Kuru at any time before expiry. After expiry, wait for settlement, then redeem or claim.

**Can I sell half?**

Yes. Contracts are ERC-20s. Sell 1 of 5, redeem any positive amount — no minimum after minting.

**Where are my assets?**

In the vault contract. Not with Kuru or a person. The vault is non-upgradeable and cannot be paused for payouts.

**What if Chainlink is unavailable after expiry?**

In V1, if Chainlink never publishes after expiry, the series cannot settle — assets remain locked. This is disclosed and mitigated by using only major, actively updated direct feeds and short-dated expiries (≤ 30 days). A recovery module may be added later.

**WMON vs MON?**

WMON is wrapped MON (ERC-20). Native MON is not used for collateral to keep behavior predictable.

**How do I know a contract is official?**

The app marks official series via `factory.isOptionToken()` on-chain. Do not trust names or Kuru listings — any address can deploy a token with a similar symbol.

---

## Quick glossary

| Term | Meaning |
|:---|:---|
| **Call** | Right to upside — pays when `S > K` |
| **Put** | Right to downside — pays when `S < K` |
| **Strike (K)** | Reference price for settlement |
| **Expiry** | When minting stops; settlement anchor time (Friday 08:00 UTC in V1) |
| **Premium** | Market price of the contract today on Kuru |
| **Collateral** | Assets locked by the writer to guarantee settlement |
| **Vault** | Contract holding collateral and representing the ERC-20 |
| **Kuru** | Venue where contracts trade (price discovery only) |
| **Chainlink** | Oracle that determines settlement price at expiry |
