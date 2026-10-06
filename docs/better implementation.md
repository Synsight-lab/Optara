# Better Implementation Plan

## Goal

Design a more capital-efficient Optara system that supports uncapped European options while still allowing Kuru and other secondary markets to trade the option claims.

This plan intentionally does **not** copy Derive's centralized matching model. Optara should be the margin, clearing, wrapping, settlement, and risk system. Kuru should remain an external venue for price discovery and trading.

The target design is:

```text
Optara = clearing, margin, wrappers, settlement, liquidation
Kuru   = external order book / secondary market / price discovery
```

The system should work without Kuru, but Kuru should be able to plug in cleanly as a first-class trading venue.

## Core Thesis

The present capped V2 is safe because every option has a finite maximum payout. Removing the cap means the protocol can no longer rely on exact worst-case collateral. Uncapped calls require a portfolio-margin system with live risk checks, maintenance margin, liquidation, and insurance.

The better architecture is therefore a new protocol version:

```text
Optara PM
```

where PM means portfolio margin.

Optara PM should not use a centralized matching engine as its main trading layer. Instead, it should issue externally tradable ERC-20 long option claims that venues like Kuru can list and trade.

## Monad Oracle Research

As of this plan, Monad has several oracle rails that can support the spot-price and signed-report parts of a portfolio-margin options system, but there is no obvious public, ready-made implied-volatility-surface feed that Optara can simply consume.

Monad's oracle documentation lists Chainlink, Chronicle, Pyth, RedStone, Stork, Supra, and Switchboard as supported or available oracle providers. It also lists Chainlink Data Streams, Pyth pull feeds, Stork pull feeds, Supra push/pull feeds, RedStone push/pull feeds, and Switchboard on Monad. Chainlink Data Streams are relevant because they provide signed offchain reports that can be verified onchain in the transaction that uses them. Switchboard is relevant because Monad's docs describe it as supporting custom feeds and any data type, which is closest to what a volatility-surface feed needs.

References to recheck before implementation:

- Monad oracle provider list: <https://monad.docsbot.app/tooling-and-infra/oracles>
- Chainlink Data Streams signed reports: <https://docs.chain.link/data-streams>
- Pyth price feeds for spot data: <https://docs.pyth.network/price-feeds>
- RedStone market-data rails: <https://docs.redstone.finance/docs/introduction>
- Block Scholes volatility oracle material: <https://www.blockscholes.com/use-cases/volatility-oracle-smart-contract-integration>

Therefore option (a) should be implemented as an Optara-specific signed volatility-surface oracle:

```text
spot price       -> Monad-supported spot oracle
vol surface      -> Optara-approved signed surface oracle
margin/pricing   -> deterministic onchain model using both inputs
settlement price -> separate expiry settlement oracle
```

Kuru prices may be an input to offchain analytics once markets are liquid enough, but Kuru must not be the sole source of the volatility surface. That would create circular margin: the venue being margined would define the margin requirement.

## What Changes From Current V2

Current Optara V2:

```text
capped option payoff
exact worst-case margin
writer mints ERC-20 long token
short liability stays internal
Kuru trades the ERC-20 long token
```

Better implementation:

```text
uncapped European option payoff
portfolio margin
signed internal risk balances
external ERC-20 wrapper tokens for long claims
Kuru trades wrapper tokens
Optara remains clearing source of truth
```

The important shift is that the ERC-20 token is no longer the whole position model. It is the external representation of a long claim. The source of truth for solvency is the Optara clearing account.

## No Centralized Matching

Optara PM should not require Derive-style internal matching for normal trading.

Do not make this the core user path:

```text
Alice signs order
Bob signs order
Optara matching module matches both orders
Optara transfers premium internally
Optara creates signed positions
```

Instead, make this the core user path:

```text
Writer deposits collateral into Optara
Writer opens short risk and mints external ERC-20 long claims
Writer sells those ERC-20 long claims on Kuru
Buyer buys on Kuru
Buyer can hold, transfer, unwrap, close, or redeem through Optara
```

This keeps trading permissionless and venue-friendly.

## Target Architecture

```text
                         OPTARA PM

        +-----------------------------------------+
        | SubAccounts                             |
        | signed internal balances                |
        +-------------------+---------------------+
                            |
                            v
        +-----------------------------------------+
        | Portfolio Risk Manager                  |
        | initial margin / maintenance margin     |
        | stress tests / account health           |
        +-------------------+---------------------+
                            |
                            v
        +-----------------------------------------+
        | Oracle Layer                            |
        | live spot / signed vol surface          |
        | expiry settlement oracle                |
        +-------------------+---------------------+
                            |
                            v
        +-----------------------------------------+
        | Option Clearing                         |
        | uncapped payoff / expiry / settlement   |
        +-------------------+---------------------+
                            |
                            v
        +-----------------------------------------+
        | External Option Wrapper                 |
        | ERC-20 long tokens for outside venues   |
        +-------------------+---------------------+
                            |
                            v
        +-----------------------------------------+
        | Venue Adapters                          |
        | Kuru first, other venues later          |
        +-------------------+---------------------+
                            |
                            v
        +-----------------------------------------+
        | KURU                                    |
        | base = external option wrapper          |
        | quote = series settlement stablecoin    |
        +-----------------------------------------+
```

## Upgradeability Model

Optara PM contracts should be upgradeable, not immutable.

Use a proxy-based architecture:

```text
SubAccounts              -> upgradeable proxy
PortfolioRiskManager     -> upgradeable proxy
VolSurfaceOracle         -> upgradeable proxy
OptionClearing           -> upgradeable proxy
ExternalOptionFactory    -> upgradeable proxy
FeeController            -> upgradeable proxy
VenueRegistry            -> upgradeable proxy
KuruAdapter              -> upgradeable proxy or replaceable adapter
LiquidationModule        -> upgradeable proxy
InsuranceFund            -> upgradeable proxy
SettlementWindow         -> upgradeable proxy
```

The wrapper ERC-20 tokens may be minimal proxies created by an upgradeable factory, but their external behavior must stay stable:

```text
no transfer tax
no rebasing
no arbitrary balance mutation
only Optara clearing can mint or burn
```

Upgradeability must not mean governance can rewrite live economic terms. The contracts are upgradeable, but these series terms must be storage-protected and non-rewritable once created:

```text
underlying
settlementAsset
optionType
strike
contractSize
expiry
settlement oracle rule
volSurfaceProductId
wrapper token
```

Governance may upgrade implementation logic and future risk parameters, but upgrades must be timelocked and auditable. Emergency upgrades may exist only behind a stricter emergency process and should default the affected product to close-only until the new implementation is reviewed.

Minimum upgrade controls:

- timelocked governance upgrades;
- separate guardian pause/close-only powers;
- storage-layout tests before every upgrade;
- implementation allowlist;
- upgrade events with implementation address and code hash;
- migration scripts for any changed storage;
- no upgrade that changes finalized settlement prices or already-accrued redemption ratios.

## Venue-Agnostic Execution

Kuru should be the first external venue adapter, but it must not be a protocol dependency.

The core execution abstraction should be:

```text
VenueRegistry
VenueAdapter
VenueRouter
```

Initial deployment:

```text
KuruAdapter enabled
InhouseMatchingAdapter disabled / future
UniswapAdapter disabled / future
OTCTransfer path always possible
```

The system must work in these modes:

```text
1. Kuru enabled:
   users trade wrappers through official Kuru routes.

2. Kuru disabled or unavailable:
   users can still mint wrappers, transfer OTC, unwrap, close, settle, and redeem.

3. Future inhouse matching:
   Optara can add an InhouseMatchingAdapter that uses the same wrapper tokens,
   protocol fees, risk checks, and settlement rules.
```

The invariant is:

```text
venues trade external long claims;
Optara clears the obligation.
```

## Internal And External Position Model

Optara PM should maintain signed internal balances:

```text
+1 option = internal long
-1 option = internal short
```

Kuru cannot trade signed internal balances directly. Kuru trades ERC-20 tokens. Therefore Optara needs an external wrapper token for each option series.

For each option series:

```text
internal signed positions + external wrapper supply = 0
```

More explicitly:

```text
sumInternalSignedBalances(series) + wrapperSupply(series) = 0
```

This invariant is the bridge between clearing and secondary markets.

## How External Inventory Is Created

Writers create Kuru-tradable inventory by opening short risk inside Optara, paying the seller protocol fee, and minting external long wrapper tokens.

```text
Writer deposits collateral
Writer calls mintExternalLong(series, quantity, recipient, maxSellerFeeNative)
Optara adds -quantity internal option position to writer
Optara runs initial margin check
Optara debits seller protocol fee
Optara mints +quantity ERC-20 wrapper tokens to recipient
```

Result:

```text
writer internal position = -quantity
external wrapper supply  = +quantity
net system position      = 0
```

This is the main replacement for a centralized matching engine.

The writer now owns ERC-20 long option tokens and can sell them on Kuru.

## Uncapped Option Payoff

The new system should support standard uncapped European options:

```text
CALL = max(S - K, 0)
PUT  = max(K - S, 0)
```

Puts are naturally bounded by strike when the underlying price cannot go below zero. Calls are not bounded.

Because calls are uncapped, Optara PM must use stress-based margin and liquidation rather than exact maximum-loss margin.

## Portfolio Margin

The risk manager should evaluate the whole account.

Recognized risk offsets may include:

- short call plus long higher-strike call;
- short put plus long lower-strike put;
- cash collateral;
- premium proceeds after they are deposited into Optara;
- internal long options;
- external wrapper tokens only after they are deposited or burned into Optara.

V1 should not recognize spot or perp offsets. Those offsets require spot/perp asset modules, mark prices, funding rules, liquidation handling, and collateral haircuts that are outside the first build. Add them only after the option-only PM system is stable.

Kuru-held assets do not receive margin credit.

```text
Kuru option balance != Optara margin hedge
Kuru stablecoin balance != Optara margin collateral
```

This is critical. The user may own assets on Kuru, but Optara cannot count them until those assets move into Optara custody or are consumed by an Optara transaction.

## Risk Manager

Optara PM should use two thresholds:

```text
Initial margin:
required to open risk, mint external longs, withdraw collateral, or wrap internal longs

Maintenance margin:
minimum required account health before liquidation is allowed
```

Account states:

```text
Healthy:
equity >= initialMargin

Close-only:
equity < initialMargin and equity >= maintenanceMargin

Liquidatable:
equity < maintenanceMargin

Insolvent:
equity < 0 after liquidation and insurance actions
```

### V1 Pricing And Margin Inputs

V1 should use option (a): a signed volatility-surface oracle.

The margin engine should price every open option from:

```text
live spot price
signed implied-volatility surface
time to expiry
strike
option type
contract size
```

The live spot oracle is for pre-expiry margin and liquidation health. The signed volatility surface is for option marking and scenario valuation. The expiry settlement oracle remains separate.

```text
live spot oracle      != expiry settlement oracle
vol surface oracle    != expiry settlement oracle
Kuru option price     != margin oracle
Kuru option price     != settlement oracle
```

### Signed Volatility-Surface Oracle

Optara should deploy its own `VolSurfaceOracle` because the current Monad oracle ecosystem provides price-feed and signed-report rails, but not a ready-made public implied-volatility surface for Optara option series.

The oracle should support two verification modes:

```text
1. native provider verifier, when available
   example: Chainlink Data Streams verifier or another Monad-supported verifier

2. Optara EIP-712 quorum fallback
   threshold signatures from approved surface publishers
```

The report must be bound to the chain and protocol:

```text
chainId
verifyingContract
surfaceOracle
productId
underlying
settlementAsset
surfaceSeq
validAfter
expiresAt
spotReferenceId
surfaceRoot
atmTotalVarianceByTenor[]
tenorTimestamps[]
surfaceMinIvBps
surfaceMaxIvBps
confidenceBps
riskParameterSetId
```

Replay protection:

```text
surfaceSeq must increase per product
expiresAt must be in the future
chainId and verifyingContract must match
old reports cannot overwrite newer reports
```

### Surface Format

Do not store an arbitrary unbounded surface onchain.

Use a compact grid of total variance:

```text
expiryTenor
logMoneynessBucket
totalVariance
```

where:

```text
totalVariance = impliedVol^2 * timeToExpiry
logMoneyness = ln(strike / forward)
```

The surface publisher signs a Merkle root of the grid. Risk checks pass only the grid points needed for the account's positions, with Merkle proofs.

The report also includes a small signed header that is stored onchain:

```text
atmTotalVarianceByTenor[up to 4]
tenorTimestamps[up to 4]
surfaceMinIvBps
surfaceMaxIvBps
confidenceBps
```

This header lets Optara run cheap cross-update and calendar sanity checks without storing the whole surface.

For a listed series, Optara derives the series volatility by interpolation:

```text
1. locate surrounding tenors;
2. locate surrounding log-moneyness buckets;
3. bilinear interpolate total variance;
4. convert interpolated total variance into implied volatility;
5. apply protocol vol floors, ceilings, and stale multipliers.
```

V1 should cap grid use:

```text
maxTenorsPerCheck = 4
maxMoneynessNodesPerCheck = 4
maxScenarioCount = 24
maxPositionsPerRiskBucket = governance cap
```

This is much more expensive than the rejected intrinsic-only approach, so gas benchmarking is mandatory before launch.

### Surface Sources

Surface publishers should compute the surface offchain from multiple inputs:

- centralized option venues where available;
- market-maker signed quotes;
- Kuru option markets only after they are liquid enough;
- realized volatility and forward curves as sanity inputs;
- stale-market widening rules.

The signed surface must include confidence metadata:

```text
confidenceBps
sourceCount
liquidityScore
maxBidAskWidthBps
lastCalibrationTime
```

The protocol should block new risk when confidence is too poor.

### Surface Publishers And Liveness

The volatility surface is a trusted input. That must be explicit.

For BTC and ETH, Optara should prefer an independent specialist volatility provider where available. Block Scholes is a relevant example because its public materials describe EIP-712 signed implied-volatility surface data for smart-contract integration. Chainlink Data Streams are useful signed-report infrastructure, but they should not be described as an implied-volatility provider unless Chainlink explicitly offers the needed IV surface feed for the exact product.

For MON, there may be no deep listed options market at launch. A MON volatility surface will initially be synthetic:

```text
realized volatility
spot volatility
market-maker quotes
related-asset proxy volatility
publisher judgment
wide confidence bands
```

That is economically closer to a signed risk-parameter oracle than a mature market-derived surface. The protocol should treat early MON surfaces conservatively:

- higher minimum IV floors;
- wider confidence penalties;
- lower open-interest caps;
- shorter surface expiry;
- close-only mode when publisher liveness degrades;
- clear frontend disclosure that MON IV is synthetic until liquid options markets exist.

Publisher operations:

```text
publisher keys are held by independent operators or an approved oracle provider
minimum quorum is required for Optara EIP-712 fallback
publisher uptime is a protocol liveness dependency
fresh reports are required for risk-increasing actions
publisher failures put affected products into close-only mode
```

Conflicted publishers, such as market makers who also trade the options, should not form a majority quorum by themselves. If market-maker quotes are used, they should be inputs to the publisher model, not unilateral onchain truth.

### Surface Sanity Rules

Before accepting a surface report, Optara should enforce cheap onchain sanity checks:

```text
minIvBps <= iv <= maxIvBps
signed ATM total variance is nondecreasing with tenor
per-update ATM IV movement <= maxIvMoveBps unless emergency mode is active
surface timestamp is fresh
confidenceBps <= maxConfidenceBps
publisher quorum is valid
```

Full no-arbitrage checks happen offchain before signing. Onchain checks are lightweight guards, not a complete quantitative validation engine.

### Option Pricing Model

Use a deterministic onchain Black-style pricing model.

For v1:

```text
model = Black-Scholes / Black-76 style European option valuation
rates = governance-set or oracle-signed risk-free rate, initially 0
forwards = derived from live spot unless a signed forward curve is approved
dividends/funding = 0 in v1 unless explicitly supported later
```

The pricing library must be fixed-point and deterministic:

```text
OptionPricer.value(optionType, spot, strike, timeToExpiry, impliedVol)
```

The implementation should use audited math libraries for:

```text
ln
sqrt
exp
normal CDF approximation
```

If gas is too high, v1 may use a signed model-price table derived from the signed surface, but the table must still be tied to the same `surfaceRoot` and risk parameter set.

### Equity And Margin Formula

Account equity:

```text
equity =
    settlementStablecoinCollateral
  + sum(markValue(internalLongOptions))
  - sum(markValue(internalShortOptions))
  - accruedFees
  - penalties
```

Initial margin:

```text
initialMargin =
    maxScenarioLoss(account, initialStressSet)
  + liquidationBuffer
```

Maintenance margin:

```text
maintenanceMargin =
    maxScenarioLoss(account, maintenanceStressSet)
```

Scenario loss:

```text
scenarioLoss =
    equityNow - equityUnderScenario
```

where each scenario shifts:

```text
spot
implied volatility
time to expiry
```

Recommended v1 stress set:

```text
spot shocks:
-50%, -30%, -15%, 0%, +15%, +30%, +50%, +100%

vol shocks:
-30%, 0%, +30%, +75%

time shocks:
now, near-expiry floor
```

The full Cartesian grid would be 64 scenarios. That is likely too expensive onchain for every account action. V1 should use a curated subset of 16-24 scenarios and benchmark before launch.

### Oracle Staleness

If the live spot oracle or volatility surface is stale:

- block risk-increasing actions;
- block collateral withdrawal;
- block wrapping out internal longs that provide margin credit;
- allow deposits;
- allow unwraps that improve margin;
- allow same-series closes;
- allow liquidation only if a fresh report is supplied in the same transaction or a configured stale-vol penalty is applied.

Recommended stale-vol treatment must be position-direction aware:

```text
stalePenalty = staleIvPenaltyBpsPerHour * hoursStale

shortLegEffectiveIv = min(maxIvBps, lastIv + stalePenalty)
longLegEffectiveIv  = max(minIvBps, lastIv - stalePenalty)
```

For equity, stale longs should either receive reduced time value or zero time value once the surface is stale beyond a stricter threshold:

```text
if surfaceAge > maxLongTimeValueStale:
    long value = intrinsic value only
```

This prevents a stale volatility surface from inflating account equity through long-option marks while still conservatively valuing short-option liabilities.

If the surface is stale beyond `maxSurfaceStale`, enter close-only mode for the affected product until a fresh accepted surface arrives.

## Protocol Fees And External Venue Fees

Optara PM should ship with protocol-fee code from day one. Fee rates may launch low, but the fee paths and `maxFee` protection must exist in the first upgradeable implementation.

There are three different fee domains:

```text
Optara seller/open fee
Optara buyer/acquisition fee
External venue fee, such as Kuru trading fees
```

These must never be merged in accounting.

### Seller Protocol Fee

The seller pays an Optara protocol fee when creating new external long supply:

```text
mintExternalLong(subAccount, seriesId, quantity, recipient, maxSellerFeeNative)
```

Fee basis:

```text
sellerFeeBase = modelMark(seriesId, quantity, currentSpot, currentSurface)
sellerFee = ceil(sellerFeeBase * sellerOpenFeeBps / 10_000)
```

The fee is denominated in the series settlement asset. It is debited from the seller's Optara cash balance after the new-risk margin check is simulated.

Required ordering:

```text
1. verify fresh spot and volatility-surface reports;
2. simulate the new short and wrapper mint;
3. compute required initial margin;
4. compute seller fee;
5. require sellerFee <= maxSellerFeeNative;
6. require cashAfterFee >= requiredInitialMargin;
7. debit seller fee;
8. credit protocol-owned fee accounting;
9. commit short position and mint wrapper.
```

The fee must not consume collateral required for margin.

### Buyer Protocol Fee

The buyer pays an Optara protocol fee when buying through an official Optara route:

```text
buyThroughVenue(adapterId, seriesId, quantity, maxPremium, maxBuyerFeeNative, venueFeeLimit, deadline)
```

Fee basis:

```text
buyerFeeBase = executedPremium
buyerFee = ceil(executedPremium * buyerTradeFeeBps / 10_000)
```

For a future inhouse matching adapter, `executedPremium` is the matched trade price. For Kuru, `executedPremium` is the quote amount spent through the official Kuru route.

Buyer fee ordering:

```text
1. quote venue premium and venue fee;
2. compute Optara buyer fee;
3. require buyerFee <= maxBuyerFeeNative;
4. execute venue trade through adapter;
5. collect buyer fee into Optara fee accounting;
6. deliver wrapper token to buyer or unwrap destination.
```

Important limitation:

```text
Optara cannot charge a buyer fee on arbitrary ERC-20 transfers or direct Kuru trades
without making wrapper tokens nonstandard.
```

Therefore the buyer protocol fee applies to official Optara-mediated acquisition routes. The frontend should route users through `VenueRouter` by default. Direct external transfers remain possible for composability, but they are outside the official fee-enforced trade path.

### Kuru Fee

Kuru has its own trading fees. Those fees are external to Optara:

```text
Kuru maker/taker fee != Optara buyer fee
Kuru maker/taker fee != Optara seller fee
```

The Kuru adapter must preview both:

```text
Optara protocol fee
Kuru venue fee
```

and route with explicit limits:

```text
maxBuyerFeeNative
maxSellerFeeNative
maxVenueFeeNative
maxPremium
deadline
```

Kuru fee support should exist in the adapter because Kuru is the first planned venue, but the core system must continue to work if the Kuru adapter is disabled.

### Fee Accounting And Funding Split

All protocol fees are credited separately from user margin:

```text
protocolOwnedBalance[settlementAsset]
insuranceFundBalance[settlementAsset]
keeperRewardReserve[settlementAsset]
treasuryBalance[settlementAsset]
```

Recommended configurable split:

```text
insuranceFundShareBps = 6,000
treasuryShareBps      = 3,000
keeperReserveShareBps = 1,000
```

Fees are never counted as user collateral after debit. Fee withdrawal by treasury is allowed only from protocol-owned balances not reserved for insurance or keeper rewards.

### Insurance Seed Capital

Uncapped options must not launch with an empty insurance fund.

Before enabling new risk for a settlement asset:

```text
insuranceFundBalance[asset] >= minimumInsuranceSeed[asset]
keeperRewardReserve[asset] >= minimumKeeperReserve[asset]
```

Seed capital can come from governance deposits, grants, protocol-owned liquidity, or a bootstrap treasury transfer. Protocol fees and liquidation penalties then replenish the fund over time.

## Capital Efficiency Without Centralized Matching

Removing centralized matching creates one tradeoff:

```text
premium is not automatically inside Optara when the option is sold on Kuru
```

The flow is:

```text
writer mints external option
writer sells on Kuru
writer receives quote asset on Kuru or in wallet
writer deposits quote asset into Optara
only then does the premium improve Optara margin
```

This is less tightly integrated than Derive, but still more capital-efficient than current capped full-collateral Optara because:

- margin is model-value and scenario-stress based, not exact capped maximum-loss based;
- spreads can reduce margin;
- internal longs can reduce margin;
- implied time value is included through the signed volatility surface;
- deposited premiums become account equity;
- writers can reuse one account across multiple option series.

If Kuru supports a route that sells and returns quote assets in the same transaction, the adapter can offer:

```text
mint external long
deposit long into Kuru
sell on Kuru
deposit proceeds into Optara
```

But this must be an optional helper, not a solvency assumption.

## Complete System Flow

### 1. Market Setup

Governance or an authorized series creator creates a new uncapped option series:

```text
underlying
settlementAsset
optionType = CALL or PUT
strike
contractSize
expiry
oracleConfig
volSurfaceProductId
riskParameterSetId
```

There is no `capWad` in the new design.

Optara deploys or registers:

```text
seriesId
subId
external wrapper token
settlement configuration
risk parameters
volatility-surface product binding
```

### 2. Writer Deposits Collateral

The writer deposits the exact series settlement asset:

```text
depositCollateral(subAccount, settlementAsset, amount)
```

The collateral becomes part of the writer's Optara account equity.

V1 should allow one settlement stablecoin per subaccount risk bucket. Do not support generic collateral in the first version. Other collateral types require collateral oracles, haircuts, liquidation routing, and depeg handling.

### 3. Writer Mints External Long Inventory

The writer creates tradable long inventory:

```text
mintExternalLong(subAccount, seriesId, quantity, recipient, maxSellerFeeNative)
```

Optara does:

```text
verify fresh live spot report
verify fresh signed volatility-surface report
derive model values and scenario losses
compute seller protocol fee
require sellerFee <= maxSellerFeeNative
writer internal option balance -= quantity
wrapper token supply += quantity
initial margin check passes after fee debit
wrapper tokens minted to recipient
```

The writer now has Kuru-tradable ERC-20 option tokens.

### 4. Kuru Market Is Created Or Verified

The canonical Kuru market must be:

```text
base  = external wrapper option token
quote = series settlementAsset
```

The Kuru adapter or indexer verifies:

```text
market base token == wrapper token
market quote token == settlement asset
chain id is correct
market address is approved or verified
```

Wrong markets must not be shown as official markets.

### 5. Writer Lists On Kuru

The writer deposits wrapper tokens into Kuru and places asks.

```text
writer wallet -> Kuru wrapper token balance
writer places sell order
```

Optara state does not change during this step.

Important:

```text
Kuru-held wrapper tokens do not reduce writer risk.
Kuru sale proceeds do not improve Optara margin until deposited.
```

### 6. Buyer Buys On Kuru Through The Official Router

The buyer pays the settlement asset through the official Optara Kuru route and receives wrapper tokens.

```text
buyer pays premium
buyer pays Optara buyer protocol fee
buyer pays Kuru venue fee if charged by Kuru
buyer receives option wrapper token
```

The buyer now owns an externally composable long option claim.

The buyer can:

- hold it in wallet;
- transfer it;
- sell it back on Kuru;
- unwrap it into Optara;
- redeem it after redemption opens.

### 7. Buyer Unwraps Into Optara

If the buyer wants the position inside Optara, they call:

```text
unwrapLong(subAccount, seriesId, quantity)
```

Optara does:

```text
burn wrapper tokens from buyer
buyer internal option balance += quantity
```

The buyer now has an internal long position.

Internal long positions can:

- reduce margin against shorts;
- participate in portfolio margin;
- settle directly into cash at expiry.

### 8. Writer Deposits Premium Proceeds

After selling on Kuru, the writer can move the quote asset back into Optara:

```text
withdraw quote asset from Kuru
depositCollateral(subAccount, settlementAsset, amount)
```

Only after this deposit does the premium improve margin.

The frontend should make this very explicit:

```text
Premium on Kuru is external.
Deposit proceeds into Optara to improve margin health.
```

### 9. Writer Buys To Close Through Kuru

If the writer wants to close before expiry:

```text
writer buys same wrapper token on Kuru
writer receives wrapper token
writer calls closeShortWithWrapper(seriesId, quantity)
```

Optara does:

```text
burn wrapper tokens from writer
writer internal short balance += quantity
required margin decreases
```

For example:

```text
before:
writer internal option balance = -10
wrapper tokens in wallet       =  4

closeShortWithWrapper(4)

after:
writer internal option balance = -6
wrapper tokens burned          =  4
```

The Kuru fill alone does not close the short. Closing happens only when Optara burns the actual same-series wrapper token or consumes an internal same-series long.

### 10. Market Maker Spread Flow

A market maker can create capital-efficient spreads:

```text
short 4,000 call
long  4,500 call
```

Flow:

```text
mintExternalLong(4,000 call) -> sell on Kuru
buy 4,500 call on Kuru
unwrap 4,500 call into Optara
risk manager recognizes spread hedge
margin requirement falls
```

The hedge counts only after the long token is unwrapped into Optara.

### 11. Internal Long Wrap Flow

A user with an internal long may want to sell it externally:

```text
wrapLong(subAccount, seriesId, quantity, recipient)
```

Optara does:

```text
internal option balance -= quantity
post-wrap margin check passes
wrapper tokens minted to recipient
```

If that internal long was reducing margin, wrapping may fail unless the account has enough collateral after removing the hedge.

### 12. Settlement Flow

At expiry:

```text
configured settlement oracle produces the expiry price
Optara finalizes the series
payoff per option is fixed
redemptions remain closed
```

V1 should use the existing-style round-in-force settlement rule rather than claiming a generic TWAP. The oracle config must define the exact eligible provider observation before the series is created:

```text
expiry
minFinalizationDelay
maxFinalizationDelay
eligible round or timestamp rule
precommitted fallback source if any
staleness and validity checks
```

A future version may add a true TWAP oracle, but only if the averaging window, round selection, and proof rules are specified before launch.

For calls:

```text
payoff = max(S - K, 0) * contractSize
```

For puts:

```text
payoff = max(K - S, 0) * contractSize
```

Internal positions settle through subaccounts:

```text
internal long  -> cash credit
internal short -> cash debit
```

External wrapper holders do not redeem immediately after price finalization. Redemptions open only after the settlement window and recovery calculation are complete.

### 13. Settlement Window And Recovery Ratio

Leveraged shorts may be underwater at expiry. Therefore wrapper redemption must not be first-come-first-served.

The required flow is:

```text
1. finalize the settlement price;
2. snapshot the risk group's claim and debtor set;
3. open the settlement window;
4. permissionless keepers settle debtor accounts;
5. wait until unsettledDebtorCount[groupId] == 0;
6. use insurance to cover any remaining shortfall;
7. compute one uniform group recovery ratio;
8. open redemption only after the ratio is fixed.
```

During the settlement window:

```text
settleAccountGroup(subAccount, groupId)
```

does:

```text
net all of the account's internal longs and shorts across the group
convert the net amount into fixed cash claim or debt
collect net debt from the account's settlement-asset collateral
record any unpaid account deficit
decrement unsettledDebtorCount[groupId] when a debtor is settled
pay a small keeper reward from configured fees or insurance budget
```

The settlement window is permissionless and counter-based. It may have time-based reward escalation, but redemption must not open merely because time passed.

At finalization, Optara snapshots:

```text
totalLongQtyAtFinalization[groupId]
wrapperSupplyAtFinalization[groupId]
internalLongClaimsAtFinalization[groupId]
unsettledDebtorCount[groupId]
grossClaim[groupId]
```

Keep an O(1) unsettled debtor counter per group:

```text
unsettledDebtorCount[groupId] += 1
```

for each account whose net group settlement is a debt. Because the protocol cannot loop over all accounts in one transaction, this count must be maintained incrementally as accounts open/close risk or be snapshotted by a bounded indexed finalization process defined before launch.

Recommended state machine:

```text
ACTIVE
-> EXPIRED_UNFINALIZED
-> PRICE_FINALIZED_REDEMPTION_CLOSED
-> SETTLEMENT_WINDOW_OPEN
-> ALL_DEBTORS_SETTLED
-> RECOVERY_RATIO_SET
-> REDEMPTION_OPEN
```

After `unsettledDebtorCount[groupId] == 0`:

```text
grossClaim[groupId] =
    sum over series in group:
        payoffPerOption[seriesId] * totalLongQtyAtFinalization[seriesId]

availableForClaims[groupId] =
    collectedSettlementCash[groupId] + insuranceContribution[groupId]

recoveryRatio[groupId] =
    min(1, availableForClaims[groupId] / grossClaim[groupId])
```

The same group `recoveryRatio` applies to all long claimants, internal and external. If insurance fully covers the deficit, `recoveryRatio = 1`.

Internal long cash claims become withdrawable only after the same recovery ratio is fixed. Wrapper holders redeem through `redeemWrapper`; internal claimants withdraw or sync cash through the account ledger. Both paths use the same ratio.

After `REDEMPTION_OPEN`, wrapper holders can redeem:

```text
redeemWrapper(seriesId, quantity, recipient)
burn wrapper tokens
receive floor(quantity * payoffPerOption[seriesId] * recoveryRatio[groupId])
```

This avoids early redeemers being paid in full while later redeemers receive nothing.

### 14. Settlement With Wrapper Supply

Before price finalization, Optara maintains the active-position invariant:

```text
sumInternalSignedBalances + wrapperSupply = 0
```

After price finalization, that active-position invariant no longer applies because internal option balances are progressively converted into fixed cash claims and debts while wrapper tokens remain outstanding until redeemed.

After the recovery ratio is set, the redemption invariant becomes:

```text
redemptionReserve[groupId] >=
    sum over series in group:
        remainingWrapperSupply[seriesId]
      * payoffPerWrapper[seriesId]
      * recoveryRatio[groupId]
```

If `recoveryRatio[groupId] = 1`, wrapper holders receive full payoff. If `recoveryRatio[groupId] < 1`, every wrapper holder in the group receives the same pro-rata payout regardless of redemption order.

### 15. Oracle Failure And Stalled Settlement

If no valid settlement price arrives by `expiry + maxFinalizationDelay`, the series enters:

```text
ORACLE_STALLED
```

In this state:

- no redemption is allowed;
- no invented current spot price may be substituted;
- no new risk may be opened;
- safe risk-reducing close/cancel paths may remain available;
- collateral withdrawals must reserve the unsettled obligation;
- a late authentic historical observation can still finalize the series;
- if all precommitted sources permanently fail, unmatched claims may remain unresolved until governance-defined recovery rules handle the incident.

This mirrors the existing protocol principle: oracle failure delays settlement; it does not erase debt or create an ad hoc settlement price.

### 16. No Kuru Path

The system must still work if Kuru is unavailable.

Valid non-Kuru path:

```text
deposit collateral
mint external long to wallet
transfer wrapper token directly OTC
buyer holds wrapper token
finalize expiry
settlement window completes
recovery ratio is fixed
buyer redeems wrapper token
writer settles internal short
```

Kuru improves liquidity and price discovery. It must not be required for settlement correctness.

## Kuru Integration Flow

### Kuru Market Convention

Every official Kuru market must use:

```text
base  = Optara external option wrapper
quote = exact series settlementAsset
```

Examples:

```text
MON 4 USDT call wrapper / USDT
ETH 4000 USDC call wrapper / USDC
BTC 90000 USDe put wrapper / USDe
```

### Kuru Adapter Responsibilities

The Kuru adapter should:

- discover candidate Kuru markets;
- verify base and quote tokens;
- preview Kuru venue fees;
- preview Optara buyer fees for official routes;
- reject wrong settlement assets;
- reject wrong wrapper tokens;
- expose buy and sell helpers;
- expose buy-to-close helpers;
- expose premium-proceeds deposit guidance;
- never report a Kuru fill as an Optara close;
- never report Kuru balances as Optara collateral.

### Kuru Sell Flow

```text
writer opens short, pays Optara seller fee, and mints wrapper
writer approves Kuru
writer deposits wrapper into Kuru
writer places sell order
buyer fills order
writer receives quote asset on Kuru net of Kuru venue fees if charged
writer optionally withdraws quote
writer deposits quote into Optara
```

### Kuru Buy Flow

```text
buyer routes through Optara VenueRouter
adapter quotes Kuru premium and Kuru fee
Optara computes buyer protocol fee
buyer accepts maxPremium, maxBuyerFeeNative and maxVenueFeeNative
buyer buys wrapper option on Kuru through adapter
buyer withdraws wrapper to wallet
buyer may hold, transfer, unwrap, or redeem after redemption opens
```

### Kuru Buy-To-Close Flow

```text
writer is short internally
writer buys same wrapper option on Kuru
writer withdraws wrapper token
writer calls closeShortWithWrapper
Optara burns wrapper token
Optara reduces internal short
Optara recomputes margin
```

### Kuru Hedge Flow

```text
trader buys wrapper token on Kuru
trader withdraws wrapper token
trader unwraps into Optara
internal long now receives margin credit
```

### Kuru Settlement Flow

If wrapper tokens remain on Kuru at expiry, Kuru itself does not settle them. The holder or Kuru-side custody workflow must wait until Optara opens redemption, then withdraw/redeem:

```text
holder withdraws wrapper token from Kuru
holder calls redeemWrapper
Optara burns wrapper token
Optara pays settlementAsset payoff times recoveryRatio
```

If Kuru supports custody redemption later, that can be an adapter feature, but the authoritative redemption remains in Optara.

## Liquidation Without Centralized Matching

Uncapped options require liquidation. But liquidation does not require a normal centralized matching engine.

Liquidation should be permissionless:

```text
any liquidator can call liquidate(account, action)
```

The main liquidation path should be a portfolio-slice transfer, not forced buying of wrapper tokens.

### Primary Mechanism: Dutch Portfolio-Slice Auction

When an account is below maintenance margin, anyone may start or execute a liquidation auction for a risk bucket.

Auction object:

```text
account
settlementAsset
riskBucket
startTime
expiryTime
startBonusBps
maxBonusBps
minSliceBps
maxSliceBps
targetHealthBufferBps
```

Recommended v1 defaults:

```text
startBonusBps = 0
maxBonusBps = 1,000        // 10%
auctionDuration = 30 minutes
minSliceBps = 500          // 5%
maxSliceBps = 2,500        // 25%
targetHealthBufferBps = 500
```

These are risk parameters, not constants. They should be set per settlement asset or risk bucket.

The auction bonus increases over time:

```text
bonusBps =
    min(startBonusBps + elapsed * bonusSlopeBpsPerSecond, maxBonusBps)
```

The liquidator chooses a slice size within protocol bounds:

```text
sliceBps in [minSliceBps, maxSliceBps]
```

Optara transfers that pro-rata slice of the account's positions in the risk bucket to the liquidator:

```text
short options
internal long options
```

The liquidator funds the margin for the transferred slice with the liquidator's own account equity. The liquidated account must not pay the liquidator's initial margin requirement.

The cash exchanged is based on the slice's current mark value, adjusted by the Dutch-auction discount:

```text
sliceMark = markValue(slicePositions)
discount = abs(sliceMark) * bonusBps / 10_000
```

If the slice is a net liability for the liquidated account:

```text
sliceMark < 0
cashToLiquidator = min(availableCollateral, -sliceMark + discount)
cashFromLiquidator = 0
```

If the slice is a net asset for the liquidated account:

```text
sliceMark > 0
cashFromLiquidator = max(0, sliceMark - discount)
cashToLiquidator = 0
```

With zero discount, transferring a slice at mark value leaves account equity approximately unchanged while reducing maintenance requirement. The health ratio improves whenever the maintenance requirement removed is larger than the discount paid.

If the liquidated account cannot pay the marked liability transfer, the cash paid is capped at available collateral and the unpaid deficit is routed to insurance or bad-debt accounting.

The transaction must satisfy:

```text
liquidator equity after position and cash transfer >= liquidator initial margin
liquidated account health improves
liquidated account is restored above maintenance, or max allowed slice was used
```

This makes the liquidator take over real risk using its own capital, not drain the failing account by receiving the slice's margin requirement.

### Partial Liquidation Size

V1 should avoid arbitrary full-account seizure.

Recommended rule:

```text
liquidate the smaller of:
1. the slice required to restore the account above initial margin plus buffer;
2. maxSliceBps of the risk bucket;
3. the remaining open position size.
```

If a partial liquidation cannot restore the account and the auction reaches `maxBonusBps`, the account can move into whole-bucket auction or insurance/backstop handling.

### Wrapper Burn Close

Burning wrapper tokens can also reduce risk:

```text
liquidator supplies same-series wrapper tokens
Optara burns them
Optara reduces the liquidated account's short
liquidator receives the model value of the burned liability plus the auction discount
```

This path is useful when Kuru liquidity exists, but it cannot be the only liquidation path because wrapper liquidity may be thin.

### Expiry And Finalization Boundary

Before expiry:

```text
use maintenance margin and Dutch portfolio-slice liquidation
```

After expiry but before price finalization:

```text
block new risk
allow deposits
allow risk-reducing close/cancel where exact same-series wrappers or internal longs are provided
continue reserving stressed margin until settlement price exists
```

After price finalization:

```text
stop auctioning option market risk
settle accounts into fixed cash debts or claims
use collateral seizure, insurance, and the recovery-ratio process for unpaid debts
```

Kuru can help liquidators source wrapper tokens or sell hedges, but liquidation must not depend on Kuru.

```text
Kuru liquidity available    -> liquidator may use it
Kuru liquidity unavailable  -> protocol liquidation still works
```

## Insurance And Bad Debt

Because uncapped calls can gap beyond modeled scenarios, the system needs an insurance layer.

Required components:

- insurance fund;
- liquidation penalties routed partly to insurance;
- protocol fees routed partly to insurance;
- bad-debt accounting;
- emergency close-only mode;
- governance-defined recovery rules.

At settlement, insurance is applied before any haircut:

```text
shortfall[groupId] =
    grossClaim[groupId] - collectedSettlementCash[groupId]

insuranceContribution[groupId] =
    min(shortfall[groupId], availableInsurance[settlementAsset])

remainingShortfall[groupId] =
    shortfall[groupId] - insuranceContribution[groupId]

recoveryRatio[groupId] =
    grossClaim[groupId] == 0
        ? 1
        : (grossClaim[groupId] - remainingShortfall[groupId]) / grossClaim[groupId]
```

No wrapper redemption or internal long payout should occur before this ratio is fixed.

Insurance funding sources:

- mandatory seed capital before enabling new risk;
- seller protocol fees;
- buyer protocol fees;
- liquidation penalties and auction discounts;
- governance recapitalization deposits.

Keeper rewards should come from `keeperRewardReserve[asset]`. If that reserve is empty, keeper rewards can be reduced to zero, but redemption must still wait for every debtor account in the group to be settled.

The current capped V2 does not need this for ordinary market movement. Optara PM does.

## Required Contract Modules

### `SubAccounts`

Tracks:

- account ownership;
- operators;
- signed internal option balances;
- cash balances;
- settlement-stablecoin collateral balances;
- account health.

### `OptionSeriesRegistry`

Tracks:

- underlying;
- settlement asset;
- option type;
- strike;
- contract size;
- expiry;
- oracle config;
- wrapper token address;
- risk parameters.
- vol surface product id;
- risk parameter set id;

### `PortfolioRiskManager`

Handles:

- equity calculation;
- initial margin;
- maintenance margin;
- model-value scenario stress;
- signed volatility-surface inputs;
- surface confidence and staleness checks;
- withdrawal checks;
- wrap checks;
- mint-external-long checks;
- liquidation eligibility.

It must require a fresh accepted spot report and volatility-surface report for risk-increasing actions.

### `LiveSpotOracle`

Handles:

- current underlying/settlement-asset spot;
- staleness checks;
- risk-action blocking when stale;
- no use of Kuru option prices.

This oracle is for margin and liquidation only.

### `VolSurfaceOracle`

Handles:

- signed volatility-surface reports;
- provider-verifier integration when available;
- EIP-712 quorum fallback;
- `surfaceSeq` replay protection;
- Merkle-root storage;
- per-product freshness checks;
- surface confidence checks;
- IV floor, ceiling, and per-update movement guards.

This oracle is for pre-expiry option marking, portfolio margin, and liquidation only. It is not the expiry settlement oracle.

### `SettlementOracle`

Handles:

- immutable expiry price-selection rule;
- provider round validation;
- min and max finalization delay;
- precommitted fallback source;
- `ORACLE_STALLED` state.

This oracle is for expiry settlement only.

### `ExternalOptionWrapper`

ERC-20 token representing an external long claim.

Properties:

- one wrapper per option series;
- mintable only by Optara clearing;
- burnable for unwrap, close, or redemption;
- no transfer tax;
- no hooks;
- no rebasing.

### `OptionClearing`

Handles:

- `mintExternalLong(..., maxSellerFeeNative)`;
- `wrapLong`;
- `unwrapLong`;
- `closeShortWithWrapper`;
- `closeShortWithInternalLong`;
- expiry finalization;
- internal settlement;
- wrapper redemption.

### `FeeController`

Handles:

- seller open-fee calculation;
- buyer acquisition-fee calculation;
- `maxSellerFeeNative` checks;
- `maxBuyerFeeNative` checks;
- protocol fee accounting;
- fee split between insurance, keeper reserve, and treasury;
- protocol-owned fee withdrawal limits.

Fees must be denominated in the exact settlement asset of the series.

### `SettlementWindow`

Handles:

- permissionless account settlement after price finalization;
- `unsettledDebtorCount[groupId]`;
- keeper rewards;
- shortfall accounting;
- insurance top-up;
- recovery-ratio calculation;
- redemption opening.

### `InsuranceFund`

Handles:

- insurance deposits;
- protocol-fee receipts;
- liquidation-penalty receipts;
- settlement shortfall contributions;
- bad-debt accounting.

### `VenueRegistry`

Tracks verified external markets:

```text
venue
market
seriesId
base
quote
chainId
status
metadata
```

This replaces Kuru-specific hardcoding and allows Uniswap or another venue later.

### `VenueRouter`

Handles:

- official Optara-mediated buy/sell routes;
- buyer protocol fee collection;
- venue-fee limits;
- premium slippage limits;
- deadline checks;
- adapter dispatch.

The router can work with Kuru now and an inhouse matching adapter later.

### `KuruAdapter`

Handles Kuru-specific:

- market verification;
- Kuru fee preview;
- order helper data;
- deposit and withdrawal helper data;
- buy and sell helper data;
- buy-to-close helper data;
- UI/indexer metadata.

It must not be required by core clearing.

### `InhouseMatchingAdapter`

Future optional adapter.

Handles:

- signed maker/taker orders;
- buyer and seller fee hooks;
- premium transfer;
- wrapper delivery;
- cancellation and nonce checks.

It must reuse the same `VenueRouter`, `FeeController`, wrapper tokens, and Optara risk checks. Adding this adapter must not require replacing Kuru or changing core settlement.

### `LiquidationModule`

Handles:

- account liquidation eligibility;
- Dutch portfolio-slice auction;
- liquidation bonus calculation;
- risk-reducing position transfer;
- collateral transfer with post-state margin checks;
- wrapper-burn close path;
- bad-debt routing;
- insurance fund claims.

### `UpgradeAdmin`

Handles:

- timelocked upgrades;
- implementation allowlists;
- emergency close-only upgrade flow;
- upgrade event emission;
- storage-layout migration coordination.

## Frontend Flow

The frontend should be built around both portfolio health and external liquidity.

Main pages:

- Portfolio;
- Markets;
- Series;
- Kuru;
- Liquidations;
- Settlement.

Series page should show:

- strike;
- expiry;
- uncapped payoff;
- wrapper token address;
- official Kuru market;
- bid/ask if available;
- open interest;
- wrapper supply;
- internal net position;
- latest IV / model mark;
- volatility-surface status;
- Optara seller fee preview;
- Optara buyer fee preview;
- Kuru venue fee preview when Kuru is selected;
- mint external long action;
- buy on Kuru action;
- sell on Kuru action;
- unwrap action;
- close short action;
- settlement-window status;
- recovery ratio;
- redeem action after redemption opens.

Portfolio page should show:

- equity;
- initial margin;
- maintenance margin;
- liquidation buffer;
- internal options;
- external wrappers held in wallet;
- Kuru balances if available, clearly marked external;
- deposited collateral;
- protocol fees paid;
- fee-adjusted free collateral;
- live spot oracle status;
- volatility-surface oracle status;
- oracle-stalled positions;
- required actions.

## Indexer Flow

The indexer should track:

- series;
- wrapper token addresses;
- wrapper supply;
- internal signed positions;
- account equity;
- initial margin;
- maintenance margin;
- accepted volatility-surface reports;
- surface sequence numbers;
- surface confidence and staleness;
- surface roots used for risk actions;
- verified Kuru markets;
- protocol fee accruals;
- insurance and keeper reserve balances;
- Kuru balances when available;
- Kuru trades when available;
- Optara close, unwrap, wrap, and redeem events;
- settlement window progress;
- unsettled accounts;
- gross claims;
- collected settlement cash;
- insurance contribution;
- recovery ratio;
- liquidation state;
- insurance fund state.

The indexer can display Kuru information, but it must never convert Kuru balances into Optara margin.

## Testing Plan

### Accounting Invariants

Before price finalization, test:

```text
sumInternalSignedBalances + wrapperSupply = 0
```

for these transitions:

- mint external long;
- wrap internal long;
- unwrap wrapper;
- close short with wrapper;
- close short with internal long.

After price finalization, test:

```text
redemptionReserve[groupId] >=
    sum over series:
        remainingWrapperSupply[seriesId]
      * payoffPerWrapper[seriesId]
      * recoveryRatio[groupId]
```

and:

```text
redemptions are blocked until recoveryRatio is fixed
redemptions are blocked while unsettledDebtorCount[groupId] > 0
all internal and external long claimants receive the same recoveryRatio
redemption burns wrapper supply
redemption order cannot change payout percentage
```

### Fee Tests

Test:

- seller open fee is charged on `mintExternalLong`;
- seller open fee respects `maxSellerFeeNative`;
- buyer fee is charged on official `VenueRouter` buy routes;
- buyer fee respects `maxBuyerFeeNative`;
- Kuru venue fee is previewed and limited separately from Optara fees;
- protocol fees do not count as user margin after debit;
- fee split credits insurance, keeper reserve and treasury accounting;
- new risk is blocked when insurance seed or keeper reserve is below minimum;
- direct ERC-20 transfer does not pretend to be an Optara fee-enforced buy.

### Kuru Flow Tests

Test:

- verified Kuru market uses wrapper as base;
- verified Kuru market uses settlement asset as quote;
- wrong base is rejected;
- wrong quote is rejected;
- writer can mint wrapper and sell on Kuru;
- buyer can buy wrapper and redeem after redemption opens;
- buyer can unwrap into Optara before settlement;
- writer can buy wrapper on Kuru and close short;
- Kuru-held wrapper does not reduce margin;
- Kuru stablecoin balance does not improve margin;
- deposited Kuru proceeds do improve margin;
- Kuru fee does not change Optara accounting except through actual assets received;
- Optara buyer fee and Kuru venue fee are shown separately;
- Kuru outage does not block settlement-window account settlement;
- Kuru outage does not block direct redemption after redemption opens.

### Risk Tests

Test:

- naked uncapped short call requires stress margin;
- call spread requires less margin than naked short call;
- put spread requires less margin than naked short put;
- internal long hedge reduces margin;
- wrapped-out long stops reducing margin;
- Kuru-held long does not reduce margin;
- stale live spot blocks risk-increasing actions;
- stale volatility surface blocks risk-increasing actions;
- invalid surface signature is rejected;
- old `surfaceSeq` reports cannot replace newer reports;
- bad Merkle proofs are rejected;
- low-confidence surfaces enter close-only mode;
- scenario margin uses Black-style model values, not intrinsic-only values;
- v1 does not credit spot or perp offsets;
- account below maintenance can be liquidated;
- account above maintenance cannot be liquidated.

### Settlement Tests

Test:

- long call receives `max(S - K, 0)`;
- short call pays `max(S - K, 0)`;
- long put receives `max(K - S, 0)`;
- short put pays `max(K - S, 0)`;
- wrapper holder can redeem exact payoff when `recoveryRatio = 1`;
- wrapper holder receives pro-rata payoff when `recoveryRatio < 1`;
- internal long settles to cash;
- internal short settles to cash debit;
- redemption is blocked during the settlement window;
- redemption is blocked until every debtor account in the group is settled;
- account settlement nets longs and shorts across all series in the group;
- first redeemer cannot receive a better ratio than last redeemer;
- oracle-stalled series cannot be redeemed against invented prices.

### Liquidation Tests

Test:

- liquidation improves account health;
- liquidation cannot make the account worse except for explicit penalty;
- liquidator cannot seize healthy accounts;
- Dutch auction bonus is bounded;
- cash exchanged in liquidation is based on mark value, not margin requirement;
- liquidated account never pays the liquidator's initial margin requirement;
- portfolio-slice liquidation requires the liquidator to pass initial margin;
- wrapper-burn liquidation closes only same-series shorts;
- bad debt routes to insurance;
- liquidation works without Kuru liquidity.

### Upgrade Tests

Test:

- proxy upgrades preserve storage layout;
- upgrades cannot rewrite existing series economic terms;
- finalized prices and recovery ratios cannot be changed by upgrade;
- Kuru adapter can be disabled without breaking mint, unwrap, close, settlement or redemption;
- future inhouse matching adapter can be added through `VenueRegistry` without changing wrapper settlement.

## Implementation Phases

### Phase 1: Spec Freeze

- define uncapped series format;
- remove cap from new series identity;
- define wrapper invariant;
- define Kuru market convention;
- define volatility-surface report schema;
- define approved surface publisher set;
- define surface quorum and verifier rules;
- define surface sanity bounds;
- define Black-style pricing approximation;
- define model-value scenario stress set;
- define live spot oracle staleness rules;
- define settlement oracle round-in-force rules;
- define settlement-window and recovery-ratio rules;
- define Dutch liquidation rules;
- define seller and buyer protocol fee formulas;
- define Kuru venue-fee limits;
- define insurance rules;
- define proxy and upgrade governance rules.

### Phase 2: Clearing Core

- implement upgradeable proxy deployment;
- implement upgrade admin and timelock controls;
- implement subaccounts;
- implement collateral deposits;
- implement signed option balances;
- implement wrapper token factory;
- implement `mintExternalLong`;
- implement wrap and unwrap;
- implement close with wrapper and internal long;
- implement `FeeController`;
- implement seller open fee with `maxSellerFeeNative`;
- implement insurance seed checks.

### Phase 3: Portfolio Margin

- implement equity;
- implement initial margin;
- implement maintenance margin;
- implement live spot oracle reads;
- implement volatility-surface report verification;
- implement surface Merkle proof verification;
- implement surface interpolation;
- implement Black-style option pricing;
- implement spot and surface staleness blocks;
- implement model-value scenario stress;
- benchmark margin gas with maximum supported positions and scenario count;
- implement account health views;
- block unsafe withdrawals and wraps.

### Phase 4: Kuru Integration

- implement venue registry;
- implement venue router;
- implement Kuru adapter;
- implement Kuru venue-fee preview and limits;
- implement Optara buyer fee with `maxBuyerFeeNative`;
- verify base and quote markets;
- build sell flow;
- build buy flow;
- build buy-to-close flow;
- build unwrap-as-hedge flow;
- leave `InhouseMatchingAdapter` as a future adapter using the same router interface.

### Phase 5: Settlement And Redemption

- implement round-in-force finalization;
- implement `ORACLE_STALLED`;
- settle internal signed balances;
- implement settlement window;
- implement `unsettledDebtorCount[groupId]`;
- implement group-level net settlement across all series;
- implement keeper settlement rewards;
- compute insurance contribution;
- compute recovery ratio;
- open redemption only after ratio is fixed;
- redeem wrapper tokens at the fixed ratio;
- handle expired-but-unredeemed wrappers.

### Phase 6: Liquidation And Insurance

- implement liquidatable state;
- implement Dutch portfolio-slice liquidation;
- implement mark-value cash transfer for liquidation;
- reject liquidation that pays the liquidator's margin requirement from the account;
- implement wrapper-burn close liquidation;
- implement liquidator post-state initial-margin check;
- implement whole-bucket auction fallback;
- implement insurance fund;
- implement bad-debt accounting;
- test Kuru outage cases.

### Phase 7: Frontend And Indexer

- rebuild Series page around wrapper token and Kuru venue;
- rebuild Portfolio page around account health;
- add Kuru status and balances as external-only;
- add clear warnings for external proceeds;
- add one-click helper flows where safe.

## Non-Negotiable Invariants

Before price finalization:

```text
sumInternalSignedBalances(series) + wrapperSupply(series) = 0
```

After price finalization and recovery-ratio calculation:

```text
redemptionReserve[groupId] >=
    sum over series:
        remainingWrapperSupply[seriesId]
      * payoffPerWrapper[seriesId]
      * recoveryRatio[groupId]
```

```text
all internal and external long claims in the same group use the same recoveryRatio[groupId]
```

```text
redemptions remain closed until unsettledDebtorCount[groupId] == 0 and recoveryRatio[groupId] is fixed
```

```text
Kuru fill != Optara close
```

```text
Kuru balance != Optara margin
```

```text
Kuru price != settlement oracle
```

```text
Kuru venue fee != Optara protocol fee
```

```text
Optara protocol fees never count as user margin after debit
```

```text
official buyer routes must enforce maxBuyerFeeNative
```

```text
seller mint/open routes must enforce maxSellerFeeNative
```

```text
Kuru option price != authoritative volatility surface
```

```text
new risk requires fresh accepted spot and volatility-surface reports
```

```text
surface reports are chain-bound, protocol-bound, sequenced, and non-replayable
```

```text
Only Optara can mint wrapper tokens
```

```text
Wrapper minting must create equal internal short risk
```

```text
Wrapper redemption must burn the wrapper token
```

```text
Internal margin credit requires internal custody
```

```text
Uncapped calls require liquidation and insurance
```

```text
liquidation cash exchange is based on mark value, not transferred margin requirement
```

```text
liquidator must fund post-transfer margin from the liquidator's own account
```

```text
upgrades cannot rewrite existing series terms, finalized prices or recovery ratios
```

## Recommendation

Build Optara PM as a venue-first clearing protocol.

Do not copy Derive's centralized matching model. Use Derive's useful ideas only where they fit:

- signed positions;
- portfolio margin;
- volatility-surface based valuation;
- account equity;
- maintenance margin;
- liquidation;
- insurance.

But keep Optara's composability goal:

```text
external ERC-20 long claims trade on Kuru
Optara clears and settles the obligation
```

The final architecture should be:

```text
Optara PM:
uncapped options
portfolio margin
signed volatility-surface oracle
external wrapper tokens
permissionless secondary market integration
Kuru as first venue
other venues later
```

This gives the protocol capital efficiency without turning Optara into a centralized matching venue.
