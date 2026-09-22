# Testing

Foundry unit, fuzz and invariant tests, plus Slither. The formulas in [math.md](./math.md) and the fee rules in [contracts.md](./contracts.md) are the source of expected values.

## Test Helpers

- `MockAggregator`: a configurable Chainlink feed. It must support several rounds with chosen `answer` and `updatedAt`, a chosen `decimals`, phase-encoded round ids, and reverting on rounds that do not exist.
- `MockERC20` with configurable decimals.
- Malicious ERC-20s that re-enter `mint`, `redeem`, `claimWriterResidual` and `sweepFees` from their transfer functions.
- A fee-on-transfer token, used to show the asset allowlist is the only defense.

## First Tests to Write

The six vectors in `math.md`, asserted **bit for bit**, before the vault exists. Each vector test must assert `UQ_SCALE`, `collateralPerOption`, both rates and both claim amounts, not just the final payout. A test that only checks the payout can pass while an intermediate value is wrong for another decimal pair.

Then vectors for these cases:

- Underlying decimals 18 / quote 6, 6 / 18, 8 / 6, and equal decimals.
- Option decimals 18 (the only value the factory produces). The math library itself is also tested with other option decimals.
- `S < K`, `S == K`, `S > K`, for both call and put.
- Very small and very large option amounts.
- Very high and very low settlement prices.

## Factory

- Valid call and valid put creation.
- **Creating the same series twice reverts with `DuplicateSeries`.** There is no idempotent return.
- **Anyone can create a series.** An address with no role can call `createSeries` with valid parameters.
- Reverts for: zero address, same underlying and quote, non-allowlisted asset, decimals above 18, creation paused (`CreationPaused`), zero strike, strike not a multiple of `strikeStep`, expiry less than an hour away, expiry more than 30 days away, expiry not on the 08:00 UTC slot, and a fee above its cap.
- **Feed check.** A feed that is not exactly the approved feed for the pair reverts (`FeedNotApproved`), including a real Chainlink feed for a different pair. A disabled pair (feed set to zero) reverts. A user cannot influence `maxChainlinkAgeAtExpiry`.
- **Fixed parameters.** The vault's `contractSize` is `10 ** underlyingDecimals`, `optionDecimals` is 18, `minOptionAmount` is `MIN_OPTION_AMOUNT`, `maxTotalShortAmount` equals the underlying's cap at creation, and `maxChainlinkAgeAtExpiry` equals the pair's value at creation.
- **Generated names.** `name` is "Optara WMON/USDC Call #N" and `symbol` is "OPT-WMON-USDC-C-N" (Put and P for puts) with `N` increasing by one per series. The pair is always the pair of the actual assets, read from them. A token with no `symbol()` yields `?` and creation still works. No user input reaches either.
- The smallest mintable position always needs at least one unit of collateral, because `requiredCollateral` rounds up. (`InvalidMinOptionAmount` is a defensive check only.)
- `setPairConfig` is `ADMIN` only. It rejects an unallowlisted asset, an unreadable or above-18 feed decimals, a non-positive latest answer, a zero age and a zero strike step. It affects only series created afterward, and existing series keep their old feed and age.
- `setMaxShortAmount` and `setDefaultFeeConfig` are `ADMIN` only and affect only series created afterward.
- `seriesIdOf(vault)` and `vaultOf(seriesId)` are exact inverses. `computeSeriesId` matches the id `createSeries` assigns.
- `isOptionToken` is false for a lookalike ERC-20 with the same name and symbol.
- Derived values (`uqScale`, `collateralPerOption`, `optionScale`, `collateralAsset`) are correct for every decimal pair.
- Fee rates in the vault equal `defaultFeeConfig` at creation time. Changing the defaults afterward gives a later series different rates and leaves earlier series unchanged.
- `setDefaultFeeConfig` above a cap reverts.
- `setKuruMarket` is `ADMIN` only, works once, and reverts the second time (`KuruMarketAlreadySet`).
- Only two roles exist: `ADMIN` and `PAUSER`.
- `setCreationPaused(true)` works for `PAUSER` and `ADMIN`. `setCreationPaused(false)` works for `ADMIN` only, and reverts for `PAUSER`.

## Vault: Minting

- Call and put collateral amounts are correct, and rounded up.
- Mint below `minOptionAmount` reverts. Mint at or after expiry reverts.
- Mint past `maxTotalShortAmount` reverts (`OpenInterestCapExceeded`); a cap of 0 means uncapped.
- The mint fee is charged **on top** of collateral, and `collateralLocked` equals required collateral exactly.
- `writerShortBalance` goes to `msg.sender`, tokens go to `receiver`, and `totalSupply == totalShortAmount`.
- Mint reverts while frozen (`MintPaused`), and only mint is affected.
- A re-entering token cannot double mint.

## Vault: Settlement

- `settle` before expiry reverts. `settle` twice reverts (`AlreadySettled`).
- Call and put rates are correct for `S < K`, `S == K`, `S > K`.
- `buyerPayoutRate + writerResidualRate == collateralPerOption` exactly, as a fuzz target over all prices.
- The settlement price equals the answer of `chainlinkRoundId`, and never the successor's. Use a feed where the two answers differ.
- Kuru or any market price has no path to influence settlement.
- `settle` is not payable and the vault holds no native token.

### Anchoring (the highest-value group)

- **Settling immediately and settling days later give the identical price**, even if the feed moved a lot in between.
- A proof whose `chainlinkRoundId` has `updatedAt > expiry` reverts (`SettlementAnchorRoundAfterExpiry`).
- A proof naming an **earlier** round whose real successor also has `updatedAt <= expiry` reverts.
- A proof whose supplied successor is not the immediate successor (it skips a round) reverts, even if that successor has `updatedAt > expiry`.
- A round with `updatedAt == expiry` is the round in force, and its successor is the proof's successor.
- A proof across a **phase boundary** succeeds with the correct successor, and fails if the code derives the successor as `roundId + 1`.
- A round that does not exist reverts as `SettlementAnchorRoundUnavailable` (for the round in force) or `SettlementAnchorSuccessorUnavailable` (for its successor), not with an unexplained error.
- A round in force older than `maxChainlinkAgeAtExpiry` at expiry reverts (`SettlementAnchorTooStale`). The result does not change with the time `settle` is called.
- **A slow but healthy feed settles.** With an hour between updates, the series still settles once the successor round exists, at the price of the round in force.
- `settle` reverts while no successor round exists, the series stays unsettled, and the same call succeeds later at the same price.
- A feed that never publishes after expiry cannot be settled. This confirms the lock case is real and disclosed.
- Answer of zero or below reverts (`OracleInvalid`).
- Feed decimals of 8 and 18 both normalize to `PRICE_SCALE` correctly.

## Vault: Redemption and Claims

- Redeem before settlement reverts. Redeem of zero reverts.
- **Redeem works for an amount below `minOptionAmount`**, acquired by transfer. This is a lockout regression test.
- `claimWriterResidual` also accepts any nonzero amount up to the short balance.
- Redeem burns first, and redeeming twice fails because the balance is gone.
- An out-of-the-money redeem burns, pays nothing, charges no fee and does not call the token.
- Claim before settlement reverts. Claim more than the short balance reverts. Claiming twice fails.
- Payout and residual match `math.md`. Buyer payout stays solvent after writers claim, in any order.
- Re-entering tokens cannot double redeem or double claim.

## Multiple Writers

Several writers can mint into the same series and their collateral is pooled in one vault. Each writer's claim is capped by their own `writerShortBalance`, and the entitlement is a per-option rate fixed at settlement, so writers cannot affect each other. The tests try every route a malicious writer might use:

- Claiming more than their own short (one wei more, another writer's amount, everyone's amount, `type(uint256).max`) reverts with `InsufficientShortBalance`. Claiming twice reverts.
- Naming another writer as the `receiver` spends the caller's own short and pays that address: no gain, and the other writer's short is untouched.
- `payout` pays each account to that account and cannot route one writer's residual to another, even if the attacker lists himself twice. `payAccount` cannot be called directly.
- Being a writer gives no claim on the buyers' payout: a writer who holds no tokens cannot redeem.
- A writer cannot claim before settlement, so no collateral can be pulled out early.
- **A huge late mint changes nothing for anyone else.** Two identical vaults, one with a large last-second mint by an attacker: the rates, and every other writer's and holder's amounts, are identical.
- The order in which writers and holders claim never changes any amount.
- **Fuzz:** four writers with random sizes, a random price, calls and puts, random claim order, and an attacker trying to over-claim. Each honest writer receives exactly `floor(short * rate / scale)` and the holders are still fully paid afterward.

## Keeper Payout

- `payout` reverts before settlement (`NotSettled`).
- For a wallet holder, `payout` redeems the **entire** balance and pays **that account**, never the caller. The payout, exercise fee, accounting and `OptionsRedeemed` event match `redeem(balance, account)` exactly.
- For a writer, `payout` claims the **entire** short balance and pays **that writer**. It matches `claimWriterResidual(short, account)` exactly.
- An account that is both a holder and a writer receives both in one call.
- An account owed nothing is a no-op. A duplicate in the list is a no-op the second time, so nothing is paid twice.
- **Contracts are skipped.** A contract holding option tokens for others is not redeemed by `payout`, and neither is a contract writer. Each can still call `redeem` and `claimWriterResidual` itself.
- **Failure isolation.** A recipient whose transfer reverts (a blacklisting token mock) fails only its own account. Every other account in the list is still paid and the failed account's state is unchanged.
- `payAccount` reverts with `Unauthorized` when called by anyone other than the vault.
- A token that tries to re-enter during `payout` cannot double pay.
- The owner can still call `redeem` and `claimWriterResidual` themselves before or after the keeper acts, and the totals paid are the same either way, so solvency invariants and fragmentation fuzz still pass with a mix of both.
- `settle` performs no payout and makes no external token call.

## Fees

- Exercise fee is taken from the gross payout, and `collateralLocked` still drops by the gross amount.
- Residual claims charge no fee.
- `sweepFees` sends exactly `accruedFees` to `factory.feeRecipient()`, has no receiver argument, and never touches `collateralLocked`.
- `sweepFees` reverts with `NoFeesAccrued` when empty and works while minting is paused and before or after settlement.
- Rotating `feeRecipient` changes only the next sweep's destination.
- No role can change a live series' fee rates.

## Roles and Pausing

- **Freeze scope.** `PAUSER` and `ADMIN` can freeze minting on a series with `setMintPaused(true)`. `PAUSER` cannot unfreeze, and `ADMIN` can.
- A frozen series still allows `settle`, `redeem`, `claimWriterResidual`, `payout`, `sweepFees` and ERC-20 transfers. Test each one explicitly on a frozen series, before and after expiry.
- A freeze on one series has no effect on any other series.
- No role can stop `settle`, `redeem`, `claimWriterResidual`, `payout`, `sweepFees` or an ERC-20 transfer.
- `ADMIN` can sweep fees but has no function that can move `collateralLocked`.

## Premium Guard

- A buy inside the range returns `valid` and `Reason.OK`.
- **The buyer limit binds on `allInCost`**: a quote whose gross premium is under the limit but whose fee-inclusive cost is over it fails with `ABOVE_BUYER_LIMIT`.
- **Totals, not per-option**: for an amount well above one whole option, a route whose per-option cost is under the bound but whose total is over it fails. This is the regression test for the unit bug.
- A high taker fee cannot make an over-limit trade pass.
- Taker fee and a maker-side fee both round up. A maker rebate rounds down. Assert exact integers where the division does not terminate.
- `hardMaxPremium` is net of `exerciseFeeBps`. An ask between the net and gross ceilings is rejected.
- `acceptableMinPremium` is unaffected by `exerciseFeeBps`.
- Minimum bounds round up and maximum bounds round down. The two bounds do not share one rounded `E(a)`. Use a decimal pair where division does not terminate.
- A sell below `acceptableMinPremium` fails with `BELOW_ACCEPTABLE_MIN`. Sell proceeds use the maker fee, not the gross premium.
- An **empty range** (`acceptableMinPremium > hardMaxPremium`) returns `EMPTY_RANGE` and prefers neither bound.
- Fails with the right reason for: unknown series, expired series, wrong or unset market, deadline passed, venue fee above the cap, stale or unavailable Chainlink reference.
- `tryLatestPrice` never reverts, including when the feed reverts.
- Guard parameter setters are `ADMIN` only and reject values above 10,000.
- Changing the guard's parameters never changes any vault's behavior.

## Invariants (Foundry invariant tests)

```text
collateralLocked >= remaining buyer payout obligation + remaining writer residual obligation
balanceOf(vault) >= collateralLocked + accruedFees
buyerPayoutRate + writerResidualRate == collateralPerOption            exactly, for all S
totalSupply == totalShortAmount before settlement
sum(writerShortBalance) == totalUnclaimedShortAmount
the settlement result is write-once
fee rates and series parameters are immutable
totalBuyerPayoutClaimed + totalWriterResidualClaimed + collateralLocked == total collateral ever locked
no account can receive more than the formula allows
writerShortBalance never underflows
option supply falls only through redemption
```

## Fuzz Targets

- Mint amounts, strike prices, settlement prices, and every supported decimal pair. Fuzz `OptionMath` with arbitrary contract sizes, and the vault with the factory-fixed size `10 ** underlyingDecimals`.
- **Fragmented mints and fragmented claims.** The aggregate solvency proof covers exactly this case, so fuzz it specifically.
- Redemption order and writer claim order.
- Fee rates across their full legal range: solvency must hold at every rate.
- **Zero-fee equivalence**: with both fee rates at zero, every amount is bit-identical to a no-fee path.
- Guard bounds across random prices, strikes, decimals and tolerances: no overflow, and both bounds move only toward rejection.

## Scenarios

1. One writer, one buyer, in-the-money call.
2. One writer, one buyer, out-of-the-money call.
3. Several writers and holders with partial redemptions and claims.
4. Put deep in the money, and put out of the money.
5. Settlement blocked until the successor round appears, then succeeds.
6. Settle days late at the same price.
7. Minting paused, everything else still works.
8. A holder acquires a sub-minimum balance by transfer and exits.
9. Kuru unavailable: mint, settle, redeem and claim all work with no market at all.

## Static Analysis and Coverage

```text
forge test
forge test --fuzz-runs 10000
forge coverage
slither .
```

Any high or medium Slither finding is fixed or documented as a false positive.

## Ready for External Audit When

- All tests pass, including invariants at high fuzz runs.
- The six vectors and the anchoring group are green.
- NatSpec is complete for public and external functions.
- No TODOs remain in the contracts.
- Feed addresses, deviation and heartbeat values, and Kuru market notes are documented.
- Every decision in `security-and-launch.md` is resolved.
