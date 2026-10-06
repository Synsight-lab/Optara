# Invariants

Properties that must hold after every transaction. Each one maps to tests in [TEST_CASES.md](TEST_CASES.md), to
stateful fuzzing handlers in [TESTING.md](TESTING.md) §5, and, where it is a property of the math or the
accounting, to the executable reference checks in [`reference/`](../reference) (§11 below).

The **Verified** column says how each invariant is checked today:

- `math Mx`: proven or property-checked by `reference/verify_math.py`;
- `sim`: asserted after every step of `reference/verify_invariants.py` (random action sequences plus full
  settlement);
- `sol`: can only be checked against the Solidity implementation (access control, upgrades, oracle signatures,
  tokens). Listed in [TEST_CASES.md](TEST_CASES.md).

## 1. Positions and wrappers

| ID | Invariant | Verified |
|---|---|---|
| **INV-1** | Before a group is finalized, for every series: `totalInternalLong − totalInternalShort + wrapperSupply = 0`. | sim |
| **INV-2** | `totalInternalLong[s]` equals the sum of all positive balances in `s`, and `totalInternalShort[s]` the sum of all negative balances (absolute). | sim |
| **INV-3** | A wrapper is minted only together with an equal decrease of some internal balance (mint opens a short; wrap removes a long). | sim |
| **INV-4** | A wrapper is burned only together with an equal increase of an internal balance, or a redemption payout. Total supply equals the sum of all holders' balances. | sim |
| **INV-5** | A subaccount holds balances only in series whose settlement asset equals the subaccount's. | sol |
| **INV-6** | Every non-zero balance has `|balance| ≥ minPositionQty` and is a multiple of it. | sim |

## 2. Cash and custody

| ID | Invariant | Verified |
|---|---|---|
| **INV-7** | For every settlement asset: `token.balanceOf(OptionClearing) ≥ Σ account cash + Σ settlement pools` (equality, plus any unsolicited donations). | sim |
| **INV-8** | No account's cash is ever negative. | sim |
| **INV-9** | Fees, once debited, are never counted as any account's cash. `toInsurance + toTreasury + toKeeper = fee` exactly. | math M14, sim |
| **INV-10** | Treasury withdrawals never touch insurance, the keeper reserve, account cash or settlement pools. | sol |
| **INV-37** | Insurance balance and keeper reserve are never negative; rewards paid never exceed the keeper reserve. | sim (insurance), sol |

## 3. Pricing and margin math

| ID | Invariant | Verified |
|---|---|---|
| **INV-38** | Option prices satisfy: price ≥ intrinsic; call ≤ spot; put ≤ strike; put-call parity; call increasing and put decreasing in spot; both increasing in IV and time. | math M2, M3 |
| **INV-39** | The normal-CDF implementation error is ≤ 1e-7, and the resulting price error is ≤ `(spot + strike) × 1e-7`. | math M1, M3 |
| **INV-40** | Surface interpolation returns a total variance within the grid's range, exactly the node value at nodes, and non-decreasing in expiry for a fixed strike when the grid is. | math M4 |
| **INV-41** | Margin is homogeneous: scaling every position of an account by a factor `c` scales MM and the IM loss term by `c`. | math M8 |
| **INV-15** | Margin of different underlyings never offsets: `maxLoss(a) = Σ bucketLoss(b)`. | math M10 |
| **INV-16** | Stale-surface pricing never values a long higher, or a short lower, than fresh pricing at the same IV. | math M11 |
| **INV-14** | `MM ≤ IM` for every account at every time (guaranteed because IM's loss uses the union of both stress sets). | math M7, sim |

## 4. Account safety

| ID | Invariant | Verified |
|---|---|---|
| **INV-11** | After any risk-increasing action (mint, wrap, withdraw, moving a long out), the acting account is healthy: `equity ≥ IM`. | sim |
| **INV-12** | Risk-increasing actions succeed only with fresh spot and surface data for every affected product, on an enabled (not close-only) product, with insurance and keeper reserve at their minimums. | sim (freshness), sol |
| **INV-13** | Deposits, unwraps, closes with wrappers and receiving a long never lower an account's `equity − IM` or `equity − MM`. | math M6, sim |
| **INV-42** | A mint never pushes a series' total internal short above `maxOpenInterestPerSeries`, nor a product above `maxShortUnderlyingPerProduct`. | sol |
| **INV-43** | Position counts per account never exceed `maxSeriesPerAccount` / `maxBucketsPerAccount` through user actions (liquidators receiving slices are checked the same way and revert if over). | sol |
| **INV-44** | The seller fee is debited before the IM check and never exceeds `maxSellerFeeNative`; fee rates never exceed the hard caps. | math M14, sol |

## 5. Oracles

| ID | Invariant | Verified |
|---|---|---|
| **INV-17** | `surfaceSeq` per product strictly increases. No report is accepted twice or out of order. | sol |
| **INV-18** | A stored spot price is never replaced by an older one. | sol |
| **INV-19** | Only leaves proven against the accepted root are used for pricing. | sol |
| **INV-20** | Kuru (venue) prices are never an input to margin, liquidation or settlement. | sol (by construction) |
| **INV-45** | Liquidation uses fresh spot data and a surface no older than `maxSurfaceStale`. | sim (freshness), sol |

## 6. Liquidation

| ID | Invariant | Verified |
|---|---|---|
| **INV-21** | An auction can start only when `equity < MM`. A healthy or close-only account is never liquidated. | sim |
| **INV-22** | Every successful slice or wrapper liquidation strictly increases the liquidated account's `equity − MM`, by at least `sliceMM × (1 − bonus − penalty)` before rounding. A slice that would not improve it after rounding reverts (dust only). | math M9, M9b, sim |
| **INV-23** | After a slice, the liquidator account is healthy, and it is never the liquidated account. | sim |
| **INV-24** | Slice transfers never change the **net** internal balance of any series (so INV-1 is preserved), and never **increase** total internal short. It can fall when the liquidator already holds the opposite position and they net. | sim |
| **INV-25** | Insurance pays at most `maxInsurancePerLiquidation` per call and never more than its balance. | sim, sol |
| **INV-46** | Only unexpired legs are moved by liquidation; finalized legs are never auctioned. No slice may be taken once `equity ≥ IM × (1 + targetHealthBufferBps)`. | sim (unexpired legs), sol |

## 7. Settlement

| ID | Invariant | Verified |
|---|---|---|
| **INV-26** | A group's settlement price is written at most once and never changes. | sim |
| **INV-27** | `participants[g]` equals the number of accounts with a non-zero balance in any series of `g`, until settled. | sim |
| **INV-28** | Redemption, claims and the ratio computation are impossible before `participants[g] == 0`; redemption and claims also need the ratio set. | sim |
| **INV-47** | Settlement identity: at finalization, `Σ_accounts N_a + wrapperClaimN = 0` exactly, so net debts equal wrapper claims plus net credits. | math M12a, sim |
| **INV-30** | When every debtor pays in full (or insurance covers what they can't), `collected + insurance ≥ grossClaim` and the ratio is exactly 1. | math M12b, M12c, sim |
| **INV-29** | The recovery ratio is set once, is ≤ 1, and is the same for every wrapper holder and internal creditor in the group. | math M12d, sim |
| **INV-31** | `pool[g] = collected + insuranceContribution − payouts so far`, and it is never negative. Total payouts never exceed `collected + insuranceContribution`. | math M12d, sim |
| **INV-32** | Redemption order and splitting never change the payout per unit (beyond rounding down, which can only lower it). | math M13, sim |
| **INV-33** | After finalization, wrapper supply of a series only decreases, only through redemption, and reaches 0 when all holders redeem. | sim |
| **INV-48** | Each account is settled at most once per group, and each credit is claimed at most once. | sim |
| **INV-49** | Rounding always favors solvency: debts round up, credits, payouts and the ratio round down, fees round up. | math M14, M5e |

## 8. Venues and router

| ID | Invariant | Verified |
|---|---|---|
| **INV-50** | After every router or adapter call, router and adapter hold zero tokens; the buyer pays at most `maxPremium + maxBuyerFeeNative + maxVenueFeeNative` and receives an exact refund of the rest. | sol |
| **INV-51** | A market is registered only if its base is the series wrapper and its quote the series settlement asset, on the same chain. | sol |
| **INV-52** | A venue fill never changes Optara balances; only Optara entry points do. Venue balances never count as margin. | sol (by construction) |

## 9. Governance and upgrades

| ID | Invariant | Verified |
|---|---|---|
| **INV-34** | Series terms, wrapper addresses, finalized prices, recovery ratios and redemption records are identical before and after any upgrade. | sol |
| **INV-35** | No role can mint wrappers, move account cash or burn someone else's wrappers outside the defined functions. | sol |
| **INV-36** | Every loop is bounded by a configured limit; no function iterates over all accounts or all series. | sol (review + gas tests) |
| **INV-53** | The guardian can only reduce risk (pause, close-only, lower caps, remove publishers); every risk-increasing change and every upgrade goes through the timelock. | sol |

## 10. Liveness (not safety, but required)

| ID | Property | Verified |
|---|---|---|
| **LIV-1** | Deposits, unwraps and closes need no oracle data and no margin check, so they work during oracle outages (unless explicitly paused). | sim |
| **LIV-2** | Settlement always completes: any address can settle any participant, rewards escalate, and position minimums bound the participant count. | sim (completes every run) |
| **LIV-3** | Kuru being unavailable never blocks minting, transfers, unwrap, close, liquidation, settlement or redemption. | sim (no venue used), sol |

## 11. Executable verification

```bash
python3 reference/verify_math.py        # 24 checks: theorems, properties, every worked example in MATH.md
python3 reference/verify_invariants.py  # stateful simulation: random actions + full settlement, all sim invariants
python3 reference/check_traceability.py # every invariant here has at least one test in TEST_CASES.md Appendix A
```

Latest results:

- `verify_math.py`: 24/24 passed (seeds 7, 3, 99).
- `verify_invariants.py`: 400 runs × 200 steps, 0 violations. The runs included 424 liquidations, 208 groups settling
  with ratio < 1, and 992 with ratio = 1.
- `check_traceability.py`: all 56 invariants (and every function, error and event) mapped to defined tests.

The scripts verify the **specification**, not Solidity code. The same invariants must be re-checked against the
contracts with Foundry invariant tests ([TESTING.md](TESTING.md) §5), using these scripts as the reference model.

Problems the scripts found and fixed in the spec (see [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) C-7 to C-10):

1. A loss-based IM buffer broke INV-13.
2. Separate IM/MM sets broke INV-14.
3. INV-24 was stated too strongly (netting can reduce total short).
4. The shortfall example's payout is 649.999999, not 650, because of round-down.
