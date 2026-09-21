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

- `factory` is written exactly once by `setFactory` during deployment (the registry is deployed before the factory, which needs the registry address). The setter reverts once `factory` is nonzero.
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
    address public vaultImplementation;   // EIP-1167 clone target

    mapping(bytes32 => bool) public created;
}
```

**V1 uses EIP-1167 minimal clones.** Deploying a full vault per series is prohibitively expensive once there are many strikes and expiries, and a minimal clone is non-upgradeable — its delegate target is fixed in the clone's bytecode — so it satisfies DD-13.

This choice has a consequence the rest of this file depends on. A clone has no constructor, so the vault's "immutable" series parameters **cannot use Solidity `immutable`**, which lives in bytecode. They are ordinary storage written once by an initializer. Immutability is therefore enforced by the absence of any setter plus an initialization guard, not by the compiler.

Rules:

- The initializer must be callable exactly once per clone, and must revert on a second call.
- The implementation contract itself must be initialized at deployment so it cannot be initialized by a third party. It holds no funds, but leaving it open is a known footgun.
- No setter may exist for any field written by the initializer.
- Every series parameter read is a storage read, not a bytecode constant. Cache the values needed in a hot path into memory once per call rather than re-reading them.
- Factory must not store mutable per-series economic parameters outside the registry.

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
uint256 public maxTotalShortAmount;  // 0 = uncapped; immutable, never raised on a live series
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

ERC-20 fields: because the vault is an EIP-1167 clone with no constructor, name, symbol, and decimals cannot come from OpenZeppelin `ERC20`'s constructor. Use an initializer-based ERC-20 (for example OpenZeppelin's upgradeable `ERC20Upgradeable`, used only for its initializer pattern and never behind a proxy admin), or store `name`/`symbol` written once by the vault initializer and override `name()`, `symbol()`, and `decimals()` (returning `optionDecimals`). The same applies to `ReentrancyGuard`: use a variant whose status slot is valid at zero, or initialize it in the initializer.

Access control: the vault holds no role storage of its own. `sweepFees` (`FEE_ADMIN_ROLE`) and `setPaused` (`PAUSER_ROLE`, plus the higher-trust role for `SETTLEMENT` and `REDEMPTION`) check `ProtocolConfig.hasRole(role, msg.sender)`, so role rotation applies to every live series at once and no per-clone role state exists.

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
}
```

Rules:

- The router reads each series' `OracleConfig` from `registry`, never from a call argument.
- Adapters hold no per-pair state and no thresholds. They receive the feed identifier as an argument and return a normalized price. All policy lives in the router.
- Adapter addresses may be updated through governance, but this is a trust assumption. A replacement cannot repoint which feed identifier a live series uses, because feed identifiers are frozen in the series config, but a malicious or broken replacement adapter can still return an arbitrary normalized price for that identifier.
- If an adapter is replaced, the change must be timelocked, evented, reviewed, and treated as settlement-critical governance.

## `ProtocolConfig`

```solidity
contract ProtocolConfig {
    mapping(address => bool) public allowedAsset;
    // Keyed on keccak256(underlying, quote, configHash). The pair MUST be in the key:
    // an OracleConfig names feeds but not which assets they price, so a config-only key
    // would let one approval bind those feeds to every pair.
    mapping(bytes32 => bool) public approvedOracleConfig;

    // No oracle default thresholds are stored here. Every threshold lives in the series' own
    // OracleConfig, pinned by its approved hash, so a stored default would gate nothing.

    uint32 public maxPremiumSpreadBps;
    uint32 public maxPriceImpactBps;
    uint32 public maxQuoteAge;
    uint16 public sellerDiscountToleranceBps;
    uint16 public buyerOverpayToleranceBps;
    mapping(address => uint256) public minKuruDepth;   // per quote asset

    // Maximum taker fee and absolute maker-side adjustment a Kuru market may apply and still be linkable.
    uint16 public maxLinkableMakerFeeBps;
    uint16 public maxLinkableTakerFeeBps;

    // Snapshotted into each new series at creation; changes never reach live series.
    uint16 public defaultMintFeeBps;
    uint16 public defaultExerciseFeeBps;

    // Read live at sweep time, deliberately not snapshotted, so it can be rotated.
    address public feeRecipient;
}
```

Rules:

- Config changes apply only to future series unless explicitly designed otherwise.
- Any global value used by live series must be considered governance risk and documented.
- Fee rate setters must enforce the compile-time caps and revert with `FeeExceedsCap`.
- `ProtocolConfig` never holds collateral or fees. Fee accrual lives in each vault.
- There is deliberately no per-series adapter allowlist. Adapters are settlement-critical dependencies held by `OracleRouter`, and which feed a series uses is frozen in its own config. Replacing an adapter is governance-sensitive because a bad adapter can lie about the pinned feed's result even though it cannot change the feed id.

## Accounting Relationships

Before settlement:

```text
option totalSupply == totalShortAmount
collateralLocked >= requiredCollateral(totalShortAmount)
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
