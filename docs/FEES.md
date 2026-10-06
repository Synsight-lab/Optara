# Fees

Optara PM ships with fee code from day one. Formulas: [MATH.md](MATH.md) §11. Rates:
[PARAMETERS.md](PARAMETERS.md) §6.

## 1. Fee types

| Fee | Paid by | When | Base | Goes to |
|---|---|---|---|---|
| **Seller (open) fee** | Writer | `mintExternalLong` | Mark value of the minted options | Split (§3) |
| **Buyer (acquisition) fee** | Buyer | Buying through `VenueRouter` | Executed premium | Split (§3) |
| **Liquidation penalty** | Liquidated account | Each slice or wrapper liquidation | Slice MM | 100% insurance |
| **Venue fee** (e.g. Kuru) | Trader | On the venue | Venue's own rule | The venue, **not** Optara |
| **Oracle update fee** (e.g. Pyth) | Whoever submits data | In the transaction | Provider's rule | The provider |

Venue and oracle fees are external and never enter Optara accounting.

## 2. Seller fee

```text
mintExternalLong(accountId, seriesId, qty, recipient, maxSellerFeeNative, update)

sellerFee = max(ceil(markValue(qty) × sellerOpenFeeBps / 10_000), minSellerFeeNative)
```

Order of operations (must be exactly this):

1. Verify fresh spot and surface.
2. Simulate the new short.
3. Compute the fee; `require(fee ≤ maxSellerFeeNative)`.
4. Debit the fee from the account's cash and split it.
5. Require `equity ≥ IM` **after** the fee.
6. Mint the wrappers.

Because the fee leaves before the IM check, it can never use up required margin.

Example: minting 10 × ETH 4,500 calls marked at 106.77 USDC each, at 300 bps → 1,067.70 × 3% = **32.04 USDC**.

## 3. Fee split

Every seller and buyer fee is split:

| Destination | Share | Use |
|---|---|---|
| `InsuranceFund` | 60% | Covers bad debt |
| Treasury (`FeeController`) | 30% | Protocol revenue; withdrawable by governance |
| Keeper reserve (`FeeController`) | 10% | Pays settlement and finalization rewards |

The treasury share takes the rounding remainder, so the parts always add up to the fee. Fees are never counted as
any user's collateral after debit.

## 4. Buyer fee

```text
buyThroughVenue(adapterId, seriesId, qty, maxPremium, maxBuyerFeeNative, maxVenueFeeNative, recipient, deadline, adapterData)

buyerFee = ceil(executedPremium × buyerTradeFeeBps / 10_000)
```

1. The router pulls `maxPremium + maxBuyerFeeNative + maxVenueFeeNative` from the buyer.
2. The adapter executes the trade.
3. The router computes the fee from the **actual** premium paid and requires `fee ≤ maxBuyerFeeNative`.
4. The fee is collected, the wrappers go to the recipient, and unused funds are refunded.
5. The whole call reverts if any limit is exceeded or `now > deadline`.

**Limitation:** Optara can't charge a buyer fee on direct Kuru trades or plain ERC-20 transfers without making the
wrapper non-standard. The buyer fee applies only to the official router. The frontend routes through it by default;
direct trading stays possible for composability.

There is no Optara fee on selling through the router: the seller already paid at mint.

## 5. Keeper rewards

Paid from the keeper reserve of the settlement asset:

| Action | Reward |
|---|---|
| `finalizeGroup` | `finalizeRewardNative` |
| `settleAccountGroup` | `settleRewardNative × min(10_000 + 2_500 × fullHoursSinceFinalization, 40_000) / 10_000` |

The reward paid is `min(reward, keeperReserve)` (INV-37): a part-empty reserve pays what it has, and an empty
reserve pays zero. A zero keeper address receives nothing. Anyone can top up the reserve with
`fundKeeperReserve(asset, amount)` (exact transfer; fee-on-transfer tokens revert); it credits no account.

If the reserve is empty, rewards drop to zero. Settlement still has to complete before redemption opens; anyone,
including holders, can call it for free.

## 6. Insurance seed gating

New risk in a settlement asset is blocked until:

```text
InsuranceFund.balance(asset) ≥ minimumInsuranceSeed[asset]
FeeController.keeperReserve(asset) ≥ minimumKeeperReserve[asset]
```

Seed capital can come from governance deposits, grants or a treasury transfer. If either balance falls below its
minimum, every product in that asset goes close-only until it is topped up (`PortfolioRiskManager` reads
`FeeController.reservesHealthy(asset)`).

`setMinimums(asset, insuranceSeed, keeperMin)`: raising both (or leaving one unchanged) is instant for the risk
admin, guardian or governance, because it only blocks risk. Lowering **either** needs governance (timelocked).

## 7. Treasury withdrawals

- Governance only, behind the parameter timelock.
- Only from the treasury balance. Never from insurance, the keeper reserve, user cash or settlement pools.
- Emits `TreasuryWithdrawn(asset, amount, to)`.

## 8. Fee rules (must hold)

| Rule | Why |
|---|---|
| Every fee has a user-set maximum | Fee changes between quote and execution can't surprise users |
| Fees are in the series settlement asset | No cross-asset conversion |
| Seller fee is charged before the IM check | Fees never consume margin |
| Fee rates ≤ hard caps (1,000 bps) | Governance can't set extreme fees |
| Optara and venue fees are shown separately | Users see who charges what |
| Recorded balances never exceed tokens held | No unbacked credit (§9) |

## 9. Custody: push, then notify

`FeeController` holds the treasury and keeper-reserve tokens; `InsuranceFund` holds the insurance tokens. Tokens
arrive in one of two ways:

| Path | Who | Check |
|---|---|---|
| Pull | Anyone: `InsuranceFund.deposit`, `FeeController.fundKeeperReserve` | Exact amount received, else `NonExactTransfer` |
| Push, then notify | `OptionClearing` → `notifySellerFee`; `VenueRouter` → `notifyBuyerFee`; `FeeController` / `OptionClearing` → `InsuranceFund.notifyDeposit` | `held ≥ recorded + amount`, else `TokensNotReceived` |

The caller transfers first and notifies in the same transaction. Because every credit checks the tokens are
present, the recorded total never exceeds what the contract holds; any surplus (a stray transfer) stays unrecorded
and cannot be withdrawn. `notifySellerFee` is callable only by `OptionClearing` and `notifyBuyerFee` only by
`VenueRouter`, so a third party cannot claim someone else's pushed tokens. See DESIGN_DECISIONS.md DD-29.

`InsuranceFund.cover(asset, amount)` (only `LiquidationModule` or `SettlementWindow`) pays `min(amount, balance)`
and always to `OptionClearing` custody, never to the caller.
