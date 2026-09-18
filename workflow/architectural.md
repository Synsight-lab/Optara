# Architecture

## Overview

The protocol is split into two layers:

```text
Options Protocol Layer
  - Creates canonical option series
  - Custodies collateral
  - Mints ERC-20 option tokens
  - Settles from an approved oracle
  - Pays buyers and releases writer residual collateral

Kuru Trading Layer
  - Lists ERC-20 option tokens against the quote asset
  - Supports secondary trading through Router and OrderBook markets
  - Provides market price discovery
  - Does not control collateral or settlement
```

This separation is the core architecture. Kuru can affect who owns option tokens, but it cannot affect what those tokens are worth at settlement.

## External Kuru Interface

Current Kuru docs describe the Router as the market deployment and routing contract. The Router stores verified market parameters and exposes market deployment through `deployProxy`. For an option token market, the expected pair is:

```text
base asset  = option ERC-20 token
quote asset = quote ERC-20 token
market type = NO_NATIVE when both assets are ERC-20s
```

Kuru docs also describe each market as an OrderBook with integrated AMM liquidity, with order placement, market orders, cancellations, liquidity provisioning, and market states. This project treats those features as trading infrastructure only.

Implementation note: Kuru market deployment may be called directly through Router or through the Kuru SDK helper that wraps market parameter calculation and deployment.

Kuru references checked on 2026-09-18:

- [Kuru Router Contract Documentation](https://docs.kuru.io/contracts/Router)
- [Kuru Architecture Overview](https://docs.kuru.io/contracts/Architecture-overview)
- [Kuru OrderBook Contract](https://docs.kuru.io/contracts/OrderBook)
- [Kuru SDK create market example](https://github.com/Kuru-Labs/kuru-sdk/blob/main/examples/v2/createMarket.ts)

Before production deployment, re-verify Kuru Router, SDK, and market-parameter behavior against the deployed Monad environment.

## Core Contracts

### `OptionSeriesFactory`

Creates canonical option series.

Responsibilities:

- Validate requested series parameters.
- Deploy a new `OptionSeriesVault`.
- Register the deployed series in `SeriesRegistry`.
- Optionally call a Kuru integration helper to deploy or record a Kuru market.
- Emit `SeriesCreated`.

Security requirements:

- Reject invalid strikes, expiries, contract sizes, oracle configs, or assets.
- Reject fee rates above the hard caps.
- Accept only `CreateSeriesParams`; derive or snapshot everything else.
- Enforce deterministic identity for a series.
- Prevent duplicate canonical series unless the duplicate resolves to the existing series.

### `SeriesRegistry`

Canonical source of truth for official series.

Responsibilities:

- Map `seriesId` to the vault address, and back again. The vault is itself the option token, so this is one address per series, not two.
- Expose immutable series parameters.
- Store optional Kuru market metadata.
- Own the `kuruLinkPaused` flag, since it owns `linkKuruMarket`.
- Let frontends and integrations verify whether an option token is official.

Security requirements:

- Only the factory can register a new series.
- Registry entries for immutable series parameters cannot be altered.
- Kuru market metadata can be append-only or tightly permissioned.

### `OptionSeriesVault`

The per-series contract that combines option-token behavior with collateral accounting.

Responsibilities:

- Store immutable series parameters.
- Accept writer collateral.
- Mint ERC-20 option tokens.
- Track writer short obligations.
- Stop minting at expiry.
- Settle using `OracleRouter`.
- Burn option tokens during redemption.
- Pay option holders.
- Release residual collateral to writers.

Security requirements:

- Series parameters are immutable.
- Minting requires collateral first.
- No early exercise in V1.
- Settlement result is written once.
- Redemption and writer withdrawals are idempotent at the user-accounting level.
- External token transfers happen after internal state updates.

### `OracleRouter`

Produces the independent settlement and reference prices for a series. It is the only component that applies oracle policy.

Responsibilities:

- Read the series' immutable `OracleConfig` from `SeriesRegistry` using `seriesId`.
- Use Chainlink as primary when configured and available for the pair.
- Use Pyth as secondary/corroborator when configured and available for the pair.
- Optionally use independent DEX TWAP as a tertiary sanity check.
- Apply all freshness, deviation, and quorum policy.
- Reject zero, negative, stale, or incomplete prices.
- Forward only the required pull-oracle fee and refund the remainder.

Security requirements:

- Kuru prices must never be used as settlement oracle prices.
- The router must never accept a caller-supplied `OracleConfig`. A config passed as an argument is a config any caller can weaken, and nothing would bind it to the series it claims to describe.
- Chainlink/Pyth deviation must be checked when both are configured.
- Settlement must fail safely if the oracle cannot provide a valid price.

### `ChainlinkOracleAdapter`, `PythOracleAdapter`, `DexTwapOracleAdapter`

Single-source fetchers. Deliberately dumb.

Responsibilities:

- Fetch one source, using the feed identifier passed in from the series' immutable config.
- Normalize the price to `PRICE_SCALE` regardless of source decimals.
- Report the source's `updatedAt` and whether the data is structurally usable.

Security requirements:

- An adapter must not hold its own `(base, quote) -> feed` mapping. That would be a second, governable source of truth, and repointing it would change the settlement oracle of an already-live series.
- An adapter must not apply staleness, deviation, or quorum policy. Policy in one place can be audited once; policy spread across three adapters can drift.
- Pair identity is bound at series creation through the approved oracle config, not re-checked at settlement. See [oracle-spec.md](./oracle-spec.md).

### `KuruMarketAdapter`

Optional helper around Kuru Router and market metadata.

Responsibilities:

- Compute or deploy the Kuru market for `optionToken / quoteAsset`.
- Store the resulting market address in the registry.
- Validate Kuru parameters such as size precision, price precision, tick size, minimum size, maximum size, maker fee, taker fee, and AMM spread.

Security requirements:

- The adapter must not custody option collateral.
- The adapter must not have permission to settle a series with Kuru market prices.
- The adapter must not receive unlimited approval to move vault collateral.

### `PremiumExecutionGuard`

Validation-only helper for simplified buy flows. It holds no funds and executes no trades.

V1 has no protocol-owned trade router, so nothing forces a buyer through this contract. Hard buyer price protection comes from Kuru's own limit-order parameters, enforced onchain by Kuru. This guard exists so the official frontend and any future router share one audited implementation of the acceptable-range and market-health rules. Its checks are advisory with respect to a user trading directly against Kuru, and user-facing copy must not imply otherwise.

See Invariant 13 in [math-of-core-invariants.md](./math-of-core-invariants.md) for the exact split between hard and advisory guarantees.

Responsibilities:

- Require buyer-provided limits: maximum total all-in cost, minimum option amount out, and deadline. Limits bind on totals, never on per-option figures.
- Check that the Kuru market is linked to the canonical series in the registry.
- Classify writer asks against an acceptable premium range before routing buyers into them.
- Reject automatic execution when spread, quote age, depth, price impact, or market status is outside configured safety bounds.
- Treat any reference premium as a safety guard only.

Security requirements:

- The guard must not define settlement value.
- The guard must not decide a fair premium on behalf of the buyer.
- The guard must not treat a writer ask as safe merely because the writer chose it.
- The guard must fail closed if market data is stale, unavailable, or inconsistent.
- The guard must not allow the collateral owner to set a buyer's maximum premium.

## Data Model

### Series Parameters

Every series has immutable parameters:

```text
seriesId
optionType            CALL or PUT
underlyingAsset       ERC-20
quoteAsset            ERC-20
collateralAsset       underlying for calls, quote for puts
strikePrice           PRICE_SCALE quote per 1 whole underlying
expiry                timestamp
oracleConfig          Chainlink feed, Pyth feed id, optional DEX TWAP, thresholds
contractSize          underlying raw units per whole option
optionTokenDecimals
optionScale           10 ** optionTokenDecimals
uqScale               underlying/quote decimal conversion constant
collateralPerOption   maximum liability of one whole option
feeConfig             mint, exercise, and residual fee rates, snapshotted at creation
settlementStyle       oracle-based European
```

The derived values and the fee snapshot are immutable for the life of the series. See [math-of-core-invariants.md](./math-of-core-invariants.md) for their definitions and [fee-spec.md](./fee-spec.md) for why fee rates are frozen per series.

### Mutable Series State

Mutable state is limited to lifecycle and accounting:

```text
state                 ACTIVE or SETTLED
totalShortAmount      total amount written by writers
totalUnclaimedShortAmount  short amount not yet claimed as residual
totalLongSupply       ERC-20 option token supply
collateralLocked      collateral backing outstanding claims
accruedFees           protocol fees, strictly segregated from collateral
settlementPrice       final oracle price, set once
buyerPayoutRate       collateral payout per whole option token
writerResidualRate    remaining collateral per whole option token
writerShortBalance    per-writer short obligation
```

The onchain enum holds only `ACTIVE` and `SETTLED`. Expiry is derived from `block.timestamp >= expiry` rather than written, and pauses are independent boolean flags rather than economic states — a paused series is still economically `ACTIVE`. The authoritative definition is [state-machine.md](./state-machine.md).

## Lifecycle

### 1. Created

The factory deploys and registers the series. No options exist yet.

### 2. Active

Writers can deposit collateral and mint option tokens. Tokens can be transferred or traded on Kuru. Settlement and redemption are not available.

### 3. Expired

The expiry timestamp has passed. New minting is disabled. Trading may still occur at the ERC-20 or Kuru level unless the market or frontend disables it, but buyers should understand that the option is awaiting settlement.

### 4. Settled

A keeper or user calls settlement. The vault reads the approved oracle price, calculates final payout and residual rates, and stores them permanently.

### 5. Redemption and Withdrawal

Long token holders burn option tokens to receive payout. Writers claim residual collateral based on their short balances. The series remains queryable in the registry.

## Settlement Flow

```text
User or keeper
    calls settle()
        OptionSeriesVault checks expiry
        OptionSeriesVault asks OracleRouter for valid price
        OracleRouter reads series oracle config from SeriesRegistry
        OracleRouter queries adapters and applies quorum policy
        OracleRouter returns settlement price
        OptionSeriesVault computes payout and residual rates
        OptionSeriesVault stores final settlement result
        OptionSeriesVault emits SeriesSettled
```

Settlement must not:

- Query Kuru best bid or best ask.
- Query Kuru trade events.
- Use Kuru AMM reserves.
- Depend on a Kuru market existing.
- Depend on Kuru market state being active.

## Kuru Trading Flow

```text
Writer mints option tokens
    transfers or deposits option tokens into Kuru flow
        Buyer buys option token on Kuru
            Buyer holds ERC-20 option token
                After settlement, Buyer redeems with OptionSeriesVault
```

Kuru sees an ERC-20 token. It does not need to know that the token is an option. The option vault sees the final token holder. It does not need to know how the holder acquired the token.

## Premium Formation and Buyer Protection

Premium is formed by trade execution, not by the option vault.

```text
Writer
    chooses whether to sell and at what ask price
        Kuru order book
            matches voluntary bids and asks
                Buyer
                    receives option tokens only if execution satisfies buyer limits
```

The writer can set an ask, but that ask is only an offer. It is not a protocol maximum premium and it is not a fair-value oracle. The buyer's submitted limit price is the maximum premium that the buyer consents to pay.

If a buy consumes multiple Kuru price levels, the realized premium is the weighted average of the actual fills:

```text
totalPremiumPaid = sum(fillOptionAmount_i * fillPrice_i)
realizedPremiumPerOption = totalPremiumPaid / totalOptionAmountReceived
```

Before an official helper routes a buyer into a writer ask, it should classify the ask:

```text
acceptable premium range =
    hard economic bounds from approved reference price
    intersected with market-health bounds from canonical Kuru depth
```

Hard bounds protect against obviously irrational asks even when the order book is manipulated. Market-health bounds protect against stale, spoofed, or thin-liquidity conditions. If the two layers disagree materially, or either layer cannot be computed safely, the route should fail closed.

For any one-click or routed buy flow:

```text
required inputs:
    option amount desired
    max total all-in cost, being premium plus venue fee
    minimum option amount out
    deadline
    recipient

safe-fail behavior:
    if route cannot satisfy buyer limits, revert
    if market is not canonical, revert
    if writer ask is outside acceptable premium range, revert or require manual limit-order UX
    if quote is stale or market safety checks fail, revert
```

Manipulated Kuru prices can make the displayed premium misleading, but they must not create a protocol loss. They also must not cause an automated buyer route to fill beyond the buyer's explicit limits or against an ask that fails the acceptable-range checks.

## Trust Boundaries

### Trusted or Permissioned Components

- Factory, for canonical deployment.
- Registry, for canonical discovery.
- Approved oracle adapters, for settlement prices.
- Emergency guardian, if included, only for narrowly scoped pause actions.

### Untrusted Components

- Buyers.
- Writers.
- Kuru traders.
- Kuru liquidity providers.
- Premium quotes and last-traded prices.
- Keepers.
- ERC-20 token contracts unless explicitly allowlisted.
- Frontends.
- Offchain indexers.
- Kuru market prices.

## Security Controls

### Collateral Isolation

Collateral stays inside the option vault. Kuru contracts may hold option tokens or quote tokens for trading, but they must not be able to withdraw option collateral.

### Oracle Isolation

Settlement uses only `OracleRouter`, reading the oracle configuration frozen into the series at creation. Option-token market prices are useful for trading, but not for determining payout.

### Premium Isolation

Premiums affect only the transfer of quote asset between buyer and seller during a trade. Premiums do not affect collateral locked, collateral released, settlement price, payout rate, or writer residual rate.

### Fee Isolation

Optara charges protocol fees at mint and exercise, but they are structurally prevented from touching collateral:

```text
mint fee       charged on top of required collateral, never deducted from it
exercise fee   carved out of an already-computed gross payout
accruedFees    a separate balance; sweeping it can never reach collateralLocked
```

Fee rates are snapshotted into each series at creation and are immutable for that series' life, so governance cannot change the economics of a position after a user has entered it. Compile-time caps bound what governance can set even for new series.

Kuru's own maker and taker fees are a separate system that Optara never receives. They must still appear in every premium bound and user-facing quote, because a buyer's real cost is the premium plus the venue fee. See [fee-spec.md](./fee-spec.md).

### Canonical Identity

Official series are identified by the factory and registry. Token name and symbol are display helpers, not security boundaries.

### Rounding Discipline

Minting rounds required collateral up. Settlement payouts round down. Minimum sizes prevent dust positions from becoming a rounding attack surface.

### Reentrancy Protection

State-changing entry points use reentrancy guards. Internal accounting is updated before external token transfers.

## Events

Minimum event set:

```text
SeriesCreated(seriesId, series, optionType, underlying, quote, strike, expiry)
KuruMarketLinked(seriesId, market, baseAsset, quoteAsset)
OptionsMinted(seriesId, writer, receiver, amount, collateralAmount, feeAmount)
PremiumRouteRejected(seriesId, market, reason)
SeriesSettled(seriesId, settlementPrice, buyerPayoutRate, writerResidualRate)
OptionsRedeemed(seriesId, holder, receiver, optionAmount, payoutAmount, feeAmount)
WriterResidualClaimed(seriesId, writer, receiver, shortAmount, residualAmount, feeAmount)
FeesSwept(seriesId, receiver, amount)
DustSwept(seriesId, receiver, amount)
PauseSet(seriesId, flag, paused, reason)
KuruLinkPauseSet(paused, reason)
RoutingPauseSet(paused, reason)
```

Every fee-bearing action emits the fee as a separate field rather than folding it into the net amount, so indexers and auditors can reconcile protocol revenue without re-deriving it.

## Upgradeability

Recommended V1 posture:

- Series vaults should be non-upgradeable once deployed.
- Factory, registry, and oracle adapter management can be governed, but changes must not alter already deployed immutable series.
- If upgradeability is used anywhere, it must be explicitly documented, timelocked, monitored, and excluded from changing settled outcomes.

## Implementation Risks

The most important architecture risks are:

- Accidentally allowing Kuru or another venue to influence settlement.
- Accidentally treating writer asks, last-traded prices, or manipulated premium quotes as fair value.
- Building a buy helper that does not require buyer-side max premium and deadline checks.
- Letting writers withdraw collateral before all long claims are protected.
- Using token metadata instead of registry identity.
- Mishandling decimals between underlying, quote, option token, and oracle price.
- Allowing tiny amounts that create zero collateral, zero payout, or favorable rounding loops.
- Adding convenience close flows before the basic lifecycle is fully proven.

See [math-of-core-invariants.md](./math-of-core-invariants.md) for the accounting rules and [design-decisions.md](./design-decisions.md) for the rationale behind these choices.
