# Testing and Invariants

## Purpose

This file defines required tests before production.

The normative sources for expected values are [math-of-core-invariants.md](./math-of-core-invariants.md) for collateral, rate, and claim math, and [fee-spec.md](./fee-spec.md) for fee arithmetic and segregation.

## Test Framework

Recommended:

```text
Foundry unit tests
Foundry fuzz tests
Foundry invariant tests
Static analysis with Slither
Gas snapshots for critical paths
Fork tests against Monad testnet when available
```

## Unit Tests

### Series Creation

Test:

- Valid call series creation.
- Valid put series creation.
- Duplicate series behavior.
- Invalid zero addresses.
- Invalid same underlying and quote.
- Invalid strike.
- Invalid expiry.
- Invalid contract size.
- Invalid min amount.
- Invalid oracle config.
- Non-allowlisted asset rejection.
- Registry canonical mapping.
- `createSeries` accepts only `CreateSeriesParams`; there is no code path by which a caller supplies `feeConfig`, `collateralPerOption`, `uqScale`, `collateralAsset`, or `seriesId`.
- Derived values match their formulas for every supported decimal pair.
- `feeConfig` equals `ProtocolConfig.defaultFeeConfig()` at the moment of creation.
- Changing `ProtocolConfig` defaults between two creations produces two series with different, individually correct snapshots.
- `computeSeriesId` returns the same id the subsequent `createSeries` assigns.
- `registry.getVault(seriesId)` and `registry.getSeriesByToken(vault)` are exact inverses.
- `isOptionToken` is false for a lookalike ERC-20 with an identical name and symbol.
- **An oracle config approved for one pair is rejected on a different pair.** Approve a config for (MON, USDC), then attempt to create (WBTC, USDC) with the same config; creation must revert. Without the pair in the approval key this succeeds and the WBTC series settles at MON's price, so this is the regression test for that binding.
- `configHash` is computed as `keccak256(abi.encode(oracleConfig))` and a single differing field produces a different, unapproved hash.
- A config with both `requireChainlink` and `requirePyth` false is rejected. Without this check the series would settle with no oracle, since a quorum over zero required sources passes vacuously.
- A config marking a source required but leaving its identifier zero is rejected.
- `maxOracleDeviationBps` below the floor is rejected, since a near-zero tolerance makes the series permanently unsettleable while looking valid until expiry.
- `maxOracleDeviationBps` above the ceiling is rejected.
- `chainlinkStaleAfter == 0` is rejected when Chainlink is required, and `pythStaleAfter == 0` when Pyth is required.
- `maxPythConfidenceBps == 0` or above the ceiling is rejected when Pyth is required.
- `maxChainlinkAgeAtExpiry == 0` is rejected when Chainlink is required.
- `maxPythSettlementLag == 0` is rejected when Pyth is required.
- Composed settlement feed configs are rejected; V1 accepts only direct feeds for the approved pair.
- `createSeries` reverts for a caller without `SERIES_CREATOR_ROLE`.
- A vault `initialize` call reverts with `AlreadyInitialized` on a second call, and reverts for any caller other than the canonical factory.
- The vault implementation contract behind the clones cannot be initialized by a third party.
- A cloned vault reports the correct `name()`, `symbol()` and `decimals()` (equal to `optionDecimals`).
- Minting beyond `maxTotalShortAmount` reverts with `OpenInterestCapExceeded`; a series with the cap set to 0 is uncapped.
- `maxTotalShortAmount` has no setter and cannot be raised after creation.

### Minting

Test:

- Call mint collateral amount.
- Put mint collateral amount.
- Rounding up collateral.
- Mint below min amount reverts.
- Mint at expiry reverts.
- Mint after expiry reverts.
- Writer short balance increases.
- Option supply equals total short amount.
- Fee-on-transfer mock token is rejected or fails safely.
- Reentrancy token cannot double mint.

### Settlement

Test:

- Settle before expiry reverts.
- Settle succeeds once the Chainlink successor round (`updatedAt > expiry`) exists and, if Pyth is required, a Pyth update inside `maxPythSettlementLag` is supplied. Settlement at exactly `block.timestamp == expiry` fails unless the Chainlink successor round already exists, which it normally does not.
- Repeated settle reverts.
- Chainlink-only valid path if explicitly allowed.
- Pyth-only valid path if explicitly allowed.
- Chainlink settlement anchor missing, too late, or invalid reverts.
- Pyth settlement anchor missing, too late, or invalid reverts.
- A Pyth price whose confidence interval exceeds `maxPythConfidenceBps` of its price reverts with `OraclePythConfidenceTooWide`, on both settlement and reference reads.
- Chainlink/Pyth deviation too high reverts.
- Chainlink/Pyth within threshold succeeds.
- Settlement depends only on the anchored Chainlink and Pyth observations. No other price source exists to influence it.
- Kuru price cannot affect settlement.
- The router reads config from the registry: there is no signature by which a caller supplies an `OracleConfig`, and a series cannot be settled under weakened requirements.
- Replacing an adapter address cannot change which feed a live series resolves to, since feed identifiers are frozen in the series config.
- An adapter returns a `PRICE_SCALE`-normalized price for sources with 8, 12, and 18 decimals.
- Adapters apply no staleness or deviation policy of their own; stale reference data is rejected by the router, not the adapter.
- `settle` refunds unused native token and the vault's native balance is zero afterward.
- Overpaying the Pyth fee by a large margin still refunds correctly.

Settlement anchoring, the highest-value group here:

- **Settling early and settling late produce the identical price.** Settle one series immediately after expiry and an identical one days later, with the feed having moved substantially in between; both must return the expiry-anchored price.
- A proof naming a round whose `updatedAt > expiry` as the round in force reverts with `SettlementAnchorInvalid`.
- A proof naming an earlier round whose real successor also has `updatedAt <= expiry` reverts, since that round is not the last one at or before expiry.
- A proof whose supplied successor is not the immediate successor (it skips an intervening Chainlink round) reverts, even if the supplied successor has `updatedAt > expiry`.
- A round published at exactly `updatedAt == expiry` is the round in force at expiry, and its successor is the proof's successor.
- The settlement price is the answer of `chainlinkRoundId`, never of `chainlinkNextRoundId`. Assert this with a feed where the two answers differ.
- A Chainlink proof crossing a proxy phase boundary succeeds when the explicit successor is correct, and fails if the implementation tries to derive the successor as `roundId + 1`.
- **A slow but healthy Chainlink feed settles.** With a heartbeat gap of an hour, a series still settles once the successor round is published, using the round in force at expiry; there is no lag bound to breach.
- Settlement reverts while no Chainlink successor round exists yet, the series stays `ACTIVE`, and the same call succeeds once the successor is published, at the same price.
- A round in force at expiry older than `maxChainlinkAgeAtExpiry` reverts with `SettlementAnchorTooStale`, measured against `expiry`, not `block.timestamp`: changing when `settle()` is called must not change the outcome.
- No Pyth update inside `expiry + maxPythSettlementLag` reverts with `SettlementAnchorTooLate`, and the series stays `ACTIVE`.
- A Chainlink feed that never publishes a round after expiry cannot be settled, confirming the FD-20 path is reachable.
- Chainlink is anchored to the round in force at expiry and Pyth to its first update at or after expiry; a live Pyth read paired with an anchored Chainlink read must not pass.
- With both sources required, the deviation check compares the expiry-anchored Chainlink price with the expiry-anchored Pyth price. A price move between expiry and the Chainlink successor round must not cause a deviation failure, because the successor's price is not used.
- `chainlinkStaleAfter` has no effect on settlement: setting it very small must not block an otherwise valid anchored settlement.
- `chainlinkStaleAfter` and `pythStaleAfter` do affect reference-price reads used for premium safety.

### Redemption

Test:

- Redeem before settlement reverts.
- Redeem zero reverts.
- **Redeem succeeds for an amount below `minOptionAmount`.** Acquire a sub-minimum balance by transfer, then redeem it. A minimum applied here would trap the holder's funds permanently, so this is a lockout regression test, not a nicety.
- `claimWriterResidual` likewise accepts any nonzero amount.
- Redeem burns tokens.
- Redeem transfers correct payout.
- Redeem twice fails due to burned balance.
- Zero payout redemption burns successfully.
- Reentrancy cannot double redeem.

### Writer Residual

Test:

- Claim before settlement reverts.
- Claim more than short balance reverts.
- Claim correct residual.
- Claim twice fails for same short amount.
- Buyer payout remains solvent after writer claims.

### Premium

Test:

- Writer ask inside acceptable range passes.
- Ask above acceptable max fails routed buy.
- Ask below acceptable min warns or blocks listing helper depending config.
- Buyer all-in cost limit exceeded fails.
- **Buyer limit binds on `allInCost`, not `grossPremium`**: a quote whose gross premium is under the limit but whose fee-inclusive cost is over must fail.
- **Bounds are compared as totals**: for an option amount well above one whole option, a route whose per-option cost is below the bound but whose total is above it must fail. This is the regression test for the total-versus-per-option unit bug.
- A high-taker-fee market cannot pass a range check that the fee-inclusive cost would fail.
- Seller-side minimum uses proceeds after the maker-side adjustment, and assumes the adjustment is a fee until FD-17 proves otherwise.
- `hardMaxPremium` is net of `exerciseFeeBps`: with a nonzero exercise fee, the ceiling is strictly below the gross current-reference ceiling.
- An ask priced between the net and gross current-reference ceilings is rejected by the official simplified route, without claiming the option could never later become profitable.
- `acceptableMinPremium` is unaffected by `exerciseFeeBps`: changing that rate leaves the seller floor identical.
- Minimum bounds round up and maximum bounds round down, so every rounding step tightens the rail; assert against exact expected integers at a decimal pair where the division does not terminate.
- The two bounds do not share a single rounded `E(a)`; each rounds its exposure term in its own direction.
- Depth-walk estimate includes taker fee and AMM spread.
- The estimated taker fee rounds up and the maker-side fee rounds up (a rebate rounds down): assert exact integers at a premium where `premium * bps / BPS_SCALE` does not divide evenly.
- When `acceptableMinPremium > acceptableMaxPremium`, the official simplified route is disabled and neither bound is silently preferred.
- Insufficient depth for requested size fails rather than extrapolating.
- Market with venue fees above the linkable cap is rejected with `KuruFeeTooHigh`.
- Deadline expired fails.
- Non-canonical Kuru market fails.
- Stale Kuru quote fails.
- Wide spread fails.
- Low depth fails.
- Excessive price impact fails.
- Single last-traded price is ignored.
- `previewPremium` returns a reason instead of reverting; `checkPremium` reverts.

### Fees

Test:

- Mint fee is charged on top of collateral, never deducted from it.
- `collateralLocked` after mint equals required collateral exactly, excluding the fee.
- Exercise fee is deducted from gross payout and `collateralLocked` still decreases by the gross amount.
- Writer residual claims are never fee-bearing; the claimed amount equals the gross residual exactly.
- Out-of-the-money redemption charges no fee and still burns.
- `sweepFees` transfers exactly `accruedFees` and cannot reduce `collateralLocked`.
- `sweepFees` reverts with `NoFeesAccrued` when nothing has accrued.
- `sweepFees` sends to `ProtocolConfig.feeRecipient()` and has no receiver argument, so a fee admin cannot redirect fees.
- Rotating `feeRecipient` changes the destination of the next sweep and nothing else.
- `sweepFees` succeeds while the series is `ACTIVE` and while every pause flag is set.
- Fee rates cannot be changed on a deployed series by any role.
- `createSeries` reverts with `FeeExceedsCap` above any cap.
- Changing `ProtocolConfig` defaults does not affect an existing series.
- Fee recipient rotation does not affect any series' economics.

## Math Test Vectors

The five worked vectors in [math-of-core-invariants.md](./math-of-core-invariants.md) are normative and must be asserted exactly, bit-for-bit. Write them first, before the vault implementation exists.

Then create additional deterministic vectors for:

- Underlying decimals 18, quote decimals 6.
- Underlying decimals 6, quote decimals 18.
- Underlying decimals 8, quote decimals 6.
- Underlying decimals equal to quote decimals.
- Option decimals 18.
- Option decimals 6.
- `S < K`, `S == K`, `S > K`.
- Very small option amount.
- Very large option amount.
- Very high settlement price.
- Very low settlement price.

Each vector must assert `UQ_SCALE`, `collateralPerOption`, both rates, and both claim amounts, not just the final payout. A test that checks only the payout will pass while an intermediate value is wrong in a way that surfaces at a different decimal pair.

## Invariant Tests

Required invariants:

```text
collateralLocked >= remaining buyer payout obligation + remaining writer residual obligation
vaultBalance >= collateralLocked + accruedFees
buyerPayoutRate + writerResidualRate == collateralPerOption      exactly, for all S
totalSupply <= totalShortAmount before settlement
sum(writerShortBalance) == totalUnclaimedShortAmount
settlement result is write-once
fee rates are immutable after creation
Kuru price changes do not change payout
premium paid does not change payout
fee collection never reduces collateral backing outstanding claims
no user can receive more than formula permits
sum paid + remaining collateral <= total collateral deposited
writerShortBalance cannot underflow
option totalSupply decreases only through redemption
```

## Fuzz Targets

Fuzz:

- Mint amounts.
- Strike prices.
- Contract sizes.
- Settlement prices.
- Decimals combinations, including every supported underlying/quote pair.
- **Fragmented mints and claims**, since the aggregate solvency proof specifically covers fragmentation and that is where per-transaction ceiling and per-claim floor interact.
- Redemption order.
- Writer claim order.
- Fee rates across their full legal range, asserting solvency holds at every rate.
- Zero-fee equivalence: with all rates at zero, results are bit-identical to a no-fee path.
- Oracle deviation.
- Premium ask values.
- Kuru depth snapshots and venue fee levels.

## Stateful Scenario Tests

Scenarios:

1. One writer, one buyer, in-the-money call.
2. One writer, one buyer, out-of-the-money call.
3. Multiple writers, multiple buyers, partial redemptions.
4. Put expires deep in the money.
5. Put expires out of the money.
6. Oracle failure then later valid settlement.
7. Kuru market unavailable but settlement succeeds.
8. Premium route manipulated but redemption unaffected.
9. Emergency pause minting only, settlement still works.
10. Redemption pause active only under simulated exploit; it gates both `redeem` and `claimWriterResidual`, and neither mint, settle nor fee sweep.
11. Each vault pause flag gates only its own action and leaves the other two working.
11a. No pause flag can block an ERC-20 transfer. There is no transfer pause, and no combination of the remaining flags prevents a holder moving tokens.
12. Registry `kuruLinkPaused` blocks linking without affecting mint, settle, or redeem.
13. Guard `routingPaused` blocks route validation without affecting the vault at all.

## Static Analysis

Run:

```text
slither .
forge test
forge test --fuzz-runs 10000
forge coverage
```

Any high or medium Slither finding must be fixed or explicitly documented as false positive.

## Audit Readiness

Before external audit:

- All tests passing.
- Invariant tests passing with high fuzz runs.
- Deployment addresses documented.
- Oracle feed IDs documented.
- Kuru market params documented.
- Founder decisions resolved.
- No TODOs in contracts.
- NatSpec complete for public/external functions.
