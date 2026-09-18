# Storage Layout

## Purpose

This file defines the intended storage model. It is written so an AI agent can implement contracts without inventing hidden state.

V1 series vaults should be non-upgradeable. Storage layout still matters for auditability and deterministic reasoning.

## `SeriesRegistry`

```solidity
contract SeriesRegistry {
    address public factory;
    bool public kuruLinkPaused;

    // The vault IS the option token. One address per series, not two.
    mapping(bytes32 => address) private _vaultBySeriesId;
    mapping(address => bytes32) private _seriesIdByVault;
    mapping(bytes32 => SeriesParams) private _seriesParams;
    mapping(bytes32 => KuruMarketConfig) private _kuruMarketBySeriesId;
    mapping(bytes32 => bool) private _seriesExists;
}
```

Rules:

- `_seriesParams[seriesId]` is write-once.
- `_vaultBySeriesId` and `_seriesIdByVault` are inverse views of the same address. There is no separate option-token mapping, because `OptionSeriesVault` is itself the ERC-20.
- `isOptionToken(token)` resolves through `_seriesIdByVault`.
- `_kuruMarketBySeriesId[seriesId]` may be unset at creation and linked later.
- Kuru market updates must be append-only unless an explicitly reviewed migration process exists.

## `OptionSeriesFactory`

```solidity
contract OptionSeriesFactory {
    SeriesRegistry public registry;
    ProtocolConfig public config;
    address public vaultImplementationTemplate; // only if using clones

    mapping(bytes32 => bool) public created;
}
```

Rules:

- If clones are used, clone initialization must be single-use.
- If direct deployment is used, no implementation template is needed.
- Factory must not store mutable per-series economic parameters outside registry.

## `OptionSeriesVault`

Immutable or initialization-only fields:

```solidity
bytes32 public seriesId;
OptionType public optionType;
address public underlying;
address public quote;
address public collateralAsset;
uint256 public strikePrice;
uint64 public expiry;
uint256 public contractSize;
uint8 public optionDecimals;
uint256 public minOptionAmount;
OracleConfig public oracleConfig;
address public registry;
address public oracleRouter;
address public protocolConfig;

// Derived once at creation, never recomputed. See math-of-core-invariants.md.
uint256 public optionScale;          // 10 ** optionDecimals
uint256 public uqScale;              // PRICE_SCALE * 10**underlyingDec / 10**quoteDec
uint256 public collateralPerOption;  // C for CALL, ceilDiv(C*K, uqScale) for PUT

// Snapshotted from ProtocolConfig at creation. Immutable for the series' life.
uint16 public mintFeeBps;
uint16 public exerciseFeeBps;
uint16 public residualFeeBps;
```

Mutable fields:

```solidity
SeriesState public state;
uint256 public totalShortAmount;
uint256 public totalUnclaimedShortAmount;
uint256 public collateralLocked;
uint256 public accruedFees;
uint256 public totalBuyerPayoutClaimed;
uint256 public totalWriterResidualClaimed;

SettlementResult public settlementResult;

mapping(address => uint256) public writerShortBalance;
mapping(VaultPause => bool) private _paused;
```

ERC-20 fields are inherited from OpenZeppelin ERC20 or equivalent.

Rules:

- `state` starts as `ACTIVE`.
- Expiry is derived from `block.timestamp >= expiry`; do not require an explicit `EXPIRED` write.
- `settlementResult` is write-once.
- `writerShortBalance[writer]` increases on mint and decreases on residual claim.
- Option token supply increases on mint and decreases on redemption.
- `accruedFees` is strictly segregated from `collateralLocked`. No code path may move value from one to the other.
- Fee rate fields are written once at initialization and have no setter.

## `OracleRouter`

```solidity
contract OracleRouter {
    SeriesRegistry public registry;
    ProtocolConfig public config;
    IOracleAdapter public chainlinkAdapter;
    IOracleAdapter public pythAdapter;
    IOracleAdapter public dexTwapAdapter;
}
```

Rules:

- The router reads each series' `OracleConfig` from `registry`, never from a call argument.
- Adapters hold no per-pair state and no thresholds. They receive the feed identifier as an argument and return a normalized price. All policy lives in the router.
- Adapter addresses may be updated through governance, but because adapters are stateless fetchers, a replacement cannot repoint which feed a live series uses. The feed identifiers are frozen in the series config.
- If an adapter is upgraded, the upgrade must be timelocked and evented.

## `ProtocolConfig`

```solidity
contract ProtocolConfig {
    mapping(address => bool) public allowedAsset;
    mapping(address => bool) public allowedOracleAdapter;
    mapping(bytes32 => bool) public approvedOracleConfigHash;

    uint32 public defaultMaxOracleDeviationBps;
    uint32 public defaultChainlinkStaleAfter;
    uint32 public defaultPythStaleAfter;
    uint32 public defaultDexTwapStaleAfter;

    uint32 public maxPremiumSpreadBps;
    uint32 public maxPriceImpactBps;
    uint32 public maxQuoteAge;
    uint16 public sellerDiscountToleranceBps;
    uint16 public buyerOverpayToleranceBps;
    mapping(address => uint256) public minKuruDepth;   // per quote asset

    // Maximum venue fees a Kuru market may charge and still be linkable.
    uint16 public maxLinkableMakerFeeBps;
    uint16 public maxLinkableTakerFeeBps;

    // Snapshotted into each new series at creation; changes never reach live series.
    uint16 public defaultMintFeeBps;
    uint16 public defaultExerciseFeeBps;
    uint16 public defaultResidualFeeBps;

    // Read live at sweep time, deliberately not snapshotted, so it can be rotated.
    address public feeRecipient;
}
```

Rules:

- Config changes apply only to future series unless explicitly designed otherwise.
- Any global value used by live series must be considered governance risk and documented.
- Fee rate setters must enforce the compile-time caps and revert with `FeeExceedsCap`.
- `ProtocolConfig` never holds collateral or fees. Fee accrual lives in each vault.

## Accounting Relationships

Before settlement:

```text
option totalSupply == totalShortAmount
collateralLocked >= maxLiability(totalShortAmount)
sum(writerShortBalance) == totalShortAmount
sum(writerShortBalance) == totalUnclaimedShortAmount
```

At all times:

```text
collateralAsset.balanceOf(vault) >= collateralLocked + accruedFees
```

After redemption and residual claims, using gross amounts:

```text
totalBuyerPayoutClaimed + totalWriterResidualClaimed + collateralLocked == originalCollateralLocked
```

`accruedFees` does not appear in that identity because fees are carved out of the gross claim amounts rather than out of collateral. Mint fees never enter `collateralLocked` in the first place.

Implementation should not try to iterate writers or holders. All claims are user-pulled.

