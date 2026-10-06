# Product Requirements — Optara PM

## 1. Summary

Optara PM lets anyone write and trade **standard, uncapped European calls and puts** on Monad with **portfolio
margin**. Writers post margin sized by stress tests instead of the full worst case, so they can sell options with
far less capital than a fully collateralized system. Long claims are ERC-20 tokens that trade on Kuru and any other
venue. Optara never runs a matching engine: venues trade, Optara clears.

## 2. Problem

| Today (capped V2) | Problem |
|---|---|
| Every option has a maximum payout (a "cap") | Buyers don't get a standard option; calls stop paying above the cap |
| Writers lock the exact worst-case loss | Capital-inefficient: a call worth ~107 USDC needed up to its full cap in collateral |
| Premium received on Kuru is not margin | Writers must move money back manually |

Traders expect options that behave like those on Deribit or Binance: uncapped payoff, portfolio margin,
liquidation if margin runs low.

## 3. Goals

| ID | Goal |
|---|---|
| G1 | Standard payoffs: calls `max(S−K,0)`, puts `max(K−S,0)`, no caps. |
| G2 | Portfolio margin: one account's shorts and longs on the same underlying offset each other. |
| G3 | Long claims are standard ERC-20 tokens tradable on any venue. |
| G4 | Kuru is the first venue, plugged in through an adapter. The protocol works without it. |
| G5 | Permissionless liquidation with no centralized matching engine. |
| G6 | Losses beyond collateral are absorbed by an insurance fund first, then shared equally by all long holders of the affected group. |
| G7 | Protocol fees fund the insurance fund, keepers and treasury. |
| G8 | Upgradeable contracts with timelocks, while series terms and finalized results can never be rewritten. |

## 4. Non-goals (v1)

- No centralized or in-house order matching (an adapter slot exists for later).
- No spot or perpetual positions, and no delta offsets from them.
- No collateral other than the subaccount's single settlement stablecoin.
- No cross-stablecoin margin.
- No American (early) exercise.
- No offsets between different underlyings (each underlying is margined separately and the results are added).
- No margin credit for anything held outside Optara (Kuru balances, wallet tokens).

## 5. Users

| User | What they do | What they need |
|---|---|---|
| **Writer** | Deposits stablecoin, mints wrappers, sells them | Low margin, clear liquidation risk, fee preview |
| **Buyer** | Buys wrappers on Kuru, holds or redeems | Full payoff, honest disclosure of recovery-ratio risk |
| **Market maker** | Writes and buys many series, runs spreads | Portfolio offsets, unwrap/wrap, predictable margin |
| **Liquidator** | Takes over unhealthy positions for a reward | Clear auction rules, capital efficiency for taken positions |
| **Keeper** | Finalizes groups, settles accounts, submits oracle data | Small rewards, deterministic calls |
| **Surface publisher** | Computes and signs IV surfaces | Clear schema, quorum rules |
| **Governance / guardian** | Lists series, sets parameters, pauses | Timelocks, limited emergency powers |

## 6. Functional requirements

### Accounts and collateral
- FR-1 A user can create any number of subaccounts. Each is bound to one settlement asset at creation.
- FR-2 Owners can approve operators who may act for the subaccount (except changing operators).
- FR-3 Deposit is always allowed for approved assets. Withdraw is allowed only if the account stays healthy (equity ≥ IM) with fresh oracle data.

### Series
- FR-4 Authorized creators list series with: underlying, settlement asset, type, strike, contract size, expiry, settlement oracle config, volatility product, risk parameter set.
- FR-5 Series terms can never change after creation.
- FR-6 Each series gets exactly one wrapper token, deployed at creation.

### Writing and wrapping
- FR-7 `mintExternalLong` creates a short of `qty` and mints `qty` wrapper tokens, charging the seller fee, only if the account stays healthy afterwards.
- FR-8 `unwrapLong` turns wrappers into an internal long. It is always allowed before expiry.
- FR-9 `wrapLong` turns an internal long into wrappers if the account stays healthy afterwards.
- FR-10 `closeShortWithWrapper` burns wrappers to reduce a short. Always allowed until the group is finalized.
- FR-11 `closeShortWithInternalLong` moves a long from one of the caller's subaccounts to another to cancel a short.

### Margin
- FR-12 Every option is priced on-chain with Black-76 from live spot and a signed IV surface.
- FR-13 IM and MM come from stress scenarios defined in a risk parameter set.
- FR-14 Stale spot or surface data blocks risk-increasing actions. Risk-reducing actions never need oracle data.
- FR-15 Stale data is applied conservatively by direction: shorts at higher IV, longs at lower IV or intrinsic only.

### Trading
- FR-16 Writers and buyers may trade wrappers on any venue. Optara never needs to know.
- FR-17 Optara's `VenueRouter` offers buy and sell routes through registered adapters, with premium, fee and deadline limits, and charges the buyer fee on buys.
- FR-18 `KuruAdapter` is the first adapter. Disabling it breaks nothing in clearing or settlement.

### Liquidation
- FR-19 Anyone can start an auction on a risk bucket below MM and take slices through a Dutch auction.
- FR-20 Liquidators fund the margin of what they take with their own subaccount.
- FR-21 Liquidators may instead burn wrappers to close the account's shorts.
- FR-22 Liquidation always improves the liquidated account's health.

### Settlement
- FR-23 After expiry, anyone can finalize a group with the precommitted settlement oracle data. One price per group.
- FR-24 Keepers settle every account with positions in the group. Redemption stays closed until all are settled.
- FR-25 The insurance fund covers shortfalls. The remaining shortfall sets one recovery ratio per group.
- FR-26 Wrapper holders redeem at `payoff × recoveryRatio`. Internal creditors claim the same ratio.
- FR-27 A missing settlement price flags the group `ORACLE_STALLED`. No invented prices.

### Fees and insurance
- FR-28 Seller fee on minting, buyer fee on router buys, both with user-set maximums.
- FR-29 Fees split into insurance, treasury and keeper reserve.
- FR-30 New risk is blocked for an asset until its insurance fund and keeper reserve reach their minimums.

### Governance
- FR-31 All core contracts are upgradeable behind a timelock. A guardian can pause and set close-only instantly.
- FR-32 No upgrade or admin action can change series terms, finalized prices or recovery ratios.

## 7. Acceptance criteria (v1 is done when)

1. A writer can deposit USDC, mint ETH call wrappers and sell them on Kuru through the router.
2. A buyer can buy through the router, see both fees, unwrap, and redeem after settlement.
3. A short call + long higher-strike call needs less margin than the short alone (the spread example in [MATH.md](MATH.md) §11).
4. Stale spot or surface data blocks minting, wrapping and withdrawals, but not deposits, unwraps or closes.
5. A liquidator can take slices of an unhealthy account; each slice improves its health.
6. A group finalizes once; all accounts settle; the recovery ratio is 1 when everyone is solvent and the same for all holders when not.
7. Redemption order never changes anyone's payout percentage.
8. Kuru disabled: minting, transfer, unwrap, close, settle and redeem all still work.
9. All invariants in [INVARIANTS.md](INVARIANTS.md) pass stateful fuzzing.
10. Gas for a risk check at the maximum allowed positions fits the target in [PARAMETERS.md](PARAMETERS.md).
11. An upgrade cannot change any series term, finalized price or recovery ratio (tested).
12. Every contract has unit, fuzz, invariant and E2E tests that pass ([TESTING.md](TESTING.md) §0), and
    `reference/check_traceability.py` passes.

## 8. Success metrics after launch

- Zero bad debt reaching the recovery ratio in normal market conditions.
- Insurance fund grows from fees faster than it pays out.
- Liquidation auctions clear within their duration.
- Surface publisher uptime ≥ the target in [PARAMETERS.md](PARAMETERS.md).

## 9. Risks users must be told about

- **Writers** can be liquidated if the market moves against them. Liquidation costs a discount and a penalty.
- **Buyers** can receive less than 100% of the payoff if bad debt exceeds the insurance fund.
- **Everyone** depends on oracle and publisher uptime; if they fail, new risk stops.
- **Everyone** trusts governance: contracts are upgradeable behind a timelock.
- **MON** volatility is synthetic at launch (no liquid MON options market exists to derive it from).
