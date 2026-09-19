# Security Threat Model

## Purpose

This file lists threats, required mitigations, and audit focus areas.

## Security Goal

The core security property:

```text
For every series, total collateral paid to buyers and writers must never exceed collateral locked.
```

Secondary property:

```text
Kuru trading and premium manipulation can change token ownership or trade price, but cannot change settlement obligations.
```

## Trust Assumptions

Trusted only within narrow scopes:

- Chainlink oracle contracts for configured feeds.
- Pyth oracle contracts for configured feeds.
- Factory for canonical deployment.
- Registry for canonical discovery.
- Governance/multisig for future configuration.

Untrusted:

- Writers.
- Buyers.
- Kuru traders.
- Market makers.
- Keepers.
- Kuru market prices.
- Frontends.
- ERC-20 tokens unless allowlisted.
- Offchain indexers.
- Last-traded prices.

## Threats and Mitigations

| Threat | Attack | Mitigation |
|---|---|---|
| Undercollateralized mint | Writer mints more claims than collateral. | Full collateral before mint, round up, invariant tests. |
| Double redemption | Holder redeems same option twice. | Burn before transfer, nonReentrant, state updates before external calls. |
| Early exercise | Buyer claims before expiry. | Redemption only after `SETTLED`. |
| Oracle manipulation | Attacker manipulates settlement source. | Chainlink/Pyth quorum, deviation checks, freshness checks, fail closed. |
| Oracle outage | Required oracle unavailable. | Settlement reverts, no Kuru fallback, recovery process required. |
| Settlement timing choice | Settlement is permissionless and undated, so a caller waits for a favorable post-expiry move and settles then, converting a worthless option into a claim on writer collateral. | Settlement price is anchored to the first oracle observation at or after expiry and proven onchain; freshness checks apply only to reference reads. |
| Forged settlement anchor | Caller names a later, more favorable round. | Adapter verifies the preceding round predates expiry, so only the first qualifying observation is accepted. |
| Redemption minimum lockout | A minimum size applied to redemption traps holders who acquired less than it through a partial fill or transfer. | `minOptionAmount` is mint-only; redeem and claim require only a nonzero amount. |
| Kuru manipulation | Wash trades distort option premium. | Kuru never settlement, route safety checks, buyer limits. |
| Unrealistic writer ask | Writer posts harmful premium. | Acceptable premium range, warnings, route rejection. |
| Fake series | Token mimics official option. | Canonical factory/registry checks. |
| Oracle config reuse across pairs | A config approved for one pair is attached to a different pair, so a series settles at the wrong asset's price. | Approval is keyed on `(underlying, quote, configHash)`, not the config hash alone. |
| Series metadata squatting | Attacker pre-creates popular strikes with misleading names; metadata is outside `seriesId` and permanent. | `SERIES_CREATOR_ROLE` gates creation in V1, FD-22. |
| Unbounded open interest | A single series absorbs more risk than the guarded launch intends. | Immutable `maxTotalShortAmount` checked at mint, FD-09. |
| Reentrancy | Malicious token re-enters vault. | ReentrancyGuard, CEI, allowlisted tokens, SafeERC20. |
| Rounding extraction | Dust positions accumulate value. | Round collateral up, payout down, min sizes. |
| Decimal mismatch | Wrong scale drains collateral. | Explicit decimals, mulDiv tests, per-asset test vectors. |
| Kuru downtime | Trading unavailable near expiry. | Settlement/redemption independent. |
| Governance abuse | Admin changes live economics. | Immutable series, timelock, no mutation of settlement result. |
| Bad pause | Pause blocks valid claims. | Narrow pause scopes, redemption pause only in active exploit. |
| Fee-on-transfer token | Collateral received less than expected. | Reject fee-on-transfer/rebasing tokens in V1. |
| Rebasing token | Balance changes break accounting. | Asset allowlist excludes rebasing tokens. |
| Fee drains collateral | A fee path reduces collateral backing live claims. | Mint fee additive, exercise fee carved from gross payout, `accruedFees` segregated, sweep cannot reach `collateralLocked`. |
| Retroactive fee change | Governance raises fees after users enter a series. | Fee rates snapshotted at creation and immutable; no setter on a deployed vault. |
| Governance fee capture | Admin sets a confiscatory fee on new series. | Compile-time caps that governance cannot exceed. |
| Malicious fee recipient | Recipient contract reverts or re-enters, bricking core paths. | Accrue-and-pull: no transfer to recipient in mint, redeem, or claim; sweep is a separate role-gated call. |
| Venue fee blindness | Buyer's limit passes on gross premium but real cost exceeds it. | All buyer limits bind on fee-inclusive `allInCost`; max linkable venue fee enforced. |
| Unverified venue fee convention | Wrong assumption about Kuru taker-fee mechanics breaks cost limits. | Assume the conservative convention and independently enforce `minOptionAmountOut`; verify before launch, FD-17. |
| Permanent oracle lock | Required feed never recovers, collateral stuck forever. | Explicit FD-20 decision plus prominent disclosure; recovery path must be timelocked and never Kuru-sourced. |
| Residual rate rounding | Independently rounded residual rate over-allocates collateral. | `writerResidualRate` computed only by subtraction; exact-identity fuzz invariant. |

## ERC-20 Asset Requirements

V1 allowlisted assets must be:

- Standard ERC-20.
- Non-rebasing.
- No fee-on-transfer.
- No transfer hooks that can re-enter without guard.
- Decimals readable and stable.
- Liquid enough for oracle support.

Native MON support should be excluded from V1 unless wrapped MON is used.

## Audit Focus

Auditors should review:

- Collateral math and decimals, especially the `UQ_SCALE` conversion helper.
- The exact identity `buyerPayoutRate + writerResidualRate == collateralPerOption`.
- Fee segregation: that no path moves value between `collateralLocked` and `accruedFees`.
- Fee rate immutability on deployed vaults.
- Oracle quorum logic.
- Settlement write-once behavior.
- Reentrancy around mint, redeem, claim.
- ERC-20 burn and transfer ordering.
- Kuru integration boundary.
- Premium range checks.
- Registry canonical identity.
- Pause permissions.
- Governance update limits.
- Invariant tests and fuzz coverage.

## Incident Response

If active exploit suspected:

1. Pause minting and premium routing.
2. Do not pause redemption unless redemption is the exploit path.
3. Snapshot affected series and balances.
4. Verify oracle sources independently.
5. Communicate impacted series status.
6. Prepare governance recovery only if explicitly required.

## Prohibited Shortcuts

Never:

- Use Kuru price for settlement.
- Allow undercollateralized minting.
- Allow admin to change strike, expiry, or fee rates on a deployed series.
- Take a protocol fee out of collateral backing outstanding claims.
- Compute `writerResidualRate` by anything other than subtraction.
- Compare a buyer's cost limit against a premium that excludes venue fees.
- Use token symbol as identity.
- Let one stale oracle settle by accident.
- Add margin or early exercise to V1 without new specs and audit.
- Add a trade router without re-auditing the approval and reentrancy surface it introduces.

