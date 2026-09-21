# Security and Launch

Threats, the decisions the founder must make, deployment order and the launch checklist.

## Core Security Property

```text
Total collateral paid out to buyers and writers never exceeds collateral locked.
Trading and premium changes can change who owns tokens, never what the vault owes.
```

## Trust Assumptions

Trusted, within narrow scopes:

- The Chainlink feed named in each series (correct, live, pricing the right pair).
- The `ADMIN` multisig or timelock: allowlists assets, **approves the one Chainlink feed for each pair**, sets the per-underlying cap and future fee defaults, sets the fee recipient, sweeps fees, sets guard parameters. Approving a feed is the most security-critical action in the system, because a series cannot be corrected once created with it.
- Allowlisted ERC-20s: standard, non-rebasing, no transfer fee, no re-entering hooks.

Not trusted: series creators (anyone), writers, buyers, keepers, Kuru and its prices, frontends, unlisted tokens.

## Threats and Mitigations

| Threat | Mitigation |
|---|---|
| Undercollateralized mint | Full collateral first, rounded up, invariant and fuzz tests. |
| Double redemption | Burn before payout, `nonReentrant`, state before external calls. |
| Early exercise | `redeem` and `claimWriterResidual` require settlement, and settlement requires expiry. |
| Caller chooses the settlement price by timing | Price pinned to the Chainlink round in force at expiry, proven on chain. Same result whenever `settle` runs. |
| Forged anchor (earlier or later round) | The named round must have `updatedAt <= expiry` and its immediate successor `updatedAt > expiry`, with phase-aware adjacency. Exactly one round passes. |
| Oracle manipulation | Chainlink is the only source. Caps limit exposure. Corroboration is a V2 option. |
| Oracle outage or dead feed | `settle` reverts, no fallback. Permanent-lock risk is explicit: decision D9. |
| Wrong feed bound to a pair | Only one feed per pair is accepted, approved by `ADMIN` after two people confirm it. A user-supplied feed that differs is rejected (`FeedNotApproved`). Users cannot choose the age window. |
| A bad or malicious series passes all checks | `ADMIN` or `PAUSER` freezes minting on it, so no one else deposits. `ADMIN` disables the pair for new series. Existing positions cannot be rescued, only stopped from growing. |
| Series spam | Each series costs its creator a deployment. The expiry slot, 30-day limit and strike step bound the count. The frontend lists only series with open interest or a Kuru market. No funds are at risk. |
| Front-running a series creation | The same series already exists, so the second call reverts and the user mints into it. Harmless. |
| Compromised `PAUSER` | It can only freeze minting and creation. It cannot unfreeze, and it cannot touch settle, redeem, claim, payout or transfers. |
| Compromised `ADMIN` | It can approve a bad feed for new series, freeze minting or sweep fees. It cannot move collateral, change a live series or block payouts. Use a multisig with a timelock. |
| Kuru manipulation, wash trades | Kuru is never an input to collateral, settlement or payout. |
| Bad premium | Kuru limit price and minimum output on every buy, plus the advisory guard. No claim of protocol-level premium protection. |
| Fake option token | `factory.isOptionToken`. Never trust names, symbols or Kuru listings. |
| Reentrancy via tokens | `nonReentrant`, checks-effects-interactions, allowlisted tokens, `SafeERC20`. |
| Fee-on-transfer or rebasing collateral | Asset allowlist. No balance-delta accounting. |
| Rounding extraction | Collateral up, claims down, `writerResidualRate` by subtraction, minimum mint size, fragmentation fuzz. |
| Decimal mismatch | One conversion expression, derived scales, vectors for every decimal pair. |
| Redemption lockout by minimum size | `minOptionAmount` is mint-only. Redeem and claim need only a nonzero amount. |
| Fee drains collateral | Mint fee on top, exercise fee carved from gross, `accruedFees` segregated, sweep cannot reach `collateralLocked`. |
| Retroactive fee change | Fees snapshotted at creation and immutable. |
| Malicious fee recipient | Accrue-and-pull. No transfer to the recipient inside mint, redeem or claim. |
| Fee admin redirects fees | `sweepFees` has no receiver argument. It pays `feeRecipient()`. |
| Keeper redeems tokens a contract holds for others | `payout` skips every address with contract code. Contracts redeem for themselves. |
| Chunked keeper calls burn a holder's value through rounding | `payout` takes no amounts and always processes the full balance. |
| One failing recipient blocks everyone's payout | Each account runs in its own `try/catch` self-call. A failure is skipped and rolled back. |
| Keeper offline or malicious | Keeper has no funds or role. Owners can always call `redeem` and `claimWriterResidual` themselves. Payouts always go to the owner, never to the caller. |
| Governance blocks user funds | No pause on settle, redeem, claim or transfer. Only minting can be paused. |
| Governance changes a live series | Everything is `immutable`. `ADMIN` has no setter that touches a vault. |
| Fake or misleading token metadata | Names are generated by the factory ("Optara Option #N"). Nothing a user types reaches token metadata. Frontends read details from `seriesInfo()`. |

### Do Not

- Use a Kuru price for settlement.
- Allow undercollateralized minting.
- Change strike, expiry, feed or fee rates on a deployed series.
- Take a protocol fee out of collateral backing claims.
- Compute `writerResidualRate` any way except by subtraction.
- Compare a buyer limit against a premium that excludes venue fees.
- Trust token symbols as identity.
- Add margin, early exercise or a trade router without new specs and a new audit.

## Incident Response

1. Freeze minting on affected series (`setMintPaused(true)`) and, if a feed approval is at fault, freeze creation and disable the pair.
2. Do not touch settle, redeem or claim paths. They cannot be paused by design.
3. Snapshot state and balances.
4. Confirm the Chainlink feed independently.
5. Tell users which series are affected.

## Decisions the Founder Must Make

No one else should choose these. Use the safe default if unresolved.

| # | Decision | Safe default or recommendation |
|---|---|---|
| D1 | Launch underlying and quote assets | Only assets with a strong direct Chainlink feed on Monad and standard ERC-20 behavior. Use WMON, not native MON. |
| D2 | Fee rates | `mintFeeBps = 10`, `exerciseFeeBps = 25`. Caps are 100 bps each. |
| D3 | Fee recipient address | A multisig or treasury that is not a contract with transfer hooks. Read live, so it can be rotated. |
| D4 | The approved feed, `maxChainlinkAgeAtExpiry` and `strikeStep` for each pair (`setPairConfig`) | Confirm Chainlink has a direct feed for the pair on Monad, confirmed by two people. Set the age to heartbeat plus a buffer. Set a strike step coarse enough to avoid thin duplicate strikes. If no direct feed exists, the pair cannot launch. |
| D5 | Per-underlying open-interest cap (`setMaxShortAmount`) and the fixed `MIN_OPTION_AMOUNT` (0.01 option) | Low caps for a guarded launch. |
| D6 | Creation limits | `MIN_EXPIRY_DELAY = 1 hour`, `MAX_EXPIRY_DELAY = 30 days`, expiry on the 08:00 UTC slot (`EXPIRY_SLOT_OFFSET`), 18-decimal options. Whether to keep the daily slot. |
| D7 | Guard parameters | `sellerDiscountToleranceBps >= 100`, `maxReferenceAge` matched to the feed heartbeat, `maxVenueFeeBps` (start at 30). |
| D8 | Whether below-intrinsic asks are blocked or only warned, and whether the UI allows manual override | Warn, and allow override after a clear warning. |
| D9 | Outage recovery | Default: accept permanent lock if the feed never updates after expiry, and disclose it prominently. The alternative is a timelocked recovery module designed before mainnet. |
| D10 | `ADMIN` multisig and timelock, and `PAUSER` address | Multisig for `ADMIN`, timelock for non-emergency changes. A separate guardian key for `PAUSER`. |
| D11 | Launch mode and bug bounty | Guarded beta with low caps. Do not launch uncapped without an audit or a bounty. |
| D12 | Kuru market parameters per pair, and whether markets are created automatically | Optional per series. Calibrate per pair. Never required for any contract function. |

## Deployment Order

1. Deploy `OptionSeriesFactory` with the deployer as `ADMIN`. Check its deployed size against the chain's limit. If too large, split out a `VaultDeployer`.
2. Deploy `PremiumExecutionGuard(factory)`.
3. As `ADMIN`: allowlist assets, **set each pair's approved feed with `setPairConfig`** (feed, age window, strike step), set the per-underlying caps, set default fee rates and the fee recipient, set the guard parameters. Fee rates and caps must be set **before** the first `createSeries`, because each series snapshots them for ever. A series created against the wrong defaults must be abandoned and recreated.
4. Grant `PAUSER`.
5. Transfer `ADMIN` to the multisig or timelock and renounce the deployer's role.
6. Create the first series. Anyone can now do this, so start with low caps.
7. Create a Kuru market, then `setKuruMarket` after confirming its assets.
8. Run a small mint, a small Kuru trade, then wait for expiry, settle, redeem and claim.
9. Raise limits only after a full cycle succeeds.

### Testnet procedure

For each launch pair on Monad testnet: create a series, mint a call and a put, create the Kuru market, run the fee measurements from `premium-guard.md`, place a sell, run the guard, buy with a maximum cost, wait for expiry, build the proof, settle, redeem and check the exercise fee, claim the residual, verify `balanceOf(vault) >= collateralLocked + accruedFees`, sweep fees and confirm collateral is untouched, and test an unsettleable case (no successor round).

### Staged rollout

```text
Stage 0  internal testnet
Stage 1  public testnet
Stage 2  mainnet guarded beta, low caps
Stage 3  higher caps after successful expiries
Stage 4  more assets after the audit follow-up
```

### Artifacts to keep in the repository

```text
deployments/monad-testnet.json
deployments/monad-mainnet.json
deployments/oracle-feeds.md      feed address, pair, decimals, heartbeat, deviation, maxChainlinkAgeAtExpiry
deployments/kuru-markets.md      market addresses, parameters, measured fee behavior
deployments/roles.md
```

### Monitoring

- Each series: `balanceOf(vault)` against `collateralLocked + accruedFees`.
- New `SeriesCreated` events: alert on any series with an unusual strike or expiry, or from an address you do not recognise, so a bad series can be frozen quickly.
- Each Chainlink feed: freshness, and whether a successor round exists after each expiry.
- Fee accrual and sweep events.
- Role changes and pause events.
- Redemption or transfer failures.
- Kuru spread, depth and any change to a linked market's fees.

### Keeper

Run a keeper bot so settlement and payouts feel automatic. It needs no role and holds no funds. Anyone else can do the same job, so the protocol never depends on it.

**Settle**

1. Track every series' expiry.
2. After expiry, poll the feed until a round with `updatedAt > expiry` exists.
3. Build the proof (round in force and its successor, see `oracle.md`) and call `settle`.
4. If it reverts, log the reason and retry. A wrong proof only reverts.

**Pay out** (after `SeriesSettled`)

1. Build the set of accounts from `Transfer` events (holders) and `OptionsMinted` events (writers). Deduplicate.
2. Drop addresses that are contracts you do not control. The vault skips them anyway.
3. Call `payout(accounts)` in chunks sized to your gas budget. Balances and short positions are read on chain, so nothing else needs to be passed.
4. Re-read balances afterward. Accounts that were skipped, such as a blacklisted recipient or a contract, stay owed and can redeem themselves.

The keeper failing or being switched off never blocks anyone's funds.

## Launch Checklist

Product

- [ ] V1 scope frozen: no margin, leverage, early exercise or writer close flow.
- [ ] User-facing risk copy approved, including the permanent-lock disclosure if D9 is "accept".
- [ ] Fake-token warning implemented with `isOptionToken`.
- [ ] Kuru liquidity risk disclosed. Guard advice is not presented as a guarantee.

Contracts

- [ ] `OptionMath`, `ChainlinkAnchor`, `OptionSeriesVault`, `OptionSeriesFactory`, `PremiumExecutionGuard` implemented.
- [ ] Only two roles exist (`ADMIN`, `PAUSER`). Creation is permissionless within the fixed limits.
- [ ] Only minting and creation can be frozen. Freezing never blocks settle, redeem, claim, payout or transfers. `PAUSER` cannot unfreeze.
- [ ] Every series parameter and fee rate is `immutable`.
- [ ] `writerResidualRate` computed by subtraction only.
- [ ] Collateral rounded up, claims rounded down, verified by the vectors.
- [ ] `accruedFees` segregated from `collateralLocked`, and `sweepFees` cannot reach collateral.
- [ ] `minOptionAmount` enforced at mint only, and fixed by the factory.
- [ ] Users choose only type, assets, strike, expiry and feed. Feed must equal the approved feed for the pair, and expiry, strike step and duplicates are enforced.
- [ ] Duplicate series revert.
- [ ] Fee-on-transfer and rebasing tokens excluded by the allowlist.
- [ ] Factory size checked against the chain limit.

Tests

- [ ] Vectors, unit, fuzz (fragmentation and zero-fee equivalence), invariants, reentrancy, anchoring and guard tests all pass.
- [ ] Slither clean or documented.

Oracle and Kuru

- [ ] Direct Chainlink feed confirmed for every launch pair, and confirmed to price that pair, by two reviewers, **before** `setPairConfig` is called.
- [ ] `maxChainlinkAgeAtExpiry` in each pair config set above the feed's heartbeat.
- [ ] Keeper built and tested: settle with proofs across phase boundaries, then chunked `payout(accounts)` with failure isolation.
- [ ] Kuru fee behavior measured on testnet and recorded.

Operations

- [ ] Multisig and timelock configured. Deployer roles renounced.
- [ ] Monitoring and alerting live. Incident runbook published.
- [ ] External audit complete and fixes reviewed. Bug bounty ready.
- [ ] Every decision D1 to D12 resolved or explicitly deferred.
