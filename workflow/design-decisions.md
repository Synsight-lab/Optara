# Design Decisions

## DD-01: V1 Options Are Fully Collateralized

### Decision

Every option minted in V1 must be backed by the maximum possible liability at mint time.

### Rationale

This removes liquidation, margin, leverage, and solvency complexity from V1. A malicious writer cannot mint claims and later walk away from losses because the collateral is already locked.

### Consequences

- Capital efficiency is lower than a margin system.
- Security review is simpler.
- Settlement does not require liquidations.
- The protocol can stay solvent even during extreme price moves.

## DD-02: V1 Uses European Exercise Only

### Decision

Options cannot be exercised before expiry. Holders can redeem only after the series is settled.

### Rationale

Early exercise creates additional state transitions, partial close behavior, oracle timing questions, and race conditions. European exercise keeps V1 focused on issuance, trading, settlement, and redemption.

### Consequences

- Buyers who want to exit before expiry must sell the option token on Kuru or transfer it elsewhere.
- Liquidity risk is explicit.
- The settlement lifecycle is much easier to test.

## DD-03: Option Series Parameters Are Immutable

### Decision

Underlying asset, quote asset, option type, strike, expiry, oracle adapter, contract size, and collateral model cannot change after deployment.

### Rationale

An option token is only meaningful if its claim cannot mutate. Immutability protects buyers, writers, market makers, and integrators from governance or operator changes that alter the economic meaning of a token.

### Consequences

- Mistaken series parameters require deploying a new series.
- Frontends can cache series metadata with high confidence.
- Security reviewers can reason about each series as a fixed instrument.

## DD-04: Use One ERC-20 Option Token Per Series

### Decision

Each option series is represented by a standard ERC-20 token.

### Rationale

ERC-20 compatibility makes the option transferable and easy to list on Kuru. Kuru does not need custom option logic because it only trades the token.

### Consequences

- Token holders can acquire options through any transfer path.
- Redemption must rely on final token ownership, not purchase history.
- Fake tokens can mimic names and symbols, so canonical registry checks are mandatory.

## DD-05: Kuru Is Secondary Trading Infrastructure Only

### Decision

Kuru Router and OrderBook are used only to create and trade markets for the option token against the quote asset.

### Rationale

The Kuru market price can be thin, manipulated, stale, or unavailable. It is useful for trading, but it is not safe as a settlement input.

### Consequences

- Kuru downtime does not block settlement.
- Kuru wash trades do not affect payout.
- Kuru liquidity risk is borne by traders, not by the vault.

## DD-06: Settlement Uses an Independent Oracle

### Decision

The final settlement price comes from an approved oracle adapter for the underlying/quote pair.

### Rationale

Option payoff must be based on an external settlement source, not the price of the option token itself. The oracle adapter can enforce freshness, pair identity, decimals, and validity rules.

### Consequences

- Oracle design becomes a critical security dependency.
- Settlement can fail safely if the oracle is stale or invalid.
- The project needs oracle manipulation analysis before launch.

## DD-07: Calls Use Underlying Collateral and Puts Use Quote Collateral

### Decision

Call writers lock the underlying asset. Put writers lock the quote asset.

### Rationale

This matches the maximum liability of each instrument in the selected V1 settlement model. A call can be fully covered by the underlying exposure. A put can be fully covered by the strike value in quote units.

### Consequences

- Call payout is paid in underlying units.
- Put payout is paid in quote units.
- Users must understand which asset they will receive at redemption.
- The math must handle oracle price, strike, token decimals, and conservative rounding.

## DD-08: Use Cash-Equivalent Oracle Settlement, Not Physical Delivery

### Decision

V1 uses oracle-based settlement formulas rather than requiring buyers to deliver quote for calls or underlying for puts at exercise time.

### Rationale

Physical delivery adds allowance handling, additional asset transfers, and more user steps after expiry. Oracle settlement makes redemption a single burn-and-claim action.

### Consequences

- Calls collateralized by underlying pay the in-the-money value converted into underlying units.
- Puts collateralized by quote pay the in-the-money value in quote units.
- Oracle correctness is central.

## DD-09: Conservative Rounding Is Part of the Security Model

### Decision

Required collateral rounds up. Buyer payout rounds down. Minimum position sizes are enforced.

### Rationale

Rounding must never create more liabilities than collateral. Small dust amounts can become exploitable if they repeatedly round in favor of attackers.

### Consequences

- Some dust may remain after all claims.
- Dust handling must be documented and tested.
- Frontends should prevent users from creating positions below practical thresholds.

## DD-10: Canonical Factory and Registry Defend Against Fake Series

### Decision

Only series deployed by the canonical factory and registered in the registry are official.

### Rationale

Any user can deploy an ERC-20 token with a misleading option-like name. The protocol needs an objective way for frontends and users to verify official series.

### Consequences

- Frontends must check the registry before displaying a series as official.
- Kuru markets should be linked from the registry when possible.
- Token metadata alone is never enough.

## DD-11: V1 Avoids Margin, Leverage, and Liquidations

### Decision

V1 does not support partially collateralized writing, borrowed collateral, portfolio margin, or liquidation engines.

### Rationale

Liquidations are a major attack surface. They depend on price feeds, keeper liveness, auction design, incentives, and volatile market conditions.

### Consequences

- The protocol may be less capital efficient.
- The first version is much easier to audit.
- Future margin versions can be designed after V1 invariants are proven.

## DD-12: Kuru Market Parameters Must Be Treated as Risk Parameters

### Decision

Kuru `sizePrecision`, `pricePrecision`, `tickSize`, `minSize`, `maxSize`, fees, and AMM spread must be validated and documented for each market.

### Rationale

Bad precision or minimum-size settings can make a market unusable, create dust orders, or mislead users about executable liquidity.

### Consequences

- Market deployment should include parameter simulation.
- The registry should store the parameters used for official markets.
- Frontends should avoid assuming every listed market is liquid or healthy.

## DD-13: Series Vaults Should Be Non-Upgradeable

### Decision

The recommended V1 design is non-upgradeable per-series vaults.

### Rationale

Upgradeability can undermine the immutability of an option claim. If the rules can change after buyers and writers enter a series, the token is harder to trust.

### Consequences

- Bugs in a live series cannot be patched by upgrading that series.
- The factory can deploy improved implementations for future series.
- Emergency pause and migration strategies must be considered separately.

## DD-14: Emergency Controls Are Narrow

### Decision

Emergency controls may pause minting and new market-linking, but should avoid blocking valid post-settlement redemptions unless redemption itself is the active source of loss.

### Rationale

Users must be able to claim valid collateral. A broad pause that blocks all exits can create governance risk and user harm.

### Consequences

- Pause roles must be limited and monitored.
- Pause behavior must be included in tests.
- The protocol needs a clear incident response runbook before launch.

## DD-15: Prefer No Pre-Expiry Close Flow in V1

### Decision

V1 should not include a writer close or buyer exercise flow before expiry unless implementation proves it does not weaken collateral accounting.

### Rationale

Close flows are useful, but they create cases where writers must reacquire and burn option tokens, collateral must be unlocked, and total short and long accounting must stay perfectly synchronized.

### Consequences

- Writers remain obligated until settlement in the simplest V1.
- Users can still transfer or trade options before expiry.
- A future V2 can add close flows after the base lifecycle is audited.

## DD-16: Premium Is Writer-Quoted but Market-Range-Constrained

### Decision

Writers may specify ask premiums, and buyers may post bid prices or submit limit-protected marketable orders. However, official frontends, mint-and-list helpers, routed-buy helpers, and primary-sale flows should only treat a writer ask as executable when it is inside an acceptable premium range.

### Rationale

The collateral owner should be able to name the price at which they are willing to sell, but the system should not blindly route buyers into unrealistic asks. An excessively high ask can cause buyer loss or value extraction through bad UX. An excessively low ask can harm the seller or indicate a manipulated flow. The protocol should treat premium as a market outcome constrained by safety rails, not as an unchecked series parameter.

### Consequences

- The series defines payoff rights, not purchase price.
- Kuru order-book liquidity determines executable premiums.
- A writer's ask is only an offer.
- A buyer's limit is the buyer's maximum accepted premium.
- Frontends must never present a writer-selected ask as protocol fair value.
- Official helpers should reject, disable, or clearly flag asks outside acceptable economic and market-liquidity ranges.
- Direct manual Kuru limit orders can still exist outside the helper UX, but they are not considered safe routed execution.

## DD-17: Premium Manipulation Fails Closed in Automated Routes

### Decision

Any simplified buy route must fail closed when market data or execution quality is unsafe.

### Rationale

Kuru markets can be thin, spoofed, wash-traded, or temporarily distorted. This should not affect settlement or collateral, but it can still hurt users if a frontend or router fills a bad order without protection.

### Consequences

- One-click buying requires buyer-side limits such as `maxPremiumPerOption`, `maxTotalPremium`, `minOptionAmountOut`, and `deadline`.
- Automatic routes should reject stale quotes, wide spreads, low depth, excessive price impact, non-canonical markets, and mismatched base or quote assets.
- Automatic routes should reject writer asks outside the acceptable premium range.
- Last-traded price must not be used as fair value.
- Optional reference pricing can be used as a warning or route-safety guard, but not as settlement logic.

## DD-18: Settlement Uses Chainlink Primary and Pyth Corroboration

### Decision

V1 settlement uses Chainlink as the primary oracle when a feed exists for the pair, Pyth as the secondary/corroborating oracle when a feed exists, and optionally an independent DEX TWAP as a tertiary sanity check. Kuru is never used for settlement.

### Rationale

External oracle networks are designed for settlement-grade price data. Kuru order-book prices are valuable for execution and liquidity checks, but they can be thin, manipulated, paused, or unavailable. Requiring independent oracle corroboration reduces the chance that a single compromised or stale source settles a series incorrectly.

### Consequences

- Some pairs may be unavailable in V1 if oracle coverage is weak.
- Settlement can fail closed during oracle outages.
- Premium safety may inspect Kuru depth, but settlement never depends on it.
- Single-oracle series require explicit founder/governance approval.
- Fail-closed settlement implies collateral stays locked during a prolonged outage. See FD-20.

## DD-19: V1 Charges Protocol Fees, Structurally Isolated From Collateral

### Decision

Optara charges a mint fee and an exercise fee in V1. Fees are collected into a balance strictly segregated from collateral: mint fees are charged on top of required collateral, and exercise fees are carved out of an already-computed gross payout.

### Rationale

The protocol needs revenue from launch rather than through a later migration that would require redeploying series or changing live economics. The constraint is that fee logic must be provably incapable of weakening solvency, which the chosen structure guarantees by construction rather than by careful arithmetic: a mint fee that is additive can never reduce collateral, and an exercise fee that splits an already-computed gross payout leaves the amount leaving `collateralLocked` unchanged.

Accrue-and-pull rather than push-on-collection keeps external transfers out of the mint and redeem paths entirely, so a misconfigured fee recipient cannot brick core protocol functions.

### Consequences

- Writers pay slightly more than bare collateral at mint.
- Only in-the-money redemptions pay an exercise fee, so worthless options cost nothing to clear.
- A zero-fee configuration must produce bit-identical results to a no-fee implementation, which is a required fuzz invariant.
- Fee revenue accrues per vault and is swept by a dedicated role.
- The audit must verify fee segregation as a first-class property, not an afterthought.

## DD-20: Fee Rates Are Immutable Per Series

### Decision

Fee rates are snapshotted from `ProtocolConfig` into each series at creation and can never change for that series. Governance changes apply only to series created afterward. Hard caps are compile-time constants that governance cannot exceed even for new series.

### Rationale

DD-03 guarantees that an option token's economic meaning cannot mutate after users enter. A governable fee on a live series would silently break that guarantee: governance could raise the exercise fee after buyers had already paid a premium, retroactively reducing their payoff. Snapshotting makes the complete economics of a series knowable at entry, which is the property that makes the token safe to price and trade.

The fee *recipient* is deliberately not snapshotted, because it affects only where revenue lands and keeping it mutable allows rotating a compromised treasury.

### Consequences

- A fee change requires deploying new series; existing series keep their original rates forever.
- Fee rates are excluded from `seriesId`, so one canonical series exists per economic definition rather than one per fee epoch.
- Worst-case governance capture is bounded by the compile-time caps.
- Frontends can cache a series' fee rates with the same confidence as its strike and expiry.

## DD-21: No Protocol-Owned Trade Router in V1

### Decision

Optara deploys no contract that executes Kuru trades on a user's behalf. `PremiumExecutionGuard` is validation-only. Buyer price protection is delivered by Kuru's native limit-order parameters, and the acceptable-range and market-health checks are enforced by the official frontend.

### Rationale

A router is the only component that would require approval over a buyer's quote balance, making it the highest-value target in the system and the one component that could lose user funds directly rather than merely routing badly. The protection a router adds over a Kuru limit order is the advisory range check, not the hard price bound — Kuru already enforces the hard bound onchain.

The cost of this decision is honesty: the range checks cannot bind a user who trades directly against Kuru, and V1 must say so rather than implying protocol-level premium protection it does not have.

### Consequences

- Attack surface stays minimal and no contract holds user quote balances.
- Buyer limits must be set on Kuru's own order parameters, computed on fee-inclusive cost.
- Acceptable-range enforcement is a property of the official frontend, not of the protocol.
- User-facing copy must not claim Optara guarantees a fair premium.
- A future router must call `checkPremium` atomically and revert on failure, at which point the range checks become real onchain guarantees for its users.
