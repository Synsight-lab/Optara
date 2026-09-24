# Optara

**Capped, cash-settled on-chain options with exact portfolio margin and secondary trading on Kuru.**

> Status: V2 engineering specification baseline. This document describes the intended protocol design; it is not a claim that the contracts are production-ready or audited.

## 1. What is Optara?

Optara is an on-chain options protocol designed for Monad. It lets users create, buy, sell, trade, hedge, close, and settle **European-style capped call and put options**.

The system separates four responsibilities:

- **Optara smart contracts are the financial source of truth**: option creation, short obligations, pair-specific stablecoin collateral, portfolio margin, oracle settlement, and redemption.
- **`@optara/math` is the off-chain reference math package**: deterministic payoff, critical-point, margin, and settlement previews used by apps and tests. It never authorizes an on-chain state transition.
- **`@optara/sdk` is the developer interaction layer**: typed reads, previews, transaction builders, event parsing, and high-level Optara workflows. Every safety-critical action is revalidated by the contracts.
- **`@optara/kuru` is the optional Kuru integration package**: market discovery, trading helpers, buy-to-close workflows, and Kuru-specific asset movement. Kuru remains the external trading layer and is not part of Optara's solvency proof.

Optara V2 intentionally avoids relying on unlimited-loss naked calls and emergency liquidation as the primary solvency mechanism. Every option has a maximum contractual payout known at creation, and the core margin engine calculates the exact worst-case expiry loss for each supported portfolio risk group.

---

## 2. Why capped options?

A normal short call can have theoretically unlimited loss as the underlying price rises. That creates a difficult on-chain problem: a price can move faster than liquidators can react.

Optara solves this at the product level by putting a **maximum payout cap** into every option series.

For a call:

```text
payoff = min(max(settlementPrice - strike, 0), maxPayout) * contractSize * quantity
```

For a put:

```text
payoff = min(max(strike - settlementPrice, 0), maxPayout) * contractSize * quantity
```

Therefore:

```text
0 <= payout <= maxPayout * contractSize * quantity
```

The payout cap is immutable once the option series is created.

Economically, a capped call behaves like a call spread: the buyer participates above the strike until the cap is reached, then the payout stops increasing. A capped put behaves similarly on the downside.

---

## 3. Core V2 design

Optara V2 uses a layered architecture. The SDK packages make integrations easier, but they are **non-authoritative**: no SDK-computed margin, balance, health value, or trade result can bypass the canonical Solidity checks.

```text
                     APPLICATIONS
          Frontend / Bots / Market Makers / Integrators
                         |
                         v
                  +---------------+
                  |  @optara/sdk  |
                  +-------+-------+
                          |
              +-----------+-----------+
              |                       |
              v                       v
       +--------------+        +---------------+
       | @optara/math |        | @optara/kuru |
       | reference    |        | Kuru-specific|
       | math/previews|        | workflows    |
       +------+-------+        +-------+-------+
              |                        |
              |                        v
              |                      Kuru
              |
              v
        OPTARA SMART CONTRACTS
   +--------------------------------+
   | SeriesFactory                  |
   | OptionToken                    |
   | ClearingHouse                  |
   | MarginVault                    |
   | RiskEngine                     |
   | SettlementEngine               |
   | OracleAdapter                  |
   | AccessController               |
   +---------------+----------------+
                   |
                   v
     pair-specific stablecoin custody
     + bounded option obligations
     + exact on-chain risk enforcement
```

The important trust rule is:

```text
SDK preview / helper / route
          !=
protocol authorization
```

For example, `@optara/sdk` may preview that a write needs `3 USDT` of additional margin, but `ClearingHouse` and `RiskEngine` MUST independently recompute the post-write requirement before the short is created.

Long option ERC-20 tokens remain externally composable and can trade on Kuru or other venues. Kuru-specific logic is isolated behind `@optara/kuru` so another venue can be added later without changing core settlement or risk contracts.

---

## 4. Pair and settlement model

Every supported option market is defined as:

```text
UNDERLYING / QUOTE_STABLECOIN
```

The quote stablecoin is also the core V2 settlement and margin asset for that series. Examples:

```text
MON / USDT  -> strike, cap, margin, premium quote, and settlement in USDT
ETH / USDC  -> strike, cap, margin, premium quote, and settlement in USDC
BTC / USDe  -> strike, cap, margin, premium quote, and settlement in USDe
```

Core V2 does **not** cross-margin one stablecoin against another. A USDT balance cannot secure a USDC-settled short unless a future multi-collateral module explicitly prices and haircuts that conversion risk.

A stablecoin depeg changes the economic value of that market, but Optara remains contractually denominated in token units of the series settlement stablecoin. Only approved stablecoins should be enabled.

The settlement oracle must produce the underlying price in that same stablecoin unit (directly or through an explicitly approved conversion path); Optara must not assume every stablecoin is always exactly $1.

---

## 5. Core product properties

### European exercise

Options settle only at expiry. There is no early exercise in the core V2 design.

### Pair-stablecoin cash settlement

Each option series settles in the **stablecoin quoted by that market pair**. For example, a `MON/USDT` option settles in USDT and an `ETH/USDC` option settles in USDC. Writers do not need to deliver the underlying asset at expiry.

### Capped payout

Every series has an immutable maximum payout per option unit.

### ERC-20 long option tokens

The buyer side of an option series is represented by a fungible ERC-20 token. Long tokens can be transferred, traded, held by vaults, or returned to Optara to close a matching short obligation.

### Internal short positions

Short obligations are recorded inside Optara margin accounts rather than being freely transferable tokens. This prevents a short liability from being moved away from the collateral that secures it.

### Exact portfolio margin

Optara does not need FHS, SPAN, or a probabilistic volatility model for the core V2 margin calculation. Because payouts are bounded and piecewise linear, Optara can calculate the exact worst-case expiry loss for positions that are safe to net together.

### Conservative netting groups

Positions may be netted only inside the same risk group:

```text
same underlying
+ same expiry
+ same settlement asset
+ compatible settlement oracle/rules
```

Different expiries and different underlyings are not cross-margined in the core V2 design.

This avoids assuming that prices at different expiries or across different assets move together.

---

## 6. Simple example

Assume:

```text
Underlying       = MON
Pair             = MON / USDT
Settlement       = USDT
MON price today  = 8 USDT
Expiry           = 30 days
1 option         = 1 MON of exposure
```

Alice wants to sell a capped call:

```text
Strike           = 10 USDT
Maximum payout   = 5 USDT
```

The buyer can receive at most 5 USDT per option, even if MON rises far above the strike.

If Alice has no hedge, the margin engine can require up to the exact maximum liability:

```text
1 option * 5 USDT cap = 5 USDT required loss coverage
```

Alice does **not** need to lock 1 MON. Her obligation is denominated in the pair's stablecoin (USDT in this example) and bounded at 5 USDT.

If Alice also locks a long 12 USDT-strike call whose payoff offsets part of the $10 short call, the risk engine evaluates both positions together and may require less USDT collateral.

Only long option tokens deposited and locked inside Optara can reduce margin. A long token sitting in Alice's wallet or on Kuru is not counted as a hedge.

---

## 7. How writing an option works

The safe core flow is:

1. A valid option series exists.
2. The writer deposits the series' settlement stablecoin into an Optara margin account.
3. The writer calls `write()` for a quantity of the series.
4. The risk engine simulates the writer's portfolio after the new short is added.
5. The write succeeds only if the account can satisfy the resulting margin requirement.
6. Optara records the writer's short obligation.
7. Optara mints the same quantity of ERC-20 long option tokens.
8. The writer may keep, transfer, or sell those long tokens.

The long-token supply and aggregate open short quantity must remain economically matched.

---

## 8. How Kuru fits into Optara

Kuru is not Optara's risk engine and Kuru collateral is not automatically Optara collateral.

The recommended integration keeps venue-specific code in `@optara/kuru`:

```text
Application
   |
   +--> @optara/sdk --------> Optara contracts
   |
   +--> @optara/kuru -------> Kuru SDK/contracts
             |
             +-------------> @optara/sdk for follow-up Optara calls

Optara write()
   |
   v
ERC-20 Option Token
   |
   | @optara/kuru / ordinary ERC-20 transfer
   v
Kuru OPTION/<SETTLEMENT_STABLECOIN> Market
   |
   +--> buyer purchases option
   +--> holder resells option
   +--> writer can buy the same series back
```

The current Kuru SDK exposes standard market creation for ERC-20 pairs and Kuru trading uses Kuru's own margin-account balances. Therefore Optara must treat the two margin systems as separate accounting domains.

If a writer sells an option token on Kuru, the stablecoin sale proceeds are **not** automatically counted as Optara margin. `@optara/kuru` may help orchestrate withdrawal/routing, but the proceeds become collateral only when the exact stablecoin is actually received and credited by Optara. A future on-chain router may automate that movement, but it cannot bypass canonical deposit and margin accounting.

### Closing a short through Kuru

A writer can:

1. buy the same option series token on Kuru;
2. withdraw/transfer it to Optara;
3. call `closeShort(seriesId, quantity, EXTERNAL)`;
4. Optara burns the returned long token;
5. Optara reduces the matching short quantity;
6. the risk engine recalculates margin;
7. excess settlement-stablecoin collateral becomes withdrawable.

---

## 9. Margin model

For one risk group, define portfolio payoff to the account as:

```text
portfolioNetPayout(S)
    = longPayouts(S) - shortPayouts(S)
```

The writer's worst-case loss is:

```text
worstCaseLoss
    = max over valid settlement prices S of
      max(shortPayouts(S) - longPayouts(S), 0)
```

Core required margin for each risk group is:

```text
groupRequiredMargin = worstCaseLoss + configuredSafetyBuffer
```

For an account that has several risk groups using the same settlement stablecoin:

```text
requiredMarginByAsset(asset)
    = sum(groupRequiredMargin for groups settled in asset)

marginBalance(account, asset) >= requiredMarginByAsset(asset)
```

There is no conversion or offset between different stablecoins in core V2.

For the solvency-first V2 mode, the safety buffer may be zero or a small conservative amount; the worst-case loss itself must be fully covered by the risk group's settlement stablecoin and recognized locked hedges.

Because each capped payoff is piecewise linear, the exact worst case can be found by evaluating a finite set of price breakpoints such as strikes and cap boundaries.

### Important premium rule

A premium reduces required **additional external capital** only if that premium is actually held inside Optara in the same settlement stablecoin used by that risk group.

Premium sitting in a wallet or in a Kuru trading balance is not Optara collateral.

---

## 10. Why liquidation is not the primary solvency mechanism

In the core V2 solvency model, the account is required to cover the exact worst-case settlement loss before a new short can be created or collateral can be withdrawn.

Therefore an underlying price mooning does not create an unlimited new liability: the option payoff is capped and the worst-case liability was known in advance.

Liquidation is reserved for future or exceptional modes, for example:

- a future undercollateralized leverage mode;
- future non-settlement collateral whose value can fall relative to the settlement stablecoin;
- operational recovery paths explicitly designed into a later release.

The initial V2 should not rely on liquidators to save an otherwise insolvent naked call position.

---

## 11. Core contracts and off-chain packages

### Authoritative smart contracts

```text
SeriesFactory
    creates immutable option-series definitions

OptionToken / OptionTokenFactory
    ERC-20 long option tokens

ClearingHouse
    canonical margin-account state, shorts, writes, closes, hedge custody coordination,
    withdrawals, and account synchronization

MarginVault
    physical custody of approved pair-specific settlement stablecoins

RiskEngine
    canonical exact worst-case portfolio-margin calculation

SettlementEngine
    expiry finalization, payoff calculation, long redemption, and matured account settlement

OracleAdapter
    canonical normalized settlement-price interface

AccessController / Governance
    approved pairs, oracle configs, limits, and emergency controls
```

All financial safety decisions are enforced by these contracts.

### Non-authoritative modular packages

```text
@optara/math
    pure TypeScript/reference implementation of payoff, critical points,
    worst-case loss, margin, fixed-point conversions, and settlement previews

@optara/sdk
    contract clients, typed reads, transaction builders, previews,
    account/series/position/settlement helpers, event decoding

@optara/kuru
    Kuru market discovery/creation helpers, trading, inventory movement,
    buy-to-close orchestration, and market-maker utilities

@optara/shared
    ABIs, generated types, chain/deployment addresses, constants, and shared schemas
```

`@optara/math` SHOULD be differential-tested against the Solidity implementation, but Solidity remains authoritative.

`@optara/kuru` replaces the need for a Kuru-specific dependency inside the core contracts for the MVP. A future on-chain Kuru router/adapter MAY be added for atomic workflows, but it must remain optional and must never become required for Optara solvency or settlement.

---

## 12. Core invariants

At minimum, the implementation must preserve these rules:

1. **Payout cap**

   ```text
   0 <= payout <= maxPayout * contractSize * quantity
   ```

2. **Margin sufficiency**

   A write, withdrawal, or hedge unlock must not leave an account below required margin. Short positions cannot be transferred at all.

3. **No fake hedges**

   A long option counted as margin protection must be locked by Optara and cannot simultaneously be transferred, redeemed, or reused elsewhere.

4. **No double-counted hedge quantity**

   Recognized hedge quantity cannot exceed the long quantity actually locked.

5. **Long/short issuance conservation**

   Writing a new short obligation creates matching long option supply; closing a short burns matching long supply.

6. **Single redemption**

   A long option token must be burned when redeemed.

7. **Immutable economic terms**

   Type, underlying, strike, expiry, payout cap, settlement asset, and settlement rules cannot change after series creation.

8. **No unsafe cross-expiry netting**

   Core V2 does not use a position at one expiry to reduce the exact margin requirement of another expiry.

---

## 13. MVP scope

### Included

- European calls and puts
- capped payouts
- settlement in the stablecoin quoted by each approved pair
- writer collateral in the exact settlement stablecoin of each series/risk group
- protocol-wide support for multiple approved settlement stablecoins, with no cross-stablecoin netting
- ERC-20 long option tokens
- internal short positions
- exact same-expiry portfolio netting
- write, close, redeem, deposit, withdraw
- oracle-based settlement
- Kuru secondary-market integration path
- permissioned/whitelisted underlying-oracle combinations for initial deployment
- unit, fuzz, invariant, integration, and adversarial tests

### Deferred

- American exercise
- uncapped calls
- cross-asset portfolio margin
- cross-expiry statistical offsets
- FHS / SPAN margin
- undercollateralized naked leverage
- cross-stablecoin or volatile collateral substitution within a risk group
- automatic Kuru-to-Optara collateral routing
- tokenized transferable short positions
- lending against Optara option tokens

---

## 14. Repository layout

The recommended repository is a monorepo so the financial core and developer tooling remain clearly separated:

```text
optara/
├── README.md
├── docs/
│   ├── PRD.md
│   ├── ARCHITECTURE.md
│   ├── PROTOCOL_SPEC.md
│   ├── OPTION_SPEC.md
│   ├── MATH.md
│   ├── INVARIANTS.md
│   ├── MARGIN_AND_RISK.md
│   ├── LIQUIDATION.md
│   ├── USER_FLOWS.md
│   ├── STATE_MACHINE.md
│   ├── KURU_INTEGRATION.md
│   ├── ORACLE_AND_SETTLEMENT.md
│   ├── COMPOSABILITY.md
│   ├── SECURITY.md
│   ├── ACCESS_CONTROL.md
│   ├── FEES.md
│   ├── DESIGN_DECISIONS.md
│   ├── TESTING.md
│   ├── TEST_CASES.md
│   └── DEPLOYMENT.md
│
├── contracts/
│   ├── src/
│   │   ├── core/
│   │   │   ├── ClearingHouse.sol
│   │   │   ├── MarginVault.sol
│   │   │   ├── RiskEngine.sol
│   │   │   └── SettlementEngine.sol
│   │   ├── factory/
│   │   ├── token/
│   │   ├── oracle/
│   │   ├── access/
│   │   ├── interfaces/
│   │   └── libraries/
│   │       ├── PayoffMath.sol
│   │       ├── RiskMath.sol
│   │       └── FixedPointMath.sol
│   ├── test/
│   ├── script/
│   └── foundry.toml
│
├── packages/
│   ├── math/       # @optara/math
│   ├── sdk/        # @optara/sdk
│   ├── kuru/       # @optara/kuru
│   └── shared/     # @optara/shared
│
├── apps/
│   ├── web/
│   └── indexer/
│
└── package.json
```

The original Foundry `src/test/script` structure moves under `contracts/`; the protocol logic itself does not move into the SDK.

---

## 15. Recommended implementation order

```text
1. Solidity option payoff/fixed-point libraries
2. Series definitions + OptionToken
3. MarginVault + ClearingHouse account ledger
4. exact Solidity RiskEngine
5. write / close / lock / unlock / withdrawal flows
6. OracleAdapter + SettlementEngine
7. core invariant/fuzz suite
8. @optara/math reference implementation
9. differential tests: Solidity math/risk vs @optara/math
10. @optara/shared generated ABIs/types/deployment metadata
11. @optara/sdk contract clients + previews + transaction builders
12. @optara/kuru market/trading/buy-to-close integration
13. frontend/indexer built on the SDK packages
14. end-to-end integration/adversarial tests
15. audit + deployment hardening
```

This order deliberately implements and tests the financial source of truth before building convenience layers.

---

## 16. Security posture

Optara is a derivatives clearing protocol. A small accounting or settlement bug can create protocol-wide bad debt.

The implementation should assume hostile users and explicitly test:

- margin bypasses;
- hedge double-counting;
- stale or manipulated oracle data;
- rounding at strike/cap boundaries;
- token decimal mismatches;
- repeated redemption;
- short close without valid long tokens;
- reentrancy;
- ERC-20 transfer edge cases;
- expiry boundary races;
- fee/accounting conservation;
- denial of service from unbounded portfolio iteration.

No production deployment should occur before independent security review and extensive invariant testing.

---

## 17. External integration note

The Kuru integration assumptions in this specification are based on the currently published Kuru SDK behavior: Kuru provides ERC-20 base/quote markets and maintains Kuru-side trading balances separate from Optara. `@optara/kuru` is the isolation layer for those venue-specific workflows. If Kuru interfaces change, the preferred response is to update `@optara/kuru`, not Optara's core risk/settlement contracts. The exact deployed Kuru contracts and SDK version must still be revalidated before deployment.

---

## 18. Canonical safety refinements

The implementation baseline requires exact payoff numerators with no intermediate
rounding (`MATH.md` sections 24/54), atomic group settlement, atomic buyer payment
against delivery, donation-tolerant custody accounting, persistent scoped containment,
and aggregate gross issuance caps (released per risk group at finalization).
A verified loss of backing is resolved by one uniform, timelocked recovery ratio for
that asset (`LIQUIDATION.md` section 102). Existing obligations use immutable versioned cores.
Expired-unfinalized positions remain fully reserved but support safe cancellation
and free-collateral recovery. Permanent oracle failure may leave unmatched claims
unresolved; no guaranteed settlement deadline is promised. See `PROTOCOL_SPEC.md`
sections 41/42 and `ACCESS_CONTROL.md` sections 40–45.
