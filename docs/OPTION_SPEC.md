# Option Specification

What one Optara PM option series is.

## 1. Product

A **European, cash-settled, uncapped** call or put on an underlying, quoted, margined and paid in one approved
stablecoin (the settlement asset).

## 2. Series terms

Stored once in `OptionSeriesRegistry` and never changed.

```solidity
enum OptionType { CALL, PUT }

struct SeriesTerms {
    address underlying;            // e.g. WETH address used as the asset identifier
    address settlementAsset;       // e.g. USDC
    OptionType optionType;
    uint256 strikeWad;             // settlement asset per 1 underlying, WAD
    uint256 contractSizeWad;       // underlying units per 1 whole option, WAD
    uint64  expiry;                // unix seconds
    bytes32 settlementOracleConfigId; // precommitted expiry price rule (ORACLES.md §5)
    bytes32 volSurfaceProductId;   // surface product for pricing (ORACLES.md §3)
    bytes32 riskParameterSetId;    // margin parameters (PARAMETERS.md)
    address wrapper;               // ERC-20 long token, set at creation
}
```

There is **no cap field**. A series is not valid without a wrapper.

## 3. Payoff

At expiry, with final settlement price `S*` (settlement asset per underlying):

```text
CALL payoff per option = max(S* − K, 0) × CS
PUT  payoff per option = max(K − S*, 0) × CS
```

| Holder | Receives / pays |
|---|---|
| Long (internal or wrapper) | Receives payoff × quantity × recovery ratio |
| Short (internal) | Pays payoff × quantity |

A put pays at most `K × CS`. A call has no maximum.

## 4. Units

| Field | Unit | Example |
|---|---|---|
| `strikeWad` | WAD | 4,500 USDC → `4500e18` |
| `contractSizeWad` | WAD | 1 ETH → `1e18`; 0.1 ETH → `1e17` |
| Quantities, balances, wrapper amounts | 18 decimals | 1 option → `1e18` |
| Cash, fees, payouts | Native units of the settlement asset | 1 USDC → `1_000_000` |

Settlement assets must have 0–18 decimals.

## 5. Identity

```text
SERIES_DOMAIN = keccak256(abi.encode(keccak256("Optara.PM.Series"), chainId, registryAddress, 1))

seriesId  = keccak256(abi.encode(SERIES_DOMAIN,
                underlying, settlementAsset, optionType, strikeWad, contractSizeWad, expiry,
                settlementOracleConfigId, volSurfaceProductId))

groupId   = keccak256(abi.encode(keccak256("Optara.PM.Group"), underlying, settlementAsset, expiry,
                settlementOracleConfigId))

productId = keccak256(abi.encode(keccak256("Optara.PM.Product"), underlying, settlementAsset))
```

- `riskParameterSetId` is **not** part of the identity: it is a margin setting, not an economic term. It is still
  stored with the series and cannot change for that series.
- Creating a series whose `seriesId` already exists reverts (`SeriesExists`).
- `seriesId` binds the chain and the registry, so the same terms on another deployment are a different series.
  `groupId` and `productId` are internal keys; the surface reports that use `productId` already bind the chain and
  the oracle contract.
- All series in a group share one settlement price and settle together.

## 6. Creation rules

`OptionSeriesRegistry.createSeries(terms)` (role `SERIES_CREATOR`) reverts unless:

| Check | Rule |
|---|---|
| Product enabled | `(underlying, settlementAsset)` is an approved, enabled product; settlement asset approved |
| Pause | `SERIES_CREATE` not paused (global, asset or product) |
| Strike | `minStrike ≤ strikeWad ≤ maxStrike` for the product, and `> 0` |
| Contract size | `> 0` and within product bounds |
| Expiry | `now + minTimeToExpiry ≤ expiry ≤ now + maxTimeToExpiry` |
| Settlement oracle | Config exists, is approved, and matches underlying + settlement asset |
| Vol product | Matches `productId` |
| Risk set | Exists and is enabled |
| Uniqueness | `seriesId` not used before |
| Group size | The group has fewer than 256 series ([MATH.md](MATH.md) §14) |

Surface tenor coverage is **not** checked at creation (publishers add the tenor after listing). A series whose
expiry lies outside the current surface's tenors is simply unpriceable: minting it reverts `SeriesNotPriceable`.

On success: deploy the wrapper via `ExternalOptionFactory` (clone at `predictWrapper(seriesId)`), store terms,
emit `SeriesCreated(seriesId, groupId, wrapper, terms)`.

## 7. Wrapper token (`ExternalOptionWrapper`)

| Property | Value |
|---|---|
| Standard | ERC-20 (with EIP-2612 permit) |
| Decimals | 18 |
| Name | `Optara ETH/USDC 4500C 2026-12-25` |
| Symbol | `oETH-USDC-4500C-261225` |
| `seriesId()` | Returns its series |
| Mint | Only `OptionClearing` |
| Burn | Only `OptionClearing` (unwrap, close), `SettlementWindow` (redeem) and `LiquidationModule` (wrapper-burn liquidation), only from the account whose own call asked for it |
| Permit | EIP-2612; EIP-712 domain name = the wrapper name, version "1" |
| Transfer tax, rebasing, hooks, pausing | None |
| Upgradeable | No (immutable clone) |

Name and symbol are display only. Integrations must identify a series by `seriesId` and its stored terms.

## 8. Internal positions

A subaccount holds a signed balance per series: `balance[accountId][seriesId]`, an `int256` with 18 decimals.

- `> 0` long, `< 0` short, `0` none.
- Longs and shorts of the **same series** in one account always net (they are one number).
- An account may hold different series of the same group long and short (e.g. a spread).

Per-series totals kept in O(1):

```text
totalInternalLong[seriesId]  = sum of positive balances
totalInternalShort[seriesId] = sum of |negative balances|
```

Before finalization, always: `totalInternalLong − totalInternalShort + wrapperSupply = 0` (INV-1).

## 9. Lifecycle of a series

```text
ACTIVE --(now ≥ expiry)--> EXPIRED --(finalizeGroup)--> FINALIZED
   --(all participants settled)--> SETTLED --(recovery ratio set)--> REDEEMABLE
```

Details per state are in [STATE_MACHINE.md](STATE_MACHINE.md).

## 10. Examples

| Series | Terms | Payoff at S* |
|---|---|---|
| ETH/USDC 4,500 call, CS 1 | K = 4,500 | S* = 5,200 → 700 USDC per option |
| ETH/USDC 4,500 call, CS 1 | K = 4,500 | S* = 4,100 → 0 |
| ETH/USDC 3,500 put, CS 1 | K = 3,500 | S* = 3,000 → 500 USDC |
| MON/USDT 4 call, CS 100 | K = 4 | S* = 5 → (5−4)×100 = 100 USDT |
