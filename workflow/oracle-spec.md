# Oracle Spec

## Purpose

This file defines V1 oracle behavior for settlement and premium safety.

Founder-approved V1 oracle model:

```text
Primary: Chainlink if feed exists for pair.
Secondary/corroborator: Pyth if feed exists for pair.
Optional tertiary check: independent DEX TWAP.
Kuru: never settlement; only premium execution/depth sanity.
```

## Security Principle

There is no unhackable oracle. V1 reduces oracle risk by using independent sources, freshness checks, deviation checks, and fail-closed behavior.

Kuru market prices must not determine settlement because Kuru markets can be thin, manipulated, paused, or unavailable.

## Price Format

All oracle adapters must normalize to:

```text
PRICE_SCALE = 1e18
price = quote units per 1 underlying unit, scaled by PRICE_SCALE
```

Example:

```text
MON/USDC = 5.25
normalized price = 5.25e18
```

Adapters must record source decimals and convert explicitly.

## Source Priority

For each series:

1. Chainlink feed is primary if available for the pair.
2. Pyth feed is secondary and corroborates Chainlink if available.
3. Independent DEX TWAP may be configured as a tertiary check.
4. Kuru may be checked for premium execution sanity only.

## Series Oracle Configuration

Each series stores:

```solidity
struct OracleConfig {
    address chainlinkFeed;
    bytes32 pythFeedId;
    address dexTwapAdapter;
    bool requireChainlink;
    bool requirePyth;
    bool requireDexTwap;
    uint32 maxOracleDeviationBps;
    uint32 chainlinkStaleAfter;
    uint32 pythStaleAfter;
    uint32 dexTwapStaleAfter;
}
```

Recommended production policy:

- If Chainlink feed exists for the pair, `requireChainlink = true`.
- If Pyth feed exists for the pair, `requirePyth = true`.
- If both exist, both must pass freshness and deviation checks.
- If only one exists, listing the series requires explicit founder/governance approval.
- If independent DEX TWAP is configured, it is a sanity check, not the main settlement source.

## Settlement Quorum Rules

### Chainlink Only

Allowed only if no Pyth feed exists or the series is explicitly approved as single-oracle.

Pass conditions:

```text
chainlinkPrice > 0
chainlinkUpdatedAt != 0
block.timestamp - chainlinkUpdatedAt <= chainlinkStaleAfter
feed pair matches underlying/quote
```

Result:

```text
settlementPrice = normalizedChainlinkPrice
```

### Chainlink + Pyth

Preferred V1 mode.

Pass conditions:

```text
chainlink valid
pyth valid
abs(chainlinkPrice - pythPrice) / min(chainlinkPrice, pythPrice) <= maxOracleDeviationBps
```

Result:

```text
settlementPrice = normalizedChainlinkPrice
```

Rationale:

- Chainlink is the founder-approved primary source.
- Pyth is the independent corroborator.
- If Pyth disagrees beyond the threshold, settlement fails closed.
- The protocol does not invent a new settlement price from Kuru or market data.

### Chainlink + Pyth + DEX TWAP

Pass conditions:

```text
chainlink valid
pyth valid
dexTwap valid
Chainlink/Pyth deviation <= maxOracleDeviationBps
DEX TWAP deviation from Chainlink settlement price <= maxTwapDeviationBps
```

Result:

```text
settlementPrice = normalizedChainlinkPrice
```

DEX TWAP only confirms that the Chainlink/Pyth-approved result is not wildly disconnected from independent onchain liquidity.

## Failure Behavior

Settlement must fail closed if:

- Required Chainlink source is stale or invalid.
- Required Pyth source is stale or invalid.
- Required DEX TWAP source is stale or invalid.
- Chainlink and Pyth deviation exceeds threshold.
- Oracle pair identity does not match series pair.
- Price is zero or negative.
- Price decimals are unsupported.
- Pyth update data is invalid or underpaid.

When settlement fails:

```text
state remains ACTIVE
minting remains blocked by expiry
redemption remains blocked
writer residual claim remains blocked
```

No fallback to Kuru is allowed.

## Premium Reference Price

Premium safety may use `OracleRouter.getReferencePrice`.

Rules:

- Same source priority as settlement.
- Can be called before expiry.
- Used only for premium bounds.
- Must not write settlement state.
- Must not be confused with final expiry settlement price.

## Pyth Pull-Oracle Handling

If Pyth is required:

- `settle` must accept update data or use a verified pre-updated price path.
- Caller pays required Pyth update fee.
- Contract must not retain excess native token without explicit refund logic.
- Invalid Pyth update causes revert.

## Chainlink Handling

Adapter must check:

```text
answer > 0
updatedAt > 0
answeredInRound >= roundId when applicable
block.timestamp - updatedAt <= chainlinkStaleAfter
feed decimals <= 18
```

If quote is not USD and feed is USD-based, adapter must compose approved feeds carefully. Example:

```text
MON/USDC from MON/USD and USDC/USD
```

Composed feeds must check freshness and validity for both legs.

## Prolonged Outage and the Permanent-Lock Risk

The fail-closed design has a consequence that must be stated explicitly rather than left implicit in the failure table above.

If a required oracle **never** returns valid data, then:

```text
settle()               always reverts
state stays ACTIVE forever
redeem()               unreachable, because it requires SETTLED
claimWriterResidual()  unreachable, because it requires SETTLED
collateral             permanently locked, for holders and writers alike
```

There is no code path out of this state in the current design. That is a deliberate consequence of refusing to fall back to a manipulable price source, but it is a real user-funds risk and not merely a liveness inconvenience.

V1 must do one of two things before mainnet, decided in [founder-decisions.md](./founder-decisions.md) FD-20:

- Accept the risk and disclose it prominently in user-facing risk copy, or
- Implement a recovery path with a delay long enough that users can observe and react to it.

Any recovery path must be timelocked, evented, incapable of running while normal settlement is still possible, and incapable of producing a settlement price from Kuru. An `EmergencyRecoveryModule` implementing the chosen option is listed as an optional contract in [implementation-spec.md](./implementation-spec.md); it stays unimplemented until FD-20 is resolved.

Shipping without an explicit decision selects permanent lock by default. That may be an acceptable choice, but it should be a chosen one.

## Needs Founder Decision

Before production:

- Decide whether single-oracle series are allowed at all.
- Decide max deviation bps for Chainlink/Pyth.
- Decide stale thresholds by asset class.
- Decide whether DEX TWAP is required for launch pairs.
- Decide the prolonged-outage recovery path, FD-20. This one can permanently lock user funds.
- Confirm exact Chainlink and Pyth feed addresses/feed IDs for Monad mainnet.
- Confirm that Chainlink actually operates feeds for the intended pairs on Monad; if it does not, FD-01 becomes a launch blocker rather than a policy question.
