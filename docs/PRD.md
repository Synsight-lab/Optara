# Optara V2 Product Requirements Document

**Document type:** Product Requirements Document  
**Protocol:** Optara  
**Target release:** V2 solvency-first MVP  
**Network target:** Monad  
**Settlement asset:** Pair-specific approved stablecoin  
**Status:** Engineering baseline

---

## 1. Product summary

Optara V2 is an on-chain options clearing protocol for **European-style capped calls and puts**.

The product allows a seller to create a bounded option obligation using the **stablecoin quoted by that option pair** as margin, mint a transferable ERC-20 long option token, and allow that long token to trade on Kuru or other compatible venues. At expiry, the long token redeems for a capped payoff in that same settlement stablecoin, determined by an oracle settlement price. Applications SHOULD interact through modular packages (`@optara/sdk`, `@optara/math`, and `@optara/kuru`), but these packages are non-authoritative: the Solidity contracts independently enforce every safety-critical rule.

The central product requirement is:

> A user must never be allowed to create, modify, or withdraw from an Optara portfolio in a way that leaves the core V2 system unable to cover the exact maximum contractual settlement loss of that portfolio.

The core V2 is designed to obtain capital efficiency through:

- capped liabilities;
- cash settlement rather than physical delivery;
- exact netting of compatible long and short positions;
- shared account collateral across compatible positions;
- transferable long option tokens;
- secondary-market liquidity through Kuru.

It does **not** obtain capital efficiency by allowing unlimited-loss calls to remain materially undercollateralized and hoping liquidation occurs in time.

---

## 2. Problem statement

Fully collateralized on-chain options are safe but often capital-inefficient:

- a covered call may require locking the full underlying asset;
- collateral is often isolated per position;
- long hedges may not reduce required collateral;
- users cannot easily reuse compatible protection across a portfolio;
- option liquidity becomes fragmented if every protocol also builds its own exchange.

At the other extreme, undercollateralized naked options can create bad debt when prices gap faster than liquidation.

Optara V2 must provide a middle design:

```text
bounded contractual payout
+ exact worst-case portfolio margin
+ pair-stablecoin settlement
+ transferable long option tokens
+ external trading venue integration
```

---

## 3. Goals

### G1. Bounded seller liability

Every option series MUST have a maximum payout known before trading begins.

### G2. Solvency-first margin

Core V2 MUST require sufficient collateral in the exact settlement stablecoin of each risk group, plus recognized locked hedges, to cover the exact worst-case settlement loss under the supported netting rules.

### G3. Capital efficiency

Optara SHOULD reduce collateral compared with naive per-position full collateral when positions genuinely offset one another.

### G4. Composability

Long option positions MUST be represented by transferable ERC-20 tokens.

### G5. External liquidity

The protocol SHOULD support secondary trading of option tokens on Kuru without making Kuru part of Optara's solvency assumptions.

### G6. Deterministic settlement

At expiry, settlement MUST be calculated from immutable option terms and an approved settlement oracle.

### G7. Auditable risk rules

The core margin logic MUST be deterministic and explainable. The MVP MUST NOT require FHS, SPAN, or a black-box statistical model.

### G8. Modular developer surface

Optara SHOULD expose a typed, modular off-chain developer surface:

```text
@optara/math -> deterministic reference math and previews
@optara/sdk  -> Optara reads, transaction builders, events, high-level workflows
@optara/kuru -> optional Kuru-specific trading/inventory workflows
```

These modules MUST NOT become trusted substitutes for on-chain margin, custody, authorization, or settlement checks.

---

## 4. Non-goals for core V2

The following are explicitly outside the core V2 MVP:

- American-style early exercise;
- uncapped call options;
- cross-underlying portfolio offsets;
- cross-expiry probabilistic netting;
- FHS margin;
- SPAN margin;
- volatility-model-based undercollateralized naked shorts;
- using one stablecoin or volatile asset to collateralize obligations denominated in another settlement asset;
- rehypothecation of user collateral;
- protocol-owned market making;
- guaranteeing Kuru liquidity;
- transferable/tokenized short liabilities;
- borrowing against long option tokens;
- automatic socialization of losses across healthy users.
- trusting SDK/client-calculated margin, health, balances, or external trade state as authoritative protocol state.

---

## 5. Users and roles

### 5.1 Option writer / seller

Deposits margin in the option pair's settlement stablecoin, creates a short obligation, receives newly minted long option tokens, and may sell those tokens to earn premium.

A writer can later close the short by acquiring the same long option series and returning/burning it through Optara.

### 5.2 Option buyer / long holder

Acquires a long option token and owns the right to the capped payoff in that series' settlement stablecoin at expiry.

The current holder at redemption receives the payout; the original buyer is not special.

### 5.3 Trader / market maker

Trades long option tokens on Kuru or another supported ERC-20 venue.

### 5.4 Hedged writer

A writer who locks compatible long option tokens in Optara. The risk engine may recognize those locked longs to reduce margin.

### 5.5 Protocol operator / governance

Manages whitelisted assets, oracle adapters, approved settlement assets, protocol parameters, emergency controls, and upgrades if the deployment is upgradeable.

Governance MUST NOT be able to change the economic terms of an already-created option series.

### 5.6 Developer / integrator

Uses `@optara/sdk` for typed Optara interactions, `@optara/math` for previews/reference calculations, and optionally `@optara/kuru` for venue-specific trading workflows. Integrator software is advisory/convenience infrastructure; contracts remain the source of truth.

---

## 6. Product terminology

### Pair / market

Every core V2 series belongs to a market of the form:

```text
UNDERLYING / QUOTE_STABLECOIN
```

The quote stablecoin is also the series `settlementAsset` and the required cash collateral asset for unhedged liability in that risk group. Examples: `MON/USDT`, `ETH/USDC`, `BTC/USDe`. Core V2 does not cross-margin balances between different settlement stablecoins.

### Option series

A unique immutable combination of:

```text
underlying
option type: CALL or PUT
strike
expiry
max payout per unit
contract size
settlement asset
oracle / settlement rule
```

### Long option token

ERC-20 token representing the buyer-side claim for one specific option series.

### Short obligation

Internal Optara accounting entry recording how many units of a series a margin account has written.

### Max payout

Maximum settlement-stablecoin payout per option unit before multiplying by quantity/contract size.

### Risk group

Positions eligible for exact portfolio netting. Core V2 requires the same:

```text
underlying
expiry
settlement stablecoin
settlement rule/oracle domain
```

### Locked hedge

A long option token deposited into Optara and explicitly locked for margin purposes. It cannot be transferred or redeemed while used by the risk engine.

---

## 7. Product rules

### PR-1. European settlement only

An option MUST settle only after its expiry timestamp and valid settlement-price finalization.

### PR-2. Cash settlement only

Settlement MUST be paid in the configured **quote/settlement stablecoin of the option pair**. Core V2 MUST support only governance-approved stablecoins and MUST NOT silently convert between settlement assets.

### PR-3. Payout cap is mandatory

Every series MUST define `maxPayout > 0`.

For puts, the implementation SHOULD require:

```text
maxPayout <= strike
```

because an asset price cannot settle below zero and a larger cap adds no economic value.

### PR-4. Immutable series terms

After series creation, no privileged role may change:

- call/put type;
- underlying;
- strike;
- expiry;
- max payout;
- contract size;
- settlement asset;
- settlement oracle/rule.

### PR-5. Short positions are not freely transferable

A user MUST NOT be able to transfer a short obligation away from its securing margin account in core V2.

### PR-6. Long tokens are transferable

Long option tokens MUST be standard transferable ERC-20 assets unless they are currently escrowed/locked inside Optara.

---

## 8. Option payoff requirements

Let:

```text
S = settlement price
K = strike
C = max payout per unit
Q = quantity adjusted for contract size
```

### Call

```text
CallPayoff = min(max(S - K, 0), C) * Q
```

### Put

```text
PutPayoff = min(max(K - S, 0), C) * Q
```

The implementation MUST preserve:

```text
0 <= Payoff <= C * Q
```

for every valid settlement price.

The cap MUST apply to contractual settlement, not be introduced retroactively after a writer loses money.

---

## 9. Margin requirements

### 9.1 Core requirement

For each margin account **and for each settlement stablecoin independently**:

```text
recognizedCollateral(account, settlementAsset)
    >= requiredMargin(account, settlementAsset)
```

must hold after every operation that can increase risk or remove collateral. Core V2 MUST NOT sum token values across different settlement stablecoins to satisfy this check.

### 9.2 Recognized collateral

Core V2 recognizes:

- the exact settlement stablecoin held inside the Optara margin account for that risk group;
- compatible long option tokens explicitly deposited and locked as hedges.

Core V2 MUST NOT count as collateral:

- the same stablecoin held only in the user wallet;
- wallet long option tokens;
- Kuru margin balances;
- unconfirmed sale proceeds;
- positions in external protocols;
- unapproved collateral assets.

### 9.3 Exact worst-case margin

Within one supported risk group:

```text
loss(S) = shortPayoffs(S) - longPayoffs(S)
worstCaseLoss = max(max(loss(S), 0))
```

Required margin for one risk group is:

```text
groupRequiredMargin = worstCaseLoss + safetyBuffer
```

Account requirement is then aggregated **by settlement asset**, not by converting everything to dollars:

```text
requiredMargin(account, asset)
    = sum(groupRequiredMargin for account risk groups settled in asset)
```

The exact implementation MUST evaluate every relevant payoff breakpoint, not sample a small arbitrary price range.

### 9.4 Safe netting scope

Core V2 MAY net positions only when they are in the same risk group.

It MUST NOT reduce a January expiry margin requirement using a February expiry long position.

It MUST NOT reduce MON risk using ETH options.

It MUST NOT use USDT collateral or USDT-settled option credits to satisfy a USDC-settled margin requirement, or vice versa.

### 9.5 Premium handling

Premium is market consideration, not magical collateral.

If an option is sold on Kuru, the premium is initially part of the user's Kuru trading balance according to Kuru's trading flow. It MUST NOT reduce Optara margin until the same settlement stablecoin is actually deposited into Optara.

If a future Optara-Kuru adapter routes premium directly into Optara, the deposit must complete before the risk engine counts it.

---

## 10. Required user flows

### UF-1. Deposit collateral

1. User approves the option pair's settlement stablecoin to Optara.
2. User calls `deposit(settlementAsset, amount)`.
3. MarginVault receives that settlement stablecoin and credits the corresponding asset balance.
4. ClearingHouse credits `marginBalance[user][settlementAsset]`.
5. Event is emitted.

### UF-2. Create/write an option

1. User selects an existing valid series.
2. User chooses quantity.
3. ClearingHouse simulates the portfolio after adding the short.
4. RiskEngine calculates post-trade required margin.
5. If insufficient, transaction reverts.
6. If sufficient:
   - short quantity increases;
   - matching long option tokens are minted;
   - long tokens are sent to the specified recipient.

The system MUST not mint long claim supply without creating matching short obligation.

### UF-3. Sell the long token on Kuru

1. Writer moves the ERC-20 option token into the required Kuru trading flow.
2. Writer lists/sells OPTION against that series' settlement stablecoin.
3. Buyer receives the option token after trade settlement.
4. Writer receives trading proceeds in Kuru's accounting domain.
5. Optara's short position remains attached to the original writer's Optara margin account.

Trading the long token MUST NOT transfer the original writer's short liability.

### UF-4. Secondary trading

Any holder may transfer or sell the long option token before expiry, subject to ERC-20 and external venue rules.

The holder at redemption owns the claim.

### UF-5. Lock a hedge

1. User deposits a compatible long option token into Optara.
2. User marks quantity as locked for margin.
3. RiskEngine recalculates required margin.
4. If the hedge lowers exact worst-case loss, excess collateral in that settlement stablecoin may become withdrawable.
5. Locked long quantity cannot be transferred or redeemed until unlocked.

### UF-6. Close a short

1. Writer acquires the same series long token.
2. Writer approves/transfers the token to Optara.
3. Writer calls `closeShort(seriesId, quantity)`.
4. ClearingHouse verifies short quantity exists.
5. The long token is burned.
6. Matching short quantity is reduced.
7. Margin is recalculated.
8. Excess collateral in the applicable settlement stablecoin becomes available.

### UF-7. Withdraw collateral

1. User calls `withdraw(settlementAsset, amount)` for a specific settlement stablecoin.
2. ClearingHouse settles/synchronizes any matured positions required for safe accounting.
3. RiskEngine computes post-withdraw margin.
4. Withdrawal succeeds only if all requirements remain satisfied.

### UF-8. Finalize expiry

1. Expiry passes.
2. OracleAdapter obtains a valid settlement price according to configured rules.
3. SettlementEngine records the final settlement price exactly once.
4. SettlementEngine calculates `payoffPerUnit`.
5. Series enters `SETTLED` state.

### UF-9. Redeem a long

1. Holder calls `redeem(seriesId, quantity)`.
2. Optara burns the holder's long option tokens.
3. Optara transfers `payoffPerUnit * quantity` units of the series' settlement stablecoin.
4. A redeemed token cannot be used again.

### UF-10. Settle a writer account

1. Account contains a matured short position.
2. ClearingHouse calculates the fixed liability using finalized `payoffPerUnit`.
3. Liability is charged against the account's balance for that series' settlement stablecoin.
4. Matured short quantity is cleared.
5. Locked matured long hedges are realized/burned or credited according to settlement logic.
6. Remaining collateral becomes available subject to other open positions.

This flow MUST be implementable without iterating over every writer in a series in a single transaction.

---

## 11. Kuru integration requirements

Kuru is a secondary trading dependency, not a settlement dependency.

### KI-1. ERC-20 compatibility

Optara long tokens MUST behave as ordinary ERC-20 assets suitable for an external market.

### KI-2. Separate accounting domains

Documentation and frontend UX MUST distinguish:

```text
Optara Margin Account
!=
Kuru Trading Margin Account
```

### KI-3. Market structure

The preferred market is:

```text
base asset  = Optara option token
quote asset = series settlement stablecoin
```

### KI-4. No solvency dependency

Optara settlement MUST continue to function if:

- Kuru has no liquidity;
- the Kuru market is paused/unavailable;
- the option token is not actively listed on a frontend.

### KI-5. Close via acquired token

Optara MUST allow a writer to close a short using a valid long token acquired from Kuru or any other source.

### KI-6. Adapter is optional

Any Kuru adapter MUST be convenience infrastructure only. A bug or outage in the adapter must not invalidate Optara's core margin or settlement accounting.

---

### KI-7. Kuru integration package

The recommended client architecture is:

```text
Application
   |
   +--> @optara/sdk  --> Optara contracts
   |
   +--> @optara/kuru --> Kuru SDK/contracts
             |
             +-------> @optara/sdk when an Optara action is also required
```

`@optara/kuru` MAY orchestrate workflows such as market lookup, buy-to-close, inventory movement, and premium routing, but it MUST NOT directly credit Optara collateral, decrement a short, or recognize a hedge without the corresponding canonical Optara state transition.

## 12. Oracle requirements

### OR-1. Provider abstraction

Optara MUST use an oracle interface rather than hard-coding one provider into core accounting logic.

### OR-2. Series-specific oracle domain

Each series MUST reference an approved oracle/settlement configuration at creation. The configuration MUST bind the priced underlying to the series `settlementAsset`; the risk and settlement engines must interpret `S` and `K` in the same quote-stablecoin units.

### OR-3. Settlement finality

Settlement price MUST be finalized once and then immutable.

### OR-4. Staleness checks

The oracle adapter MUST reject stale or invalid data according to the selected provider's semantics.

The implementation MUST NOT assume every approved stablecoin is exactly worth one U.S. dollar. If a provider does not expose a direct `UNDERLYING/SETTLEMENT_STABLECOIN` price, any derived price path must be explicit in `oracleConfigId` and must include the conversion needed to express the underlying in settlement-stablecoin units.

### OR-5. Expiry rule

The exact price-selection rule around expiry MUST be specified before production deployment, for example a provider-specific price update at/after expiry or a defined time-weighted settlement rule.

This is a launch-blocking decision and cannot remain ambiguous in production.

### OR-6. Failure path

The production specification MUST define what happens if no valid price is available within the normal settlement window. Governance must not have arbitrary discretion to choose a profitable price for one side.

---

## 13. Settlement and solvency requirements

### SR-1. Per-asset claim safety

Solvency MUST be enforced **per settlement stablecoin**. Finalized claims in one stablecoin MUST NOT rely on balances held in another.

Total outstanding long claims must remain backed by writer obligations secured under the margin rules.

### SR-2. No withdrawal around unpaid matured debt

A writer MUST NOT withdraw collateral while ignoring a matured short liability.

### SR-3. No unbounded settlement loop

Finalizing one series MUST NOT require looping through all writers or holders.

### SR-4. Long redemption is fungible

Any valid holder of the series token receives the same payout per unit.

### SR-5. No socialized loss in core V2

A healthy user's collateral MUST NOT be intentionally confiscated to cover another account's shortfall under normal operation.

The architecture is expected to prevent such shortfalls through exact bounded-risk margin.

---

## 14. Liquidation requirements

Liquidation is **not** the primary solvency mechanism for the core V2 bounded-risk mode.

A price move in the underlying should not make a properly margined core V2 account insolvent because the maximum contractual loss is already bounded and margin is based on exact worst-case expiry loss.

Therefore:

- core V2 MAY omit price-driven liquidation entirely;
- or implement a limited safety/position-reduction mechanism for operational reasons;
- any future undercollateralized leverage mode MUST have a separate specification covering initial margin, maintenance margin, liquidation incentives, gap risk, and insurance/bad-debt handling.

The future leverage mode MUST NOT be silently enabled by changing one margin parameter in production.

---

## 15. Composability requirements

### CR-1. Transferable long token

A long option token MUST be usable by wallets, Kuru, vaults, and other ERC-20-aware contracts.

### CR-2. Stable metadata

External integrations MUST be able to query immutable series metadata.

### CR-3. No external hedge assumption

An external protocol holding an Optara long does not automatically reduce an Optara writer's margin. Only tokens locked under Optara control can be recognized.

### CR-4. Permissionless holder redemption

Any holder should be able to redeem after settlement without needing the original writer or original buyer.

### CR-5. Short liability isolation

Composability of the long token MUST NOT make short liabilities transferable without collateral checks.

---

## 16. Functional requirements by component

### SeriesFactory

MUST:

- create unique series IDs;
- reject invalid expiries;
- reject zero strike/cap/contract size where inappropriate;
- enforce approved underlying/oracle/settlement combinations;
- prevent duplicate series or deterministically map identical terms to one series;
- permanently freeze series economic terms.

### OptionToken

MUST:

- implement standard ERC-20 behavior;
- be mintable/burnable only through authorized Optara contracts;
- expose/resolve its `seriesId`;
- use deterministic decimals appropriate to contract size/quantity design.

### MarginVault

MUST:

- custody governance-approved settlement stablecoins;
- prevent arbitrary transfers by users;
- transfer only under ClearingHouse/SettlementEngine authorization;
- use safe ERC-20 transfer handling;
- maintain accounting conservation per settlement asset;
- never satisfy one settlement asset's liabilities by silently spending another stablecoin.

### ClearingHouse

MUST:

- manage account collateral ledger by settlement asset;
- manage short quantities;
- manage locked long hedges;
- enforce risk checks before state-changing actions;
- support write, close, deposit, withdraw, lock, unlock, and settlement synchronization.

### RiskEngine

MUST:

- calculate exact supported worst-case loss;
- net only permitted positions;
- reject portfolios exceeding implementation limits;
- use fixed-point arithmetic with explicit rounding direction;
- expose required margin by settlement asset, e.g. `requiredMargin(account, settlementAsset)`.

### SettlementEngine

MUST:

- finalize settlement exactly once;
- calculate fixed payoff per unit;
- support long redemption;
- support lazy/batched writer-account synchronization;
- prevent double redemption and double short settlement.

### OracleAdapter

MUST:

- normalize provider data into Optara price units;
- validate timestamps/freshness;
- enforce configured settlement rule;
- expose clear failure states.

---

### Off-chain developer packages

The MVP SHOULD maintain these modular packages:

#### `@optara/math`

MUST/SHOULD:

- implement deterministic reference payoff, critical-point, worst-case-loss, margin, and settlement calculations;
- use the same documented units and rounding model as the Solidity implementation;
- be used for differential/reference tests;
- never be trusted by contracts as proof of account health.

#### `@optara/sdk`

SHOULD provide:

- typed contract clients and generated types;
- series/account/position reads;
- margin and settlement previews;
- transaction builders for deposit, write, close, lock, unlock, withdraw, sync, and redeem;
- event decoding and transaction-result helpers.

Every state-changing transaction MUST still pass all on-chain checks.

#### `@optara/kuru`

SHOULD isolate Kuru-specific logic such as:

- canonical market discovery/validation;
- market creation helpers where supported;
- buy/sell workflows;
- option/stablecoin inventory movement;
- buy-to-close orchestration;
- market-maker helpers.

A Kuru package failure MUST NOT affect Optara solvency or settlement correctness.

## 17. Risk-engine implementation constraints

The risk engine MUST avoid unbounded gas growth.

Core V2 SHOULD impose explicit limits such as:

- maximum open series per account;
- maximum positions per risk group;
- maximum distinct risk groups per account;
- maximum batch operations.

The exact values are deployment parameters and must be benchmarked.

Because capped option payoffs are piecewise linear, exact worst-case loss can be found by evaluating finite critical settlement prices. The implementation should use this structure rather than brute-force price grids.

---

## 18. Security requirements

The implementation MUST have tests covering at least:

- payout cap enforcement at extreme prices;
- strike/cap boundary rounding;
- put price floor at zero;
- margin after write;
- margin after closing a short;
- margin after locking/unlocking a hedge;
- attempted hedge double-use;
- transfer of locked long token;
- withdrawal that would break margin;
- cross-expiry netting rejection;
- cross-underlying netting rejection;
- double redemption;
- double settlement;
- oracle stale data;
- oracle decimal conversion;
- malicious/reentrant ERC-20 behavior where relevant;
- fee-on-transfer/rebasing token rejection for collateral;
- series metadata immutability;
- supply/short conservation;
- accounting conservation;
- expiry boundary ordering;
- Kuru integration not affecting Optara solvency.
- SDK preview values never being accepted as authorization without on-chain recomputation;
- differential tests between Solidity payoff/risk math and `@optara/math`.

A production release requires independent audit/review.

---

## 19. Acceptance criteria for V2 MVP

V2 MVP is functionally complete when all of the following are true:

1. A user can deposit an approved settlement stablecoin and the balance is tracked by asset.
2. An approved series can be created.
3. A sufficiently margined user can write the series.
4. Writing creates a short obligation and matching long ERC-20 supply.
5. An insufficiently margined write reverts.
6. A long token can be transferred between wallets.
7. A long token can be traded in a Kuru `OPTION/<series settlement stablecoin>` market in an integration test or supported deployment environment.
8. A writer can buy/acquire the same long token and close the short.
9. Compatible locked longs reduce exact margin where mathematically valid.
10. Incompatible expiries/underlyings do not reduce margin.
11. A user cannot withdraw below required margin.
12. A series can be finalized after expiry using the configured oracle rule.
13. A holder can redeem the correct capped payout in the series' settlement stablecoin.
14. A writer's matured liability is correctly charged without requiring a global writer loop.
15. Fuzz/invariant tests show no payout above cap, no double redemption, no unsafe hedge reuse, and no collateral withdrawal below required margin.
16. `@optara/math` reference calculations match Solidity across the supported test domain.
17. `@optara/sdk` can build the core user transactions without becoming an authorization source.
18. `@optara/kuru` can discover/use the canonical `OPTION/<settlement stablecoin>` market while preserving the Kuru/Optara accounting boundary.

---

## 20. Launch-blocking open decisions

The following must be finalized in later specifications before production implementation is considered complete:

1. exact whitelist of supported settlement stablecoins and token addresses for each environment;
2. exact supported underlying/stablecoin pair combinations;
3. initial supported underlying(s);
4. production settlement-oracle provider(s);
5. exact direct or derived oracle path for each `UNDERLYING/SETTLEMENT_STABLECOIN` pair;
6. exact expiry price-selection/finality rule;
7. contract size and token decimal convention;
8. series-creation permission model;
9. minimum/maximum strike, cap, expiry, and quantity bounds;
10. protocol fee schedule;
11. whether the initial deployment is immutable or upgradeable;
12. governance/admin model and timelocks;
13. emergency pause scope;
14. account/risk-group position-count limits;
15. exact safety-buffer policy;
16. Kuru market-creation and frontend-listing operational process;
17. settlement accounting details for lazy writer synchronization;
18. exact MVP scope of `@optara/kuru` and whether any separate on-chain Kuru router/adapter is needed later.

None of these open items should be silently inferred by an implementation agent.

---

## 21. Product principle for engineers and AI agents

When implementation details conflict with this PRD, prefer the interpretation that preserves these properties in order:

```text
1. solvency
2. immutable buyer/seller contract terms
3. correct settlement
4. no double-counting of collateral or hedges
5. deterministic margin
6. composability
7. gas efficiency
8. convenience
```

A convenience feature must never weaken the first five properties.

