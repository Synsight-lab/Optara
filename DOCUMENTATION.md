<div align="center">

# 🌿 Optara — Documentation Hub

### *Secure, transparent, fully collateralized options on Monad*

<img src="https://img.shields.io/badge/Chain-Monad-836EF9?style=for-the-badge" /> <img src="https://img.shields.io/badge/Style-European%20•%20Fully%20Collateralized-22C55E?style=for-the-badge" /> <img src="https://img.shields.io/badge/Settlement-Chainlink-375BD2?style=for-the-badge" /> <img src="https://img.shields.io/badge/Trading-Kuru-FF6B6B?style=for-the-badge" />

**Not audited. Not on mainnet yet.** Built and tested — 286 tests pass. Start with the guide that fits you.

</div>

---

<div style="background: linear-gradient(90deg, #f0fdf4 0%, #eff6ff 100%); border: 2px solid #22c55e; border-radius: 12px; padding: 16px 20px;">

### 💚 The One Promise

> **Trading changes *who owns* a ticket. It never changes *how much the vault owes*.**
> No wash trade, no fake liquidity, no crashed order book can drain collateral.

</div>

---

## 🚀 Pick your guide

<div style="display: grid; grid-template-columns: 1fr; gap: 16px; max-width: 640px; margin: 0 auto;">

<div style="background: #f0fdf4; border: 2px solid #22c55e; border-radius: 14px; padding: 22px; text-align: center;">

### 👥 For Users

## 🌿 User Guide

**No code. No jargon.**

Learn what an option is, how to use Optara step-by-step, and **how to profit** as a writer or buyer — with real dollar examples.

<div style="margin-top: 14px;">

<a href="./USER_GUIDE.md" style="background: #22c55e; color: white; padding: 10px 18px; border-radius: 8px; text-decoration: none; font-weight: bold; display: inline-block;">📖 Open User Guide →</a>

</div>

<div style="margin-top: 12px; font-size: 0.85em; color: #6b7280;">

Calls vs Puts • Writer vs Buyer profit • 5-step flow<br>Fees in plain English • FAQ

</div>

</div>

<!-- Developer guide hidden until keeper/indexer/kuru integration ready
<div style="background: #ede9fe; border: 2px solid #836EF9; border-radius: 14px; padding: 22px; text-align: center;">
### 🧑‍💻 For Developers
## ⚙️ Developer Guide
**Full technical reference.**
Architecture, exact math & vectors, settlement proofs, contract interfaces, roles, deployment runbook, and test matrix.
<div style="margin-top: 14px;">
<a href="./DEVELOPER_GUIDE.md" style="background: #836EF9; color: white; padding: 10px 18px; border-radius: 8px; text-decoration: none; font-weight: bold; display: inline-block;">📖 Open Developer Guide →</a>
</div>
<div style="margin-top: 12px; font-size: 0.85em; color: #6b7280;">
Factories • Vaults • ChainlinkAnchor • Guards<br>Invariants • Fuzz • Slither
</div>
</div>
-->

</div>

---

## 🌟 What is Optara in one minute?

**Optara lets anyone create and trade options that are 100% backed by real collateral.**

```mermaid
flowchart LR
    W[✍️ Writer<br>locks collateral<br>gets tickets] --> K[🔄 Kuru<br>sells ticket<br>for premium]
    K --> Buyer[🛒 Buyer<br>pays premium<br>holds ticket]
    Buyer --> S[🔮 Chainlink<br>price at expiry<br>decides payout]
    S --> H[💸 Holder<br>burns ticket<br>gets payout]
    S --> Wr[🏦 Writer<br>reclaims<br>leftover]
    style W fill:#fef3c7,stroke:#f59e0b
    style K fill:#ffe4e6,stroke:#FF6B6B
    style S fill:#dbeafe,stroke:#375BD2
    style H fill:#dcfce7,stroke:#22c55e
    style Wr fill:#f0fdf4,stroke:#16a34a
```

| Job | Who does it | Can trading break it? |
|:---|:---|:---|
| 🛒 Who owns the ticket | <span style="color:#FF6B6B">**Kuru**</span> (order book) | — |
| 🏦 How much is owed | <span style="color:#22c55e">**Optara vault**</span> | **No** ✅ |
| 🔮 What price counts | <span style="color:#375BD2">**Chainlink at expiry**</span> | **No** ✅ |

> Because of this split, wash trades, thin liquidity, or a down market can change *who holds* a ticket — but **never** what the vault owes.

**At a glance:**

| Question | Answer |
|:---|:---|
| 🔗 Chain | Monad (uses `WMON`, not native MON) |
| 🎫 Style | European — redeem *only after* expiry |
| 🔒 Backing | 100% — Calls = underlying, Puts = quote |
| 🛒 Trading | Kuru (price discovery only) |
| 🔮 Settlement | Chainlink feed *pinned to expiry* (proven on-chain) |
| ✅ Audited? | Not yet — see launch checklist |

---

## 🧭 What’s inside

| Section | What you get |
|:---|:---|
| **Start** | 🔌 Wallet in 2 min (wrap `MON→WMON`, faucet) + 🧮 Profit calculator (break-even, PnL table) |
| **Core** | 💰 Writer vs Buyer profit with stock-like examples, 5-step flow |
| **Safety** | ⚠️ 3 must-know risks (illiquidity, delayed settlement, premium ≠ fair) |
| **Reference** | 📚 Full specs in `simple-workflow/` — math, contracts, oracle, guard, tests |

<!-- Developer guide contents hidden
| Section | Users | Developers |
|:---|:---|:---|
| **Start** | 🔌 Wallet + calculator | 📍 Deployments + ABIs |
| **Core** | 💰 Writer vs Buyer | 🏗️ Architecture, 📦 Contracts, 🧮 Math |
| **Safety** | ⚠️ 3 risks | 🚨 Errors/Events, 🔐 Threats |
| **Build** | — | 🍳 Recipes, ⛽ Gas, 🚀 Deploy |
| **Ops** | — | 🗺️ Roadmap, 📝 Changelog |
-->

---

## 📚 Where to go next

| I want to… | Open… |
|:---|:---|
| Understand options and make profit | **[USER_GUIDE.md](./USER_GUIDE.md)** — calls/puts, wallet setup, calculator, 5-step flow, fees, FAQ |
| See the lean build spec | [`simple-workflow/README.md`](./simple-workflow/README.md) — 6 files that define V1 |
| See the full 19-doc spec | [`workflow/README.md`](./workflow/README.md) — reference (`simple-workflow/` wins on conflict) |
| See contracts + test results | [`contracts/README.md`](./contracts/README.md) — layout, 286 tests, sizes, status |

<!-- Developer guide links hidden
| Integrate / audit / deploy | **[DEVELOPER_GUIDE.md](./DEVELOPER_GUIDE.md)** — math, proofs, addresses, recipes, gas, catalog |
| Check what changed | [`DEVELOPER_GUIDE.md#--changelog`](./DEVELOPER_GUIDE.md#-changelog) |
-->

---

<div align="center">

### 💚 Built with care. Tested heavily. Use with eyes open.

*If docs and code disagree, that’s a bug — fix one of them.*

</div>
