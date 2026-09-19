# State Machine

## Purpose

This file defines legal state transitions for each option series.

## States

V1 uses a minimal explicit state:

```solidity
enum SeriesState {
    ACTIVE,
    SETTLED
}
```

Expiry is derived:

```text
isExpired = block.timestamp >= expiry
```

Pause flags are separate controls and must not be confused with economic state.

## Lifecycle

```text
CREATED
  -> ACTIVE
      -> expired by time
          -> SETTLED
              -> redemptions and writer residual claims
```

`CREATED` is not an onchain state in the vault. A newly deployed vault starts as `ACTIVE`.

## Function Permissions by State

| Function | Before Expiry | At/After Expiry Before Settlement | After Settlement |
|---|---:|---:|---:|
| `mint` | allowed | revert | revert |
| ERC-20 transfer | allowed | allowed unless paused | allowed unless paused |
| `settle` | revert | allowed | revert or return stored result |
| `redeem` | revert | revert | allowed |
| `claimWriterResidual` | revert | revert | allowed |
| `linkKuruMarket` | allowed if not linked | allowed with warning | allowed metadata only |
| `sweepFees` | allowed, fee admin | allowed, fee admin | allowed, fee admin |
| `sweepDust` | revert | revert | allowed once fully wound down |

Recommended behavior for repeated `settle`: revert with `AlreadySettled`.

## Mint Transition

Preconditions:

```text
state == ACTIVE
block.timestamp < expiry
VaultPause.MINT not set
optionAmount >= minOptionAmount
requiredCollateral(optionAmount) > 0
maxTotalShortAmount == 0 or totalShortAmount + optionAmount <= maxTotalShortAmount
```

Effects:

```text
writerShortBalance[writer] += optionAmount
totalShortAmount += optionAmount
totalUnclaimedShortAmount += optionAmount
collateralLocked += requiredCollateral
accruedFees += mintFee
mint optionAmount to receiver
```

Postconditions:

```text
totalSupply == totalShortAmount
collateralLocked >= requiredCollateral(totalShortAmount)
vaultBalance >= collateralLocked + accruedFees
```

## Settlement Transition

Preconditions:

```text
state == ACTIVE
block.timestamp >= expiry
VaultPause.SETTLEMENT not set
anchor proof identifies the first observation at or after expiry
that observation is within expiry + maxSettlementLag
oracle quorum passes on the anchored observation
```

There is no upper bound on *when* `settle()` may be called. The anchor pins the price to expiry, so a late call produces the same result as an early one.

Effects:

```text
settlementResult.settled = true
settlementResult.settlementPrice = finalPrice
settlementResult.buyerPayoutRate = calculatedBuyerRate
settlementResult.writerResidualRate = calculatedResidualRate
settlementResult.settledAt = block.timestamp
state = SETTLED
```

Postconditions:

```text
buyerPayoutRate + writerResidualRate <= collateralPerOption
settlement result cannot change
```

## Redemption Transition

Preconditions:

```text
state == SETTLED
optionAmount > 0
holder balance >= optionAmount
```

Effects:

```text
grossPayout = floor(optionAmount * buyerPayoutRate / OPTION_SCALE)
exerciseFee = floor(grossPayout * exerciseFeeBps / BPS_SCALE)
netPayout   = grossPayout - exerciseFee

burn optionAmount from holder
collateralLocked -= grossPayout
accruedFees += exerciseFee
totalBuyerPayoutClaimed += grossPayout
transfer netPayout to receiver
```

Collateral decreases by the gross amount while only the net leaves the vault. Rate definitions are normative in [math-of-core-invariants.md](./math-of-core-invariants.md); fee arithmetic is in [fee-spec.md](./fee-spec.md).

Postconditions:

```text
holder cannot redeem same tokens again
remaining collateral >= writer residual obligations
vaultBalance >= collateralLocked + accruedFees
```

## Writer Residual Claim Transition

Preconditions:

```text
state == SETTLED
shortAmount > 0
writerShortBalance[writer] >= shortAmount
```

Effects:

```text
grossResidual = floor(shortAmount * writerResidualRate / OPTION_SCALE)
residualFee   = floor(grossResidual * residualFeeBps / BPS_SCALE)   // 0 by V1 default
netResidual   = grossResidual - residualFee

writerShortBalance[writer] -= shortAmount
totalUnclaimedShortAmount -= shortAmount
collateralLocked -= grossResidual
accruedFees += residualFee
totalWriterResidualClaimed += grossResidual
transfer netResidual to receiver
```

Postconditions:

```text
writer cannot claim same short amount again
buyer claims remain solvent
vaultBalance >= collateralLocked + accruedFees
```

## Fee and Dust Sweep Transitions

### `sweepFees`

Preconditions:

```text
caller has FEE_ADMIN_ROLE
accruedFees > 0
```

Allowed in any state, including `ACTIVE`. Accrued fees are not collateral, so there is no reason to trap them until settlement.

Effects:

```text
amount = accruedFees
accruedFees = 0
transfer amount to ProtocolConfig.feeRecipient()
```

### `sweepDust`

Preconditions:

```text
caller has DEFAULT_ADMIN_ROLE
state == SETTLED
totalSupply() == 0
totalUnclaimedShortAmount == 0
```

Only reachable once every claim against the series is exhausted, at which point the remaining balance is provably unclaimable. See Invariant 5A in [math-of-core-invariants.md](./math-of-core-invariants.md).

## Oracle Failure State

V1 should not write a separate `ORACLE_FAILED` state. If oracle quorum fails:

```text
settle reverts
state remains ACTIVE
mint remains unavailable because block.timestamp >= expiry
redeem remains unavailable
writer residual claim remains unavailable
```

Frontend status may show `Awaiting valid oracle settlement`.

A series can also reach this state permanently if no oracle observation exists inside `expiry + maxSettlementLag` — for example if the feed stopped updating across expiry. The anchor cannot then be proven and no later observation qualifies, so `settle` reverts forever.

Emergency recovery for prolonged oracle failure is a governance process and must be explicitly decided before launch. See FD-20 and FD-21 in [founder-decisions.md](./founder-decisions.md).

## Pause Model

Pause flags live on the contract that performs the action. A vault does not hold a Kuru-linking flag, because it does not perform Kuru linking.

```text
OptionSeriesVault        VaultPause.MINT
                         VaultPause.SETTLEMENT
                         VaultPause.REDEMPTION
                         VaultPause.TRANSFER
SeriesRegistry           kuruLinkPaused
PremiumExecutionGuard    routingPaused
```

Pause flags are not economic state. A paused series is still `ACTIVE` or `SETTLED`; the flag only gates entry points.

Recommended V1 defaults:

- `PAUSER_ROLE` can pause minting, Kuru linking, and premium routing quickly.
- Settlement pause requires a higher-trust role or timelock unless there is an active exploit.
- Redemption pause is the highest-trust emergency action, because it blocks users from claiming collateral they are already owed.
- Transfer pause is discouraged for ERC-20 composability. It would also strand option tokens resting in Kuru orders. Avoid unless needed for compliance or an active exploit.
- Transfer pause gates holder-to-holder transfers only. It must never block mint or burn, or it would silently become a redemption pause held by a lower-trust role. See [implementation-spec.md](./implementation-spec.md).
- `sweepFees` is never gated by a pause flag, since it moves no collateral.

## Prohibited Transitions

V1 must never allow:

- `SETTLED -> ACTIVE`.
- Changing `settlementPrice`.
- Changing `buyerPayoutRate` or `writerResidualRate` after settlement.
- Changing any fee rate after series creation.
- Minting after expiry.
- Redeeming before settlement.
- Claiming writer residual before settlement.
- Withdrawing collateral before settlement.
- Any fee or dust sweep that reduces `collateralLocked` while claims remain outstanding.
- Reducing writer short balance without burning options or settling residual claim.
- Increasing option supply without increasing collateral and writer short accounting.

