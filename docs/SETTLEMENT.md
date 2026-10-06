# Settlement

How a settlement group goes from expiry to paid-out claims, without a first-come-first-served race. Formulas:
[MATH.md](MATH.md) §13.

## 1. Why there is a settlement window

Shorts are leveraged, so some may be underwater at expiry. If holders could redeem the moment the price is final,
early redeemers would be paid in full and late ones could find the pool empty. Instead:

1. Fix the price.
2. Settle **every** account that has positions in the group.
3. Cover any shortfall from insurance.
4. Fix **one** recovery ratio for everyone.
5. Only then open redemption.

## 2. Group lifecycle

```text
ACTIVE ──(now ≥ expiry)──> EXPIRED
EXPIRED ──(finalizeGroup)──> FINALIZED            // price fixed, redemption closed, settlement window open
EXPIRED ──(now ≥ expiry + maxFinalizationDelay)──> flagged ORACLE_STALLED (still finalizable later)
FINALIZED ──(participants == 0)──> ALL_SETTLED
ALL_SETTLED ──(computeRecoveryRatio)──> REDEEMABLE // ratio fixed, redemption and claims open
```

## 3. What changes at expiry

| Action on the group's series | Before expiry | Expired, not finalized | Finalized |
|---|---|---|---|
| `mintExternalLong`, `wrapLong` | Allowed (if healthy) | Blocked | Blocked |
| `unwrapLong` | Allowed | Blocked | Blocked |
| `closeShortWithWrapper` | Allowed | **Allowed** (cancels short against wrapper) | Blocked |
| `closeShortWithInternalLong` | Allowed | Allowed | Blocked |
| Wrapper transfers | Allowed | Allowed | Allowed |
| `redeemWrapper` | — | — | Only when REDEEMABLE |

## 4. Finalization

```solidity
function finalizeGroup(bytes32 groupId, bytes calldata settlementData) external;
```

- Permissionless. Pays `finalizeRewardNative` from the keeper reserve.
- `SettlementOracle` verifies the round-in-force proof ([ORACLES.md](ORACLES.md) §5).
- Stores `settlementPrice[groupId]` once. It can never change.
- Snapshots `wrapperSupplyAtFinalization[seriesId]` for every series in the group. Wrapper supply can only fall
  after this, through redemption.
- Emits `GroupFinalized(groupId, priceWad, observationTimestamp, participants)`.

## 5. The participant counter

`participants[groupId]` counts subaccounts that hold a non-zero balance in **any** series of the group. It's
maintained in O(1) using a per-(account, group) count of non-zero series:

```text
when balance[a][s] changes from 0 to non-zero:   seriesCount[a][g] += 1; if it became 1: participants[g] += 1
when balance[a][s] changes from non-zero to 0:   seriesCount[a][g] -= 1; if it became 0: participants[g] -= 1
```

Every ledger write goes through one function, `SubAccounts.applyDelta`, that applies this rule: mint, wrap, unwrap,
close, transfer, liquidation, settle. Settling an account zeroes its balances in the group through the same function,
which is what decrements `participants` (STATE_MACHINE.md §6).

Creditors are counted too, not just debtors, because whether an account owes or is owed depends on the price, which is
unknown until finalization.

## 6. Settling accounts

```solidity
function settleAccountGroup(uint256 accountId, bytes32 groupId) external;
```

- Permissionless; any keeper may call it for any account.
- Requires the group to be finalized and the account to be a participant.
- Nets **all** of the account's series in the group into one signed amount `N_a` ([MATH.md](MATH.md) §13).
  - **Debt** (`N_a < 0`): collected from the account's cash up to what's available and moved into the group's pool
    immediately. Any unpaid part is added to the group's deficit.
  - **Credit** (`N_a > 0`): recorded as a claim, paid later at the recovery ratio.
- Zeroes every balance of the account in the group and decrements `participants`.
- Pays the caller `settleReward` from the keeper reserve. The reward escalates per hour since finalization, so
  settlement always completes.
- Emits `AccountSettled(accountId, groupId, netNumerator, collected, unpaid)`.

Credits are **not** counted as equity or made withdrawable until the ratio is fixed and the account claims them.

## 7. Recovery ratio

```solidity
function computeRecoveryRatio(bytes32 groupId) external;
```

Callable once, only when `participants[groupId] == 0`:

1. `grossClaim` = wrapper claims (from the finalization snapshot) + net credit claims. Only **netted** claims count
   ([MATH.md](MATH.md) §13.1).
2. `shortfall = grossClaim − collected`.
3. `InsuranceFund.cover(asset, shortfall)` moves up to that amount into the group's pool.
4. `ratio = min(1, (collected + insurance) / grossClaim)`, rounded down, stored forever.
5. Emits `RecoveryRatioSet(groupId, ratioWad, grossClaim, collected, insuranceContribution)`.

The group is now REDEEMABLE. With everyone solvent, the ratio is exactly 1.

## 8. Paying out

| Who | Call | Receives |
|---|---|---|
| Wrapper holder | `redeemWrapper(seriesId, qty, recipient)` | Burns `qty`, receives `floor(qty × payoff × ratio)` in the settlement asset |
| Internal creditor | `claimSettlement(accountId, groupId)` | Credit × ratio added to the account's cash |

- Redemption is permissionless for any token holder. Order never matters: everyone gets the same ratio.
- Zero-payoff wrappers can be redeemed (burned) for 0.
- Unredeemed wrappers stay redeemable forever. No deadline.
- After every wrapper is redeemed and every credit claimed, leftover rounding dust may be swept to the insurance
  fund.

## 9. Pool accounting

```text
pool[groupId] = collected + insuranceContribution − Σ payouts so far
invariant:      pool ≥ Σ remaining payouts at the fixed ratio       (INV-6)
```

The pool's stablecoins stay in `OptionClearing` custody, tracked separately from account cash.

## 10. Example

ETH 4,500 call `X` and 5,000 call `Y`, `S* = 5,200`:

| Party | Position | Net |
|---|---|---|
| Account A | short 1 X, internal long 1 Y | −700 + 200 = −500 (debt) |
| Account B | short 1 Y | −200 (debt) |
| Wallet W | 1 X wrapper | claim 700 |

Collected = 700 and grossClaim = 700, so ratio = 1. W redeems 700.

If B had only 50 USDC: collected = 550, shortfall = 150. With 100 from insurance: ratio = 650/700 = 0.9286, and W
receives 649.999999 (the ratio and payout round down; the 1 micro-USDC of dust is later swept to insurance).

## 11. Oracle failure

If the price never arrives: the group stays `EXPIRED` and is flagged `ORACLE_STALLED` after the deadline. Positions
remain reserved; closes with wrappers stay open; nothing is redeemed. A late authentic round can still finalize. No
current-spot or invented price is ever used. See [ORACLES.md](ORACLES.md) §5.3.
