# Optara V2 Architecture

**Document type:** Technical architecture  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP  
**Settlement asset:** Pair-specific approved stablecoin  
**Network target:** Monad  
**Status:** Engineering baseline

---

## 1. Architectural objective

Optara V2 is a bounded-risk on-chain options clearing system.

The architecture must guarantee that:

1. option settlement liability is contractually bounded;
2. writer margin is calculated from deterministic portfolio payoffs;
3. only collateral and hedges under Optara control can secure a short;
4. long claims remain transferable and composable;
5. secondary trading can occur on Kuru without making Kuru part of Optara's solvency model;
6. settlement does not require iterating over every writer or holder in one transaction.

The core architectural principle is:

> **Optara clears and settles options; external venues trade the long tokens.**

---

## 2. Pair and settlement-asset model

Core V2 supports option markets quoted in approved stablecoins:

```text
UNDERLYING / QUOTE_STABLECOIN
```

For a given series, `quoteStablecoin == settlementAsset`. Strike, payout cap, premium quotes, cash margin, and expiry payout are denominated in that asset. For example:

```text
MON / USDT -> USDT margin and settlement
ETH / USDC -> USDC margin and settlement
BTC / USDe -> USDe margin and settlement
```

The protocol may custody several approved stablecoins at once, but core V2 keeps their solvency domains separate. USDT cannot secure a USDC-settled short, and USDC cannot secure a USDe-settled short. Cross-stablecoin collateral substitution requires a future collateral-pricing/haircut module and is intentionally outside the core design.

Optara guarantees settlement in units of the configured stablecoin, not that the stablecoin will always equal one U.S. dollar. Stablecoin depeg/issuer risk is therefore handled through the approved-asset whitelist and market disclosure, not by silently converting obligations into another stablecoin.

---

## 3. High-level architecture

Optara V2 uses four software layers with an explicit trust boundary.

```text
                       APPLICATION LAYER
          +----------------------------------------+
          | Web app / Bots / Market makers / dApps |
          +--------------------+-------------------+
                               |
                               v
                         @optara/sdk
                 typed Optara interaction layer
                               |
                 +-------------+-------------+
                 |                           |
                 v                           v
           @optara/math                 @optara/kuru
        reference math only          Kuru-specific flows
                 |                           |
                 |                           v
                 |                          Kuru
                 |
                 v
                    OPTARA CONTRACT LAYER
 +----------------------------------------------------------------+
 | SeriesFactory / OptionTokenFactory / OptionToken                |
 | ClearingHouse <-------> RiskEngine                              |
 |      |                    ^                                     |
 |      v                    |                                     |
 | MarginVault         PayoffMath / RiskMath                       |
 |      |                                                          |
 |      +-------> SettlementEngine <-------> OracleAdapter          |
 |                                      |                           |
 +--------------------------------------+---------------------------+
                                        |
                                        v
                                  Oracle provider(s)
```

### Authority rule

```text
Smart contracts
= authoritative balances, positions, risk, settlement, authorization

@optara/math
= off-chain reference implementation / preview / test oracle

@optara/sdk
= transaction construction and developer ergonomics

@optara/kuru
= optional venue-specific trading orchestration
```

No off-chain package may authorize a state change by supplying a precomputed "safe" result that the contracts trust without recomputation.

### Dependency direction

Preferred dependency graph:

```text
apps
 |
 +--> @optara/sdk --> @optara/shared
 |         |
 |         +--> @optara/math
 |
 +--> @optara/kuru --> @optara/sdk
 |          |
 |          +--> Kuru SDK/contracts
 |
 +--> @optara/math

contracts
 --> no dependency on TypeScript SDK packages
 --> no dependency on Kuru availability
```

This makes Kuru replaceable and keeps financial correctness inside the protocol.

---

## 4. Trust and accounting boundaries

### 4.1 Optara boundary

Optara is responsible for:

- series terms;
- custody and accounting for approved pair-specific settlement stablecoins;
- short obligations;
- recognized locked long hedges;
- margin calculations;
- expiry finalization;
- buyer redemption;
- writer settlement accounting.

### 4.2 Kuru boundary

Kuru is responsible for its own:

- order books;
- market matching/execution;
- Kuru trading balances/margin accounts;
- maker/taker execution behavior;
- market liquidity.

Optara MUST NOT assume that a balance visible inside Kuru is available to settle an Optara short.

### 4.3 Oracle boundary

Oracle data is external input. Optara must constrain its use through:

- approved adapters;
- exact decimal normalization;
- freshness/finality checks;
- immutable series settlement rules;
- single finalization.

---

### 4.4 SDK boundary

`@optara/sdk` is a non-authoritative client layer. It may:

- query series and account state;
- preview writes, withdrawals, hedge locks/unlocks, and settlement;
- build transactions;
- decode events and normalize application-facing types;
- batch safe read operations.

It MUST NOT:

- create synthetic collateral;
- bypass `RiskEngine`;
- bypass access control;
- treat a preview as proof of health;
- alter settlement results;
- mutate protocol state without a valid on-chain transaction.

Every safety-critical SDK workflow ends in a canonical contract call that independently verifies the operation.

### 4.5 Reference-math boundary

`@optara/math` mirrors documented protocol mathematics for:

```text
payoffs
critical prices
portfolio loss
worst-case loss
required-margin previews
fixed-point/native-unit conversions
settlement previews
```

It is intended for frontends, bots, simulations, indexers, and differential testing.

The Solidity libraries and `RiskEngine`/`SettlementEngine` remain authoritative. A disagreement between `@optara/math` and Solidity is a bug to investigate, not a reason for the contracts to trust the SDK result.

### 4.6 Kuru package boundary

`@optara/kuru` contains venue-specific client logic. It may depend on the Kuru SDK and `@optara/sdk`, but core Optara contracts do not depend on `@optara/kuru`.

A future on-chain Kuru router/adapter is optional and must remain outside the solvency assumptions.

## 5. Core contract and package map

### On-chain source of truth

```text
SeriesFactory
    |
    +--> SeriesRegistry / immutable series metadata
    |
    +--> OptionTokenFactory --> OptionToken(seriesId)

ClearingHouse <------> RiskEngine
    |                     |
    |                     +--> PayoffMath / RiskMath
    |
    +-------> MarginVault
    |
    +-------> locked OptionToken custody
    |
    +-------> SettlementEngine <------> OracleAdapter
```

### Off-chain modules

```text
@optara/shared
    ABIs, generated types, addresses, constants

@optara/math
    pure reference math and previews

@optara/sdk
    |
    +--> account/series/position clients
    +--> margin/settlement previews
    +--> transaction builders
    +--> event parsing

@optara/kuru
    |
    +--> Kuru market discovery/validation
    +--> buy/sell/inventory workflows
    +--> buy-to-close orchestration
    +--> optional market-maker helpers
    |
    +--> Kuru SDK/contracts
```

### Long-token external paths

```text
OptionToken(seriesId)
    |
    +-------> wallet / other DeFi
    +-------> Kuru OPTION/<SETTLEMENT_STABLECOIN> market
    +-------> return to ClearingHouse to close short
    +-------> lock in ClearingHouse custody as hedge
    +-------> redeem through SettlementEngine after finalization
```

Off-chain modules can make these paths easier but do not change their economic meaning.

---

## 6. SeriesFactory

### Responsibility

Creates or registers immutable option-series definitions.

### Series structure

Conceptually:

```solidity
struct Series {
    address underlying;          // identifier/address for priced asset
    OptionType optionType;       // CALL or PUT
    uint256 strike;              // normalized fixed-point price
    uint64 expiry;               // unix timestamp
    uint256 maxPayout;           // settlement-stablecoin units per contract unit
    uint256 contractSize;        // underlying exposure per token unit
    address settlementAsset;     // approved stablecoin quoted by this pair
    bytes32 oracleConfigId;      // immutable approved settlement config
    address optionToken;         // long ERC-20 token
}
```

Exact Solidity types may differ, but the economic fields MUST be immutable.

### Validation

Series creation must reject:

- expired or too-near expiry;
- zero strike where not explicitly supported;
- zero max payout;
- zero contract size;
- unapproved settlement asset;
- unapproved oracle configuration;
- unsupported underlying;
- put cap above strike if the protocol adopts `maxPayout <= strike` as a canonicalization rule;
- duplicate economic series if unique canonical series are required.

### Series ID

Prefer a deterministic hash of immutable economic terms so integrations can independently verify identity.

Example concept:

```text
seriesId = keccak256(
    underlying,
    type,
    strike,
    expiry,
    maxPayout,
    contractSize,
    settlementAsset,
    oracleConfigId
)
```

---

## 7. OptionToken

### Responsibility

Represents the transferable **long claim** for one series.

### Required properties

- ERC-20 compatible;
- one token contract per series or an equivalent factory-controlled fungible representation;
- mint/burn restricted to Optara-authorized contracts;
- exposes its series identity;
- transferable before expiry unless locked in Optara;
- burnable on short close;
- burnable on redemption.

### Why only the long side is tokenized

The long claim is safe to transfer because it does not carry margin liability.

The short side remains in the ClearingHouse because transferring it without a simultaneous collateral transfer and risk check can make the protocol insolvent.

---

## 8. MarginVault

### Responsibility

Holds the approved stablecoins that back Optara margin accounts and settlement payments. Each balance and liability is accounted for by settlement asset; assets are not silently converted or cross-netted.

### Key rule

A user's internal margin-account balance is tracked per settlement stablecoin and is a claim on matching assets held by the MarginVault, subject to open-position liabilities denominated in that same asset.

### Core operations

```text
deposit(account, settlementAsset, amount)
withdraw(account, settlementAsset, amount)  // only after risk check/sync
transferForRedemption(settlementAsset, recipient, amount)
```

### Security constraints

- use safe ERC-20 transfer semantics;
- reject unsupported fee-on-transfer/rebasing collateral;
- settlement engine/clearing house only may move protocol-held settlement stablecoins;
- no arbitrary governance sweep of user collateral;
- emergency recovery paths must exclude correctly accounted user funds.

The vault MUST maintain token-unit conservation independently for every approved `settlementAsset`; balances of one stablecoin are never treated as reserves for another.

---

## 9. ClearingHouse

### Responsibility

The ClearingHouse is the main account ledger and state-transition coordinator.

It stores or references:

```text
cash balances by settlement stablecoin
open short quantities
locked long hedge quantities
active risk groups
matured but not yet synchronized liabilities/credits
```

### Conceptual account state

```solidity
struct Account {
    mapping(address => uint256) cashBalance; // settlementAsset => token amount
    mapping(bytes32 => uint256) shortQty;
    mapping(bytes32 => uint256) lockedLongQty;
    // plus bounded enumerable indexes for active positions/risk groups
}
```

The production implementation must use storage layouts that allow bounded iteration.

### Main entry points

Conceptually:

```text
deposit(settlementAsset, amount)
withdraw(settlementAsset, amount)
write(seriesId, quantity, recipient)
closeShort(seriesId, quantity)
lockLong(seriesId, quantity)
unlockLong(seriesId, quantity)
syncSeries(account, seriesId)
syncAccount(account, seriesIds[])
```

### State transition rule

Every action that can increase risk or reduce recognized collateral MUST run the risk check on the resulting state before it commits.

---

## 10. Writing / issuance architecture

### Flow

```text
Writer
  |
  | deposit pair settlement stablecoin
  v
MarginVault + ClearingHouse
  |
  | write(series, qty)
  v
RiskEngine simulates post-write portfolio
  |
  +-- insufficient --> revert
  |
  +-- sufficient ----> record short qty
                       mint matching long tokens
                       send long tokens to recipient
```

### Conservation rule

For newly written quantity `Q`:

```text
aggregate open short obligation += Q
long token supply                += Q
```

For a short close of quantity `Q`:

```text
aggregate open short obligation -= Q
long token supply                -= Q
```

Subject to settlement/redemption accounting after expiry.

### Premium handling

`write()` does not need to know the market premium.

This is deliberate.

A writer can mint a long token against secured margin and later sell it on Kuru at the market price. The sale price is market-discovered rather than protocol-assigned.

Because Kuru is a separate accounting domain, sale proceeds are not Optara collateral until transferred/deposited back into Optara.

This avoids circular logic where the protocol depends on a premium that has not yet been received.

---

## 11. RiskEngine

### Objective

Calculate the exact maximum expiry loss of a supported bounded-payoff portfolio without FHS, SPAN, or a statistical price distribution.

### 11.1 Payoff functions

For quantity `Q` after applying contract size:

#### Call

```text
callPayoff(S) = min(max(S - K, 0), C) * Q
```

#### Put

```text
putPayoff(S) = min(max(K - S, 0), C) * Q
```

Where:

```text
S = settlement price
K = strike
C = maximum payout per unit
```

### 11.2 Account loss function

For one risk group:

```text
shortLiability(S) = sum(shortQty_i * payoffPerUnit_i(S))
longCredit(S)     = sum(lockedLongQty_j * payoffPerUnit_j(S))

portfolioLoss(S)  = max(shortLiability(S) - longCredit(S), 0)
```

Then:

```text
worstCaseLoss = max_S portfolioLoss(S)
```

### 11.3 Exact critical-point evaluation

Each capped payoff is piecewise linear.

Therefore the maximum portfolio loss occurs at a boundary of one of the linear regions, not at an arbitrary hidden price.

For a CALL with strike `K` and cap `C`, critical prices include:

```text
K
K + C
```

For a PUT with strike `K` and cap `C`, critical prices include:

```text
max(K - C, 0)
K
```

The risk group should evaluate the union of:

```text
0
all strikes
all cap boundaries
```

and any terminal boundary needed by the implementation. For calls, once price is above every `K + C`, all call payouts are flat, so no infinity search is required.

This allows exact bounded-risk margin with finite work.

### 11.4 Risk-group isolation

Core V2 uses:

```text
riskGroup = (
    underlying,
    expiry,
    settlementAsset,
    oracle/settlement domain
)
```

Required account margin is conservatively:

```text
requiredMargin(account, settlementAsset)
    = sum(worstCaseLoss(group) + groupBuffer
          for groups settled in settlementAsset)
```

No cross-expiry, cross-underlying, or cross-stablecoin offsets are recognized in the core engine.

### 11.5 Locked hedge requirement

A long token can reduce margin only if Optara controls it.

Flow:

```text
wallet long token
      |
      | deposit/lock
      v
ClearingHouse escrow
      |
      v
RiskEngine may count it
```

While locked, the token cannot:

- be transferred;
- be sold on Kuru;
- be redeemed separately;
- be counted again for another account.

### 11.6 Margin equation

Core solvency-first mode:

```text
groupRequiredMargin = exactWorstCaseLoss + safetyBuffer
```

and, after aggregation for all groups sharing that asset:

```text
marginBalance(account, settlementAsset)
    >= requiredMargin(account, settlementAsset)
```

If the protocol represents locked long credits directly in the loss function, the settlement-stablecoin requirement is already net of those hedges.

### 11.7 Why this does not require price-driven liquidation

If required margin covers exact worst-case loss, a price move cannot create a liability larger than the amount already modeled.

Therefore a correctly margined core V2 account remains settlement-solvent even if the underlying gaps sharply.

A future leveraged-margin engine may intentionally require less than exact worst-case loss, but that is a separate architecture requiring maintenance margin, liquidation, insurance, and gap-risk rules.

---

## 12. Kuru integration architecture

### Integration principle

Kuru is an external trading venue. The preferred Optara software boundary is an **off-chain package**:

```text
Application
    |
    +--> @optara/sdk ------> Optara contracts
    |
    +--> @optara/kuru -----> Kuru SDK/contracts
              |
              +-----------> @optara/sdk when the workflow also needs an Optara call
```

This prevents Kuru-specific client/API changes from leaking into core clearing contracts.

### Market shape

```text
Base  = Optara long option token
Quote = series settlement stablecoin
```

### Writer trading flow

```text
Optara write()
    |
    v
Long option ERC-20
    |
    | @optara/kuru helper / ordinary ERC-20 transfer
    v
Kuru OPTION/<SETTLEMENT_STABLECOIN> market
    |
    +--> buyer obtains long economic ownership
    |
    +--> seller receives quote asset in Kuru accounting domain
```

Kuru proceeds are not Optara collateral until the exact stablecoin is transferred into Optara and credited by `ClearingHouse`/`MarginVault`.

### Writer buy-to-close flow

```text
@optara/kuru buys exact same-series long
        |
        v
writer obtains actual ERC-20 custody
        |
        v
@optara/sdk builds closeShort()
        |
        v
ClearingHouse receives/controls + burns long
        |
        v
shortQty decreases
RiskEngine recomputes margin
```

The Kuru trade itself never decrements an Optara short.

### Why `@optara/kuru` is separate from `@optara/sdk`

The main SDK should remain useful even if Optara later supports another venue. Venue-specific market discovery, order parameters, Kuru margin-account behavior, and Kuru API changes belong in `@optara/kuru`.

### Optional future on-chain router

A future on-chain router/adapter MAY support atomic buy-to-close or premium-to-margin flows where the venue interface permits. Such a router:

- is convenience infrastructure;
- must deliver actual tokens/stablecoins before Optara credits them;
- must use ordinary `ClearingHouse` entry points;
- must not bypass risk checks;
- must not be required for settlement or solvency.

---

## 13. OracleAdapter

### Interface concept

```solidity
interface ISettlementOracle {
    function settlementPrice(bytes32 oracleConfigId, uint64 expiry)
        external
        view
        returns (uint256 price, uint256 timestamp, bool valid);
}
```

The exact interface may differ.

### Responsibilities

- provider-specific data retrieval;
- decimal normalization;
- staleness validation;
- finality validation;
- settlement-window logic;
- consistent price units;
- output expressed in the series `settlementAsset` units per underlying unit, or an explicitly configured derived path that produces those units;
- no implicit assumption that every stablecoin equals exactly one U.S. dollar.

The core SettlementEngine should not contain provider-specific parsing. `oracleConfigId` should bind the underlying, settlement asset, provider(s), decimal normalization, and any approved conversion path so `settlementPrice`, `strike`, and `maxPayout` share a coherent unit system.

---

## 14. SettlementEngine

### Series states

Recommended lifecycle:

```text
ACTIVE
  |
  | expiry reached
  v
EXPIRED_UNSETTLED
  |
  | valid oracle settlement price finalized
  v
SETTLED
```

Option-series terms remain immutable throughout.

### Finalization

For each series:

```text
settlementPrice = finalized oracle price
payoffPerUnit   = capped payoff function(settlementPrice)
seriesClaim     = payoffPerUnit * outstandingLongSupply
```

Both `settlementPrice` and `payoffPerUnit` become immutable after finalization. `seriesClaim` is reserved/accounted in that series' `settlementAsset`; it must never be backed by a different stablecoin.

### Long redemption

```text
holder -> redeem(seriesId, qty)
       -> burn qty long tokens
       -> transfer qty * payoffPerUnit units of settlementAsset
```

### Writer settlement without a global loop

Optara must not execute:

```text
for every writer in series:
    settle(writer)
```

That would become unbounded.

Instead, use **lazy per-account settlement** or bounded keeper batches.

Recommended baseline: lazy per-account synchronization.

When an account next performs a state-changing action, or when a keeper/user explicitly calls `syncSeries(account, seriesId)`:

1. read finalized `payoffPerUnit`;
2. calculate the account's short liability;
3. realize any locked-long credit for that matured series;
4. debit/credit the account cash ledger for `series.settlementAsset`;
5. clear the matured position quantities;
6. release any now-unused margin.

### Long redemption before writer sync

The MarginVault can custody multiple approved stablecoins, but accounting is segmented by asset. Account withdrawal rules treat matured unsynchronized short liabilities as debt in the exact settlement stablecoin of that series.

Therefore a writer cannot withdraw collateral that economically belongs to already-finalized long claims merely because their account has not yet been synchronized.

The exact accounting identities for pooled redemption and lazy short synchronization must be specified **per settlement asset** and invariant-tested in `SETTLEMENT.md` and `INVARIANTS.md` before implementation is finalized.

This is a critical area and should not be improvised during coding.

---

## 15. Account synchronization rules

Before these actions, the account MUST synchronize all matured positions relevant to the operation:

- withdrawal;
- unlocking a matured long hedge;
- closing/mutating a matured position;
- risk calculation that would otherwise count expired positions incorrectly.

The implementation should permit bounded explicit series lists to avoid scanning unbounded account history.

---

## 16. Withdrawal architecture

Withdrawal flow:

```text
withdraw request
      |
      v
sync required matured positions
      |
      v
simulate post-withdraw collateral
      |
      v
RiskEngine.requiredMargin(account, settlementAsset)
      |
      +-- insufficient --> revert
      |
      +-- sufficient ----> debit ledger
                           MarginVault sends settlementAsset
```

A user can withdraw only **free collateral**.

---

## 17. Hedge architecture

Example:

```text
Alice portfolio

SHORT  $10 CALL, cap $5
LONG   $12 CALL, cap $3  [locked in Optara]
```

The RiskEngine evaluates both across the same settlement prices.

The long $12 call can reduce required margin only while Optara controls it.

If Alice wants to sell the $12 long on Kuru:

1. request unlock;
2. RiskEngine recalculates portfolio without that hedge;
3. unlock succeeds only if the remaining balance in that risk group's settlement stablecoin is sufficient;
4. token returns to Alice;
5. Alice may then move it to Kuru.

This prevents a margin-reducing hedge from being sold out from under the protocol.

---

## 18. Liquidation architecture

### Core V2

Price-driven liquidation is not necessary for solvency if:

```text
recognized settlement-stablecoin balance + locked hedge protection
>= exact worst-case contractual loss
```

Core V2 should therefore avoid making liquidation the primary design dependency.

### Future leveraged mode

If a future release intentionally allows:

```text
initialMargin < exactWorstCaseLoss
```

then that mode requires a new specification for:

- mark-price source;
- initial margin;
- maintenance margin;
- liquidation threshold;
- partial vs full liquidation;
- liquidator incentives;
- close-out market liquidity;
- price-gap risk;
- insurance fund;
- bad-debt waterfall;
- socialized-loss policy.

That logic must not be mixed into the core engine by default.

---

## 19. Access control

Recommended roles:

```text
GOVERNANCE
    manages approved assets/oracles/fees/limits

PAUSER
    can stop narrowly scoped risky entry points

KEEPER (optional)
    can trigger public settlement/synchronization actions

FACTORY / MINTER roles
    internal contract permissions only
```

Governance must never be able to rewrite an existing series' strike, expiry, cap, or settlement price.

Emergency powers should be narrow and timelocked where practical.

---

## 20. Upgradeability

This is a launch decision, not an implementation detail.

If upgradeable:

- separate storage from logic carefully;
- timelock upgrades;
- protect immutable economic terms at the data layer;
- test storage layout migrations;
- define emergency-upgrade policy.

If immutable:

- use replaceable adapters/factories around immutable core components where possible;
- include migration tooling for a future protocol version.

The PRD intentionally leaves the final choice open.

---

## 21. Events and indexing

At minimum emit events for:

```text
SeriesCreated
CollateralDeposited
CollateralWithdrawn
OptionWritten
ShortClosed
LongLocked
LongUnlocked
SeriesExpired
SeriesSettled
LongRedeemed
AccountSeriesSynchronized
FeeCharged
ParameterChanged
Paused / Unpaused
```

Events should contain enough indexed fields for an external indexer to reconstruct:

- series catalog;
- long-token addresses;
- open short quantities;
- margin deposits/withdrawals;
- settlement state;
- redemption history.

Do not rely on events as the source of truth for on-chain solvency.

---

## 22. Gas and bounded-computation constraints

The protocol must not allow a single account to create an unbounded list of positions that every future action must iterate.

Possible controls:

- maximum active series per account;
- maximum series per risk group;
- explicit `seriesIds[]` passed to synchronization;
- per-risk-group cached position indexes;
- bounded batch operations;
- removal of zeroed positions from active indexes.

Risk-engine computation should scale with bounded active positions, not protocol-wide users.

---

## 23. Fixed-point arithmetic and rounding

All price, quantity, contract-size, and settlement-stablecoin conversions must use explicit fixed-point units.

The implementation specification must define:

- strike decimals;
- oracle price decimals;
- settlement stablecoin decimals;
- option-token decimals;
- contract-size decimals;
- multiplication/division rounding direction.

Security preference:

- never round in a way that pays a long more than the contractual cap;
- never round required margin downward if doing so can create a deficit;
- use shared math libraries so risk calculation and settlement calculation cannot disagree.

The payoff function used by `RiskEngine` and `SettlementEngine` should be the same library implementation.

---

## 24. Core invariants the architecture must preserve

### I-1. Payout bound

```text
0 <= payoff(series, S, Q) <= maxPayout * Q
```

### I-2. Post-action solvency

After any risk-increasing or collateral-decreasing action:

```text
for every settlementAsset:
recognizedCollateral(account, settlementAsset)
    >= requiredMargin(account, settlementAsset)
```

No surplus in one stablecoin may satisfy a deficit in another.

### I-3. Hedge custody

```text
recognizedLockedLong <= long tokens actually controlled by Optara
```

### I-4. No hedge double use

One unit of long exposure cannot be counted twice.

### I-5. Issuance conservation

Long claim creation must have matching short obligation creation.

### I-6. Close conservation

Closing short quantity requires destruction/consumption of equivalent long claim quantity.

### I-7. Single settlement price

A series has at most one finalized settlement price.

### I-8. Single redemption

A redeemed long token cannot redeem again because it is burned.

### I-9. No unsafe cross-group margin

Positions outside the permitted risk group cannot reduce one another's core margin requirement.

### I-10. Kuru independence

Optara remains settlement-correct if Kuru is unavailable.

### I-11. Off-chain non-authority

```text
SDK/math/Kuru-package result
!=
authorization to mutate Optara state
```

Every safety-critical state transition is independently validated by the authoritative contracts.

---

## 25. Recommended source tree

```text
optara/
├── contracts/
│   ├── src/
│   │   ├── core/
│   │   │   ├── ClearingHouse.sol
│   │   │   ├── MarginVault.sol
│   │   │   ├── RiskEngine.sol
│   │   │   └── SettlementEngine.sol
│   │   ├── factory/
│   │   │   ├── SeriesFactory.sol
│   │   │   └── OptionTokenFactory.sol
│   │   ├── token/
│   │   │   └── OptionToken.sol
│   │   ├── oracle/
│   │   │   ├── ISettlementOracle.sol
│   │   │   └── OracleAdapter.sol
│   │   ├── access/
│   │   │   └── AccessController.sol
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
│   ├── math/           # @optara/math
│   │   ├── payoff.ts
│   │   ├── criticalPoints.ts
│   │   ├── portfolio.ts
│   │   ├── risk.ts
│   │   ├── margin.ts
│   │   └── fixedPoint.ts
│   ├── sdk/            # @optara/sdk
│   │   ├── accounts/
│   │   ├── series/
│   │   ├── positions/
│   │   ├── margin/
│   │   ├── settlement/
│   │   ├── transactions/
│   │   └── contracts/
│   ├── kuru/           # @optara/kuru
│   │   ├── markets.ts
│   │   ├── trading.ts
│   │   ├── inventory.ts
│   │   ├── buyToClose.ts
│   │   └── marketMaker.ts
│   └── shared/         # @optara/shared
│       ├── abi/
│       ├── addresses/
│       ├── constants/
│       └── types/
│
└── apps/
    ├── web/
    └── indexer/
```

The SDK/package tree is modular application infrastructure. The contract tree contains every authoritative financial rule.

---

## 26. Implementation phases

### Phase 1 — Authoritative Solidity math

Implement and fuzz:

- capped call/put payoff;
- fixed-point conversion;
- critical prices;
- exact worst-case risk-group loss.

### Phase 2 — Series + token

Implement immutable series metadata and long ERC-20 tokens.

### Phase 3 — Collateral + clearing

Implement pair-stablecoin custody, account ledger, write, close, lock/unlock, and withdrawal safety.

### Phase 4 — Settlement

Implement oracle adapters, risk-group finalization, atomic account-group synchronization, and long redemption.

### Phase 5 — `@optara/math`

Implement the independent TypeScript/reference model and differential-test it against Solidity across unit, fuzz, and generated portfolio cases.

### Phase 6 — `@optara/shared` + `@optara/sdk`

Generate ABIs/types/deployment metadata and build typed read/preview/transaction workflows. SDK previews must call or reproduce canonical math but remain non-authoritative.

### Phase 7 — `@optara/kuru`

Implement market validation/discovery, buy/sell, inventory transfer, and buy-to-close workflows using the current Kuru integration surface.

### Phase 8 — Applications + hardening

Build web/indexer on top of the packages, then run end-to-end, invariant, adversarial, integration, gas, admin, and independent security review.

---

## 27. Architecture decisions intentionally deferred

These are not safe to guess during coding:

- production oracle provider;
- exact expiry settlement-window rule;
- series creation permissions;
- fee model;
- upgradeability;
- exact position-count limits;
- exact safety buffer;
- exact MVP scope of `@optara/kuru` and whether any future on-chain Kuru router is warranted;
- exact lazy-settlement accounting implementation;
- frontend listing process for Kuru option markets.

They must be resolved in the later protocol, oracle, settlement, fee, and deployment specifications.

---

## 28. Summary

The intended architecture is:

```text
APPLICATIONS
    |
    v
@optara/sdk --------------------+
    |                           |
    +--> @optara/math           +--> Optara contracts
    |
    +--> @optara/kuru -----------------> Kuru

Optara contracts:
    bounded claims
    + pair-stablecoin custody
    + exact portfolio risk
    + immutable settlement

SDK packages:
    previews
    + typed interactions
    + venue workflows
    + developer ergonomics
```

The architectural rule is simple:

> **Move integration complexity into modular packages, but keep every financial safety decision inside the contracts.**

This preserves composability and developer experience without turning an SDK, frontend, indexer, or Kuru into a trusted part of Optara solvency.
