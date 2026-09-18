# Storage Layout

## Purpose

This file defines the intended storage model. It is written so an AI agent can implement contracts without inventing hidden state.

V1 series vaults should be non-upgradeable. Storage layout still matters for auditability and deterministic reasoning.

## `SeriesRegistry`

```solidity
contract SeriesRegistry {
    address public factory;

    mapping(bytes32 => address) private _vaultBySeriesId;
    mapping(bytes32 => address) private _optionTokenBySeriesId;
    mapping(address => bytes32) private _seriesIdByOptionToken;
    mapping(bytes32 => SeriesParams) private _seriesParams;
    mapping(bytes32 => KuruMarketConfig) private _kuruMarketBySeriesId;
    mapping(bytes32 => bool) private _seriesExists;
}
```

Rules:

- `_seriesParams[seriesId]` is write-once.
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
    ProtocolConfig public config;
    IOracleAdapter public chainlinkAdapter;
    IOracleAdapter public pythAdapter;
    IOracleAdapter public dexTwapAdapter;
}
```

Rules:

- Adapter addresses may be updateable for future series through governance.
- Deployed series store their oracle config. Governance updates must not silently change old series requirements unless the series config explicitly points to a router-level approved adapter.
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

    uint32 public defaultMaxPremiumSpreadBps;
    uint32 public defaultMaxPriceImpactBps;
    uint256 public defaultMinKuruDepth;

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

