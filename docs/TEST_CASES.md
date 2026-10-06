# Test Cases

Required tests, by area. These are the minimum: every contract also needs its own unit, fuzz, invariant and E2E
tests as required by [TESTING.md](TESTING.md) §0. ID format `AREA-NNN`. Each test asserts state, balances and events, and names the
invariants it checks. Strategy and tooling: [TESTING.md](TESTING.md).

Completeness is checked by `python3 reference/check_traceability.py`. It fails if any invariant, function, error or event in
the spec lacks a test below, if an appendix cites a test ID that doesn't exist, or if a contract has no row in
[TESTING.md](TESTING.md) §0.2.

## ACC — Subaccounts

| ID | Case |
|---|---|
| ACC-001 | Create a subaccount with an approved asset; ids increase; `SubAccountCreated` emitted |
| ACC-002 | Create with an unapproved asset reverts |
| ACC-003 | Owner sets and revokes an operator; the operator can act; a revoked operator can't (`OperatorSet`) |
| ACC-004 | An operator can't set operators |
| ACC-005 | A stranger can't act on someone else's account (`NotAuthorized`) |
| ACC-006 | Any action on a non-existent account reverts (`UnknownAccount`) |
| ACC-007 | Ledger writes (`addCash`, `subCash`, `applyDelta`) only from the three writer modules, never from owners or strangers; cash can't go below zero (`InsufficientCash`); every write emits `CashUpdated` / `BalanceUpdated`, and participant changes emit `ParticipantsUpdated`; zero delta is a no-op |
| ACC-008 | `applyDelta` keeps the series list and underlying buckets exact (open, sign flip, close with swap-and-pop, reopen); `bucketsOf`, `seriesCountInGroup`, `totals` correct |
| ACC-009 | `setPositionLimits` and `setMinPositionQty`: governance only; bounds enforced (`InvalidLimits`); lowering limits forces nothing; the minimum can only change to an exact divisor (`PositionLimitsSet`, `MinPositionQtySet`) |

## SER — Series and products

| ID | Case |
|---|---|
| SER-001 | Create a valid call and put; wrapper deployed at `predictWrapper(seriesId)` with correct name, symbol, decimals, `seriesId`, minter and burners; `SeriesCreated`, `GroupCreated`, `WrapperDeployed` |
| SER-002 | Duplicate `seriesId` reverts (`SeriesExists`); the risk set is not part of the identity |
| SER-003 | Each bound violated reverts with its reason (`InvalidSeriesParams` 1 strike, 2 size, 3 expiry, 4 oracle config, 5 vol product, 6 risk set); bounds inclusive; unknown or disabled product (`ProductNotEnabled`), revoked asset (`AssetNotApproved`), role and `SERIES_CREATE` pause enforced |
| SER-004 | Creation does not depend on surface tenor coverage; a series outside it is unpriceable at mint (`SeriesNotPriceable`, CLR-005) |
| SER-005 | No function can change terms (all writes revert; upgrade test UPG-003) |
| SER-006 | `groupId` shared across series with the same underlying, asset, expiry and oracle config; ids match the OPTION_SPEC §5 formulas and depend on chain id; `getSeries`, `getGroup`, `seriesInGroup`, `groupOf`, `productOf` views correct |
| SER-007 | `approveProduct` timelocked, each config check reverts with its reason (`InvalidProductConfig` 1–6), `getProduct` reflects it; `setProductEnabled(false)` instant for the guardian, re-enabling timelocked; disabled product blocks new series but not existing ones (`ProductApproved`, `ProductEnabled`) |
| SER-008 | `setSettlementAssetApproved`: governance approves (reads decimals; non-contract or > 18 decimals rejected: `NotAContract`, `UnsupportedDecimals`), guardian may revoke (`SettlementAssetApproved`) |
| SER-009 | A group holds at most 256 series (`GroupFull`) |
| SER-010 | Wrapper: only the minter mints, only the three burners burn, `deployWrapper` registry only, clones and implementation can't be (re)initialized, ERC-20 transfers exact, EIP-2612 `permit` with the series-name domain, replay rejected |

## CLR — Clearing

| ID | Case |
|---|---|
| CLR-001 | Deposit credits exact cash (`CollateralDeposited`); fee-on-transfer token reverts (`NonExactTransfer`) |
| CLR-002 | Withdraw within free margin succeeds (`CollateralWithdrawn`); 1 unit above reverts (`NotHealthy`) |
| CLR-003 | Withdraw with open positions and stale spot reverts; with no positions needs no oracle data |
| CLR-004 | Mint: balance −qty, wrapper +qty to recipient, fee debited and split, healthy after; `ExternalLongMinted`, `SellerFeeCharged` (INV-1, 3, 9, 11) |
| CLR-005 | Mint reverts on: stale spot, stale surface, close-only product, insurance below minimum, OI cap, position limit, fee > max, unhealthy |
| CLR-006 | Mint after expiry reverts (`SeriesNotActive`) |
| CLR-007 | Unwrap: wrapper burned from caller, balance +qty (`LongUnwrapped`), no oracle data needed (INV-4, 13) |
| CLR-008 | Unwrap or mint into an account with a different settlement asset reverts (`AssetMismatch`, INV-5) |
| CLR-009 | Wrap: needs a long, healthy after (`LongWrapped`); reverts if the long was needed as a hedge (INV-3, 11) |
| CLR-010 | Close with wrapper reduces the short (`ShortClosedWithWrapper`); reverts if `qty` > short; works after expiry, reverts after finalization (`GroupFinalized`) |
| CLR-011 | Close with internal long between two of the caller's accounts (`ShortClosedWithInternalLong`); the source must stay healthy (INV-11); the target's health never falls (INV-13) |
| CLR-012 | A non-zero balance below `minPositionQty` reverts (INV-6, `PositionBelowMinimum`) |
| CLR-013 | Participant counter updates on every 0↔non-zero change and counts accounts, not series (INV-27) |
| CLR-014 | INV-1 holds after every clearing action |
| CLR-015 | Anyone may deposit into any account; deposit never lowers health (INV-13); custody equals Σ cash + Σ pools after every clearing action (INV-7); cash never negative (INV-8) |
| CLR-016 | `updateOracles` alone applies spot updates, surface reports and node proofs, with no other effect |
| CLR-017 | Per-series totals equal the sum of balances after random action sequences (INV-2) |
| CLR-018 | Risk-increasing actions revert on stale data, close-only product, emergency mode, insurance or keeper reserve below minimum (INV-12, `ProductCloseOnly`, `InsuranceBelowMinimum`) |
| CLR-019 | OI caps: a mint pushing series OI or product short underlying above its cap reverts (`OpenInterestCap`); lowering a cap below current OI forces nothing and only blocks new mints (INV-42) |
| CLR-020 | Position counts: adding the (max+1)th series or bucket by mint or unwrap reverts (`PositionLimit`); liquidators receiving slices are checked the same way (INV-43) |
| CLR-021 | Deposit, unwrap and close succeed with stale oracles and an empty `OracleUpdate` (LIV-1) |
| CLR-022 | Input errors: `ZeroAmount`, `InvalidRecipient`, `UnknownSeries`, `InsufficientCash`, `InsufficientShort`, `InsufficientLong` each triggered |
| CLR-023 | Provider fee handling: functions taking `OracleUpdate` refund excess `msg.value` |

## PRV — Previews and views

| ID | Case |
|---|---|
| PRV-001 | `previewMint` fee, equity and IM after equal the values produced by `mintExternalLong` in the same block |
| PRV-002 | `previewWithdraw`, `previewWrap` and `maxWithdrawable` match execution; withdrawing exactly `maxWithdrawable` succeeds, +1 unit fails |
| PRV-003 | `healthOf`, `equityOf`, `marginOf`, `priceOf`, `ivOf` match the reference model and report `fresh = false` when data is stale |
| PRV-004 | `previewSlice`, `previewSettle`, `previewRedeem`, `previewSellerFee`, `previewBuyerFee` match execution |
| PRV-005 | Ledger views (`balanceOf`, `seriesOf`, `totals`, `participants`, `isAuthorized`, `settlementPrice`, `recoveryRatio`, `groupState`, `isOracleStalled`, `insuranceBalance`, `keeperReserve`, `treasury`) match state |

## PRC — Pricing (vs reference vectors)

| ID | Case |
|---|---|
| PRC-001 | Normal CDF error ≤ 1e-7 over x ∈ [−10, 10] (INV-39) |
| PRC-002 | Black-76 call/put vs reference across spot, strike, IV and time grids; error ≤ (F + K) × 1e-7 (INV-39) |
| PRC-003 | Put-call parity holds within tolerance (INV-38) |
| PRC-004 | `T = 0` or `σ = 0` gives intrinsic |
| PRC-005 | Price ≥ intrinsic; call ≤ F; put ≤ K (INV-38) |
| PRC-006 | Worked examples from [MATH.md](MATH.md) §10 (106.77, 39.65, 96.62) |
| PRC-007 | Monotonicity: call up and put down in spot; both up in IV and time (INV-38) |

## VOL — Volatility surface oracle

| ID | Case |
|---|---|
| VOL-001 | A valid report with quorum is accepted; header and kNodes stored; `SurfaceAccepted`; status FRESH; a report signed with `cast` from JSON typed data is accepted (independent EIP-712 check, `reportDigest`) |
| VOL-002 | Wrong chainId / contract (reason 1), unknown product, pair mismatch or product without `setSurfaceConfig` (reason 2) revert (`InvalidSurfaceReport`) |
| VOL-003 | Replayed or lower `surfaceSeq`, or an older `validAfter`, reverts (reason 3, INV-17) |
| VOL-004 | Expired or not-yet-valid report reverts; lifetime > max reverts |
| VOL-005 | Duplicate signer, unknown signer, unsorted signatures, malformed signature, below quorum, no independent signer → revert (`InvalidSignatures`); more than quorum is fine; changing any of the 21 signed fields changes the digest |
| VOL-006 | Tenor and calendar checks (reason 5: no tenor, not increasing, not after validAfter, ATM variance zero or decreasing, unused tenor with data, ATM IV outside the report's bounds); kNodes checks (reason 6: empty, > 32, not strictly increasing); IV bounds vs the product floor and cap (reason 7) |
| VOL-007 | ATM IV move > `maxIvMoveBps` reverts; accepted in emergency mode (`setEmergencyMode`, `EmergencyModeSet`, product goes close-only) |
| VOL-008 | `confidenceBps > maxConfidenceBps` → report stored with `lowConfidence` (the risk manager makes the product close-only); the next confident report clears it |
| VOL-009 | `proveNodes`: valid proof caches the leaf (`nodeValue`, `NodeProven`, INV-19); already-proven leaves skipped; tampered value, wrong index, unused tenor, node beyond `kNodes`, old report → reason 10; leaf IV outside the report's bounds → reason 9 |
| VOL-010 | Interpolation: exact tenor, between tenors, between nodes, beyond edge nodes (flat) vs reference (INV-40) |
| VOL-011 | `surfaceStatus`: FRESH while age ≤ `surfaceStaleAfter` and before `expiresAt`, then STALE with `staleSeconds`; pricing adjustments (short IV up, long IV down, long intrinsic after `maxLongTimeValueStale`) in the risk manager |
| VOL-012 | Age > `maxSurfaceStale` → product close-only automatically |
| VOL-013 | A needed leaf missing from cache and update reverts (`MissingSurfaceNode`) |
| VOL-014 | `addPublisher` and `setQuorum` governance only; `removePublisher` instant for the guardian; duplicates and unknown publishers rejected (`InvalidPublisher`); `isPublisher`, `quorum` views (`PublisherAdded`, `PublisherRemoved`, `QuorumSet`) |
| VOL-015 | `setSurfaceConfig`: governance only, each bound enforced (`InvalidSurfaceConfig` 1–6) (`SurfaceConfigSet`); `kNodes` storage rewritten only when the grid changes |

## SPT — Spot oracle

| ID | Case |
|---|---|
| SPT-001 | `update` accepts a fresh price normalized to WAD for direct and derived (base/USD ÷ quote/USD) sources and exponents 0 to −36 (`SpotUpdated`); `spotPrice`, `requireFreshSpot`, `isSpotFresh` |
| SPT-002 | An older or equal-time update doesn't overwrite a newer one (INV-18) |
| SPT-003 | Stale spot (`age > maxSpotAge`, or never set) reverts `requireFreshSpot` (`StaleSpot`); a derived price is as old as its older leg; stale spot blocks risk-increasing actions only |
| SPT-004 | `updateFee` quotes the provider fee; `update` pays exactly that fee and refunds the rest to the caller; insufficient fee reverts (`InsufficientProviderFee`); a caller that can't take the refund reverts (`RefundFailed`) |
| SPT-005 | `setSource` governance only (`SpotSourceSet`); a derived source divides by the stablecoin/USD leg, never treats USD as the stablecoin; each source check reverts with its reason (`InvalidSpotSource` 1–4) |
| SPT-006 | Non-positive price, positive or too negative exponent, price above 1e36 or rounding to zero revert (`InvalidSpotPrice`); refreshing an unconfigured product reverts |

## MRG — Margin

| ID | Case |
|---|---|
| MRG-001 | Naked call IM/MM match the reference (3,417.78 / 1,447.43; cash needed 3,524.55) |
| MRG-002 | Spread IM much lower than naked (438.22; cash needed 505.34) |
| MRG-003 | Put example (1,423.23 / 676.31) |
| MRG-004 | Different underlyings don't offset (INV-15) |
| MRG-005 | Unwrap, close and deposit never lower health (property fuzz, INV-13) |
| MRG-006 | MM ≤ IM for random portfolios, including mixed-vega ones (INV-14; IM uses the union of both sets) |
| MRG-007 | Health states classified correctly at boundaries (equity = IM, = MM) |
| MRG-008 | Expired-unfinalized legs valued at intrinsic with spot shocks; finalized-unsettled at exact payoff |
| MRG-009 | Wallet or Kuru-held wrappers give no margin credit (INV-52) |
| MRG-010 | Margin never below the reference beyond rounding (differential fuzz) |
| MRG-011 | Homogeneity: scaling every position by c scales MM and the IM loss term by c (INV-41) |
| MRG-012 | `setRiskParameterSet`: more conservative values instant, less conservative timelocked; existing series keep their set id (`RiskParameterSetUpdated`) |

## FEE — Fees, insurance, keeper reserve

| ID | Case |
|---|---|
| FEE-001 | Seller fee formula and minimum; charged before the IM check, so a fee can't consume margin (INV-44) |
| FEE-002 | Fee > `maxSellerFeeNative` reverts (`FeeTooHigh`, INV-44) |
| FEE-003 | Split exact; treasury takes the remainder (INV-9, `FeeSplit`) |
| FEE-004 | Buyer fee on router buys from the actual premium; > max reverts; refunds exact (`BuyerFeeCharged`) |
| FEE-005 | No Optara fee on router sells or direct transfers |
| FEE-006 | `setFeeRates` above hard caps reverts; changes are timelocked (INV-44) |
| FEE-007 | `withdrawTreasury` limited to the treasury balance (INV-10, `TreasuryWithdrawn`) |
| FEE-008 | Keeper rewards paid and escalating; zero when the reserve is empty; never exceed the reserve (INV-37, `KeeperRewardPaid`) |
| FEE-009 | `InsuranceFund.deposit` credits no account (`InsuranceDeposited`); insurance never goes negative (INV-37) |
| FEE-010 | `setSplit` requires the sum to be 10,000; `setMinimums` raising is instant, lowering timelocked; falling below a minimum sets close-only |

## LIQ — Liquidation

| ID | Case |
|---|---|
| LIQ-001 | `startAuction` reverts when equity ≥ MM (INV-21, `NotLiquidatable`); `AuctionStarted` emitted otherwise |
| LIQ-002 | Worked example [MATH.md](MATH.md) §12.1: cash 464.43, penalty 15.49, health −1,100.01 → −379.92 |
| LIQ-003 | Every slice improves `equity − MM` by ≥ sliceMM × (1 − bonus − penalty), with equality when paid in full; dust slices that can't improve after rounding revert (INV-22, `HealthNotImproved`) |
| LIQ-004 | Liquidator must be healthy after (INV-23); unhealthy liquidator reverts |
| LIQ-005 | Slice bounds (`SliceOutOfBounds`); whole-bucket mode after `auctionDuration` |
| LIQ-006 | Bonus grows linearly and caps at max |
| LIQ-007 | Net-asset slice: the liquidator pays mark − discount (`SliceLiquidated`) |
| LIQ-008 | Insufficient cash: the liquidator is paid first, the penalty reduced, insurance top-up ≤ max (INV-25), `BadDebtCovered` |
| LIQ-009 | `minCashToLiquidator` / `maxCashFromLiquidator` enforced (`SlippageExceeded`) |
| LIQ-010 | Wrapper-burn liquidation reduces the short, needs ΔMM > 0, pays mark + discount (`WrapperLiquidated`) |
| LIQ-011 | Auction ends at IM + buffer; `endAuction` when healthy or empty (`AuctionEnded`) |
| LIQ-012 | Expired legs are not transferred; finalized legs never auctioned (INV-46) |
| LIQ-013 | Slices never change a series' net internal balance and never increase total short; netting with the liquidator's opposite position may reduce it (INV-24) |
| LIQ-014 | Works with the venue adapter disabled (LIV-3) |
| LIQ-015 | Stale spot reverts liquidation; a surface older than `surfaceStaleAfter` but within `maxSurfaceStale` uses stale penalties; beyond it reverts (INV-45) |
| LIQ-016 | Liquidator account equal to the liquidated account, or with another settlement asset, reverts (INV-23) |
| LIQ-017 | A slice once equity ≥ IM × (1 + target) reverts; starting a second auction on an active bucket reverts (`AuctionActive`); slicing without an auction reverts (`AuctionNotActive`) (INV-46) |

## STL — Settlement

| ID | Case |
|---|---|
| STL-001 | Finalize with a valid round-in-force proof (successor or latest round); for any round history exactly one round is provable (`verify`); second finalize reverts (INV-26) |
| STL-002 | Too early (`FinalizationTooEarly`, `earliestFinalization`), each wrong proof reverts with its reason (`InvalidSettlementProof` 1–12): earlier round, round after the end, skipped round, false latest claim, missing round or successor, wrong proof count; stale or non-positive observation is invalid; Chainlink phase boundaries handled (`isImmediateSuccessor`) |
| STL-003 | Fallback feed only after the primary is proven invalid; refused while the primary is valid; derived sources: half-up division, leg skew limit, invalid leg |
| STL-004 | `ORACLE_STALLED` after the deadline (`OracleStalled`); late valid finalize works |
| STL-005 | Wrapper supply snapshot at finalization; supply only decreases afterwards (INV-33) |
| STL-006 | `settleAccountGroup` nets all series; debt collected into the pool; unpaid recorded; balances zeroed; counter decremented (`AccountSettled`) |
| STL-007 | Ratio can't be computed while participants > 0 (INV-28, `SettlementIncomplete`) |
| STL-008 | Netting example [MATH.md](MATH.md) §13.2: ratio exactly 1 (INV-30) |
| STL-009 | Shortfall example: insurance 100 (`InsuranceCovered`), ratio 0.928571…, W receives exactly 649.999999 (round-down) |
| STL-010 | The ratio is the same for wrappers and internal creditors and is set once (INV-29, `RatioAlreadySet`, `RecoveryRatioSet`) |
| STL-011 | Redemption order irrelevant: random orders give identical per-unit payouts (INV-32) |
| STL-012 | Total payouts ≤ collected + insurance; pool = collected + insurance − payouts, never negative (INV-31) |
| STL-013 | Zero-payoff wrappers redeem for 0 and burn (`WrapperRedeemed`) |
| STL-014 | `claimSettlement` credits cash once (`SettlementClaimed`) |
| STL-015 | Batch settle skips non-participants; rewards paid |
| STL-016 | `sweepDust` only when everything is redeemed and claimed (`DustSwept`) |
| STL-017 | Settlement identity: for random groups, Σ account nets + wrapper claims == 0 exactly at finalization (INV-47) |
| STL-018 | Settling the same account twice reverts (`NotParticipant`); claiming twice reverts (`NothingToClaim`) (INV-48) |
| STL-019 | Rounding: debts round up, credits, ratio and payouts round down (INV-49) |
| STL-020 | Any address can settle any participant; rewards escalate; settlement completes for every group (LIV-2) |
| STL-021 | Redeem or claim before the ratio reverts (`RatioNotSet`); settle before finalization reverts (`GroupNotFinalized`) |
| STL-022 | `registerConfig` (oracle admin) stores an approved config under the hash of its contents that can never change; duplicates and each invalid config revert (`SettlementConfigExists`, `InvalidSettlementConfig` 1–6); `setConfigApproved`: governance approves, guardian may revoke, unknown id reverts (`UnknownSettlementConfig`); `isConfigUsable` matches the pair; `stalledAfter` (`SettlementConfigRegistered`, `SettlementConfigApproved`) |

## VEN — Venues

| ID | Case |
|---|---|
| VEN-001 | `registerMarket` accepts the matching base/quote; rejects a wrong base, wrong quote or wrong chain (INV-51, `MarketRegistered`) |
| VEN-002 | Router buy end-to-end with the mock venue: fees separate, limits enforced, refund exact (INV-50, `VenueTrade`) |
| VEN-003 | Router sell: `minProceeds` enforced; no Optara fee |
| VEN-004 | Deadline passed reverts (`DeadlineExpired`) |
| VEN-005 | The router and adapter end every call with zero balance (INV-50) |
| VEN-006 | Disabling Kuru: mint, transfer, unwrap, close, liquidate, settle, redeem all still work (LIV-3, INV-52) |
| VEN-007 | A Kuru balance never appears as margin (INV-20, INV-52) |
| VEN-008 | Fork test: real Kuru market create, buy, sell (nightly) |
| VEN-009 | Unregistered or inactive market reverts (`MarketNotVerified`); `setMarketStatus` expired hides it (`MarketStatusSet`) |
| VEN-010 | `registerAdapter` timelocked; `setAdapterEnabled(false)` instant for the guardian (`AdapterRegistered`, `AdapterEnabled`) |

## UPG / ACL / PAU — Upgrades, access, pauses

| ID | Case |
|---|---|
| UPG-001 | Storage layout check passes for each module: no plain storage, every ERC-7201 slot constant correct (`contract/script/storage_check.py`) |
| UPG-002 | `setImplementationAllowed`, `scheduleUpgrade`, `executeUpgrade`: an upgrade before its eta reverts (`UpgradeNotReady`); a non-allowlisted implementation can't be scheduled; anyone executes after the eta; storage preserved and migration call runs (`ImplementationAllowed`, `UpgradeScheduled`, `UpgradeExecuted`) |
| UPG-003 | Protected storage (terms, wrappers, prices, ratios, redemptions) unchanged across an upgrade (INV-34) |
| UPG-004 | `scheduleEmergencyUpgrade`: council only, shorter delay, no allowlist needed, affected products set close-only immediately and stay so until governance clears them |
| UPG-005 | `deployProxy`: proxy deployed and initialized in one transaction; its ProxyAdmin is owned by UpgradeAdmin; governance or deployer only; an initializer that deploys contracts is rejected (`ProxyDeployed`, `UnknownProxy`) |
| UPG-006 | `cancelUpgrade`: governance cancels any, the council only its own emergency upgrades; cancelled or executed operations can't run again (`UpgradeCancelled`, `UpgradeNotPending`) |
| UPG-007 | A scheduled upgrade is blocked if the implementation's code hash changes or governance removes it from the allowlist (`CodeHashMismatch`, `ImplementationNotAllowed`) |
| UPG-008 | Delays bounded at construction (`InvalidDelay`); zero addresses rejected (`ZeroAddress`); `transferGovernance` / `acceptGovernance` two-step (`GovernanceTransferStarted`, `GovernanceTransferred`); `setEmergencyCouncil` (`EmergencyCouncilSet`); `setProtocolControl` (`ProtocolControlSet`); `renounceDeployer` (`DeployerRenounced`) |
| UPG-009 | Unknown proxy or operation and non-contract implementations revert (`UnknownProxy`, `UnknownUpgrade`, `NotAContract`); `getOperation` and `proxyAdminOf` report state |
| ACL-001 | Every admin function reverts for every other role (role matrix, `NotAuthorized`) |
| ACL-002 | The guardian can pause but not unpause, upgrade or raise limits (INV-53) |
| ACL-003 | Risk-reducing parameter changes instant; risk-increasing ones timelocked (INV-53) |
| ACL-004 | No role can mint wrappers or move account cash directly (INV-35) |
| ACL-005 | `setProductCloseOnly`: guardian, governance or UpgradeAdmin may set, only governance clears; `isProductCloseOnly` and `upgradeAdmin` views (`ProductCloseOnlySet`) |
| ACL-006 | `grantRole` / `revokeRole`: governance only; GOVERNANCE is the default admin role; the deployer holds no role after setup (`RoleGranted`, `RoleRevoked`) |
| PAU-001 | Each pause bit blocks exactly its functions, in global, asset and product scope (`ActionPaused`, `Paused`); unpause is governance only (`Unpaused`) |
| PAU-002 | Pausing a bit never blocks unrelated actions (e.g. pausing MINT leaves CLOSE and SETTLE working) |
| PAU-003 | Scope ids must match their scope and bits must be defined and non-zero (`InvalidScope`, `InvalidPauseBits`); `pausedBits`, `isPaused`, `requireNotPaused` agree with the union of global, asset and product masks |

## GAS / E2E / EVT

| ID | Case |
|---|---|
| GAS-001 | Risk check at max positions ≤ `maxRiskCheckGas` |
| GAS-002 | Settlement batch of 20 within the block limit |
| GAS-003 | Every function containing a loop is benchmarked at its configured maximum; no loop depends on user count (INV-36) |
| E2E-001 | F1 → F2 → F9 → F13 full lifecycle, ratio 1 |
| E2E-002 | Market crash/rally, liquidation, expiry with shortfall, insurance, ratio < 1 |
| E2E-003 | Publisher outage → close-only → recovery |
| E2E-004 | Oracle stall at expiry → late finalize |
| EVT-001 | Every event in [PROTOCOL_SPEC.md](PROTOCOL_SPEC.md) §14 is emitted by at least one test with all fields asserted (generated checklist) |

## SVC — Off-chain services

| ID | Case |
|---|---|
| KPR-001 | Settlement keeper finalizes, settles every participant in batches and computes the ratio for a group with 200 accounts |
| KPR-002 | Liquidation bot starts auctions and takes profitable slices; restarts safely |
| PUB-001 | Publisher produces reports that pass every on-chain check; refuses to sign on calendar/butterfly arbitrage or an ATM move above the limit |
| PUB-002 | `/oracle-update` returns an `OracleUpdate` whose proofs verify on-chain for an account's positions |
| IDX-001 | The indexer rebuilds every balance, total, supply and participant count from events, equal to chain state |
| IDX-002 | The indexer survives a reorg and duplicate events without corrupting state |
| FE-001 | Action buttons enabled/disabled per [STATE_MACHINE.md](STATE_MACHINE.md) for every state |
| FE-002 | Risk-increasing transactions fetch a fresh `OracleUpdate` and re-preview before sending |
| FE-003 | Disclosures must be acknowledged before mint and buy flows |
| FE-004 | Every error in [PROTOCOL_SPEC.md](PROTOCOL_SPEC.md) §13 maps to a readable message |

## REF — Reference model (runs today, no contracts needed)

| ID | Case |
|---|---|
| REF-001 | `reference/verify_math.py` passes all 24 checks (theorems, properties, every MATH.md example) |
| REF-002 | `reference/verify_invariants.py` passes (random actions + full settlement, all `sim` invariants) |
| REF-003 | `reference/check_traceability.py` passes (this catalog covers every invariant, function and error) |

---

## Appendix A — Invariant → tests

| Invariant | Tests |
|---|---|
| INV-1 | CLR-004, CLR-014, REF-002 |
| INV-2 | CLR-017, REF-002 |
| INV-3 | CLR-004, CLR-009, REF-002 |
| INV-4 | CLR-007, STL-013, REF-002 |
| INV-5 | CLR-008 |
| INV-6 | CLR-012, REF-002 |
| INV-7 | CLR-015, REF-002 |
| INV-8 | CLR-015, REF-002 |
| INV-9 | CLR-004, FEE-003, REF-001 |
| INV-10 | FEE-007 |
| INV-11 | CLR-004, CLR-009, CLR-011, CLR-002, REF-002 |
| INV-12 | CLR-005, CLR-018, SPT-003 |
| INV-13 | CLR-007, CLR-011, CLR-015, MRG-005, REF-001, REF-002 |
| INV-14 | MRG-006, REF-001, REF-002 |
| INV-15 | MRG-004, REF-001 |
| INV-16 | VOL-011, REF-001 |
| INV-17 | VOL-003 |
| INV-18 | SPT-002 |
| INV-19 | VOL-009, VOL-013 |
| INV-20 | VEN-007 |
| INV-21 | LIQ-001, REF-002 |
| INV-22 | LIQ-002, LIQ-003, REF-001, REF-002 |
| INV-23 | LIQ-004, LIQ-016, REF-002 |
| INV-24 | LIQ-013, REF-002 |
| INV-25 | LIQ-008, REF-002 |
| INV-26 | STL-001, REF-002 |
| INV-27 | CLR-013, REF-002 |
| INV-28 | STL-007, STL-021, REF-002 |
| INV-29 | STL-010, REF-001, REF-002 |
| INV-30 | STL-008, REF-001, REF-002 |
| INV-31 | STL-012, REF-001, REF-002 |
| INV-32 | STL-011, REF-001, REF-002 |
| INV-33 | STL-005, REF-002 |
| INV-34 | UPG-001, UPG-003, SER-005 |
| INV-35 | ACL-004 |
| INV-36 | GAS-001, GAS-002, GAS-003 |
| INV-37 | FEE-008, FEE-009, REF-002 |
| INV-38 | PRC-003, PRC-005, PRC-007, REF-001 |
| INV-39 | PRC-001, PRC-002, REF-001 |
| INV-40 | VOL-010, REF-001 |
| INV-41 | MRG-011, REF-001 |
| INV-42 | CLR-019 |
| INV-43 | CLR-020 |
| INV-44 | FEE-001, FEE-002, FEE-006, REF-001 |
| INV-45 | LIQ-015 |
| INV-46 | LIQ-012, LIQ-017, REF-002 |
| INV-47 | STL-017, REF-001, REF-002 |
| INV-48 | STL-018, REF-002 |
| INV-49 | STL-009, STL-019, REF-001 |
| INV-50 | VEN-002, VEN-005 |
| INV-51 | VEN-001 |
| INV-52 | MRG-009, VEN-006, VEN-007 |
| INV-53 | ACL-002, ACL-003, ACL-005, PAU-001 |
| LIV-1 | CLR-021, REF-002 |
| LIV-2 | STL-020, KPR-001, REF-002 |
| LIV-3 | LIQ-014, VEN-006 |

## Appendix B — Function → tests

| Function | Tests |
|---|---|
| createSubAccount | ACC-001, ACC-002 |
| addCash / subCash / applyDelta | ACC-007, ACC-008, CLR-012, CLR-013, CLR-017 |
| bucketsOf / seriesCountInGroup | ACC-008, CLR-013 |
| setPositionLimits / setMinPositionQty | ACC-009, CLR-020 |
| setOperator | ACC-003, ACC-004 |
| createSeries | SER-001, SER-002, SER-003, SER-004, SER-009 |
| setSettlementAssetApproved | SER-008 |
| deployWrapper / predictWrapper | SER-001, SER-010 |
| getGroup / getProduct | SER-006, SER-007 |
| approveProduct | SER-007 |
| setProductEnabled | SER-007 |
| depositCollateral | CLR-001, CLR-015, CLR-021 |
| withdrawCollateral | CLR-002, CLR-003, PRV-002 |
| mintExternalLong | CLR-004, CLR-005, CLR-006, CLR-019, PRV-001 |
| wrapLong | CLR-009, PRV-002 |
| unwrapLong | CLR-007, CLR-008, CLR-021 |
| closeShortWithWrapper | CLR-010, CLR-021 |
| closeShortWithInternalLong | CLR-011 |
| updateOracles | CLR-016 |
| setRiskParameterSet | MRG-012 |
| setProductCloseOnly / isProductCloseOnly / upgradeAdmin | ACL-005, UPG-004 |
| startAuction | LIQ-001, LIQ-015, LIQ-017 |
| liquidateSlice | LIQ-002, LIQ-003, LIQ-004, LIQ-005, LIQ-007, LIQ-008, LIQ-009, LIQ-016 |
| liquidateWithWrapper | LIQ-010 |
| endAuction | LIQ-011 |
| finalizeGroup | STL-001, STL-002, STL-003, STL-004 |
| settleAccountGroup | STL-006, STL-018 |
| settleAccountsGroup | STL-015 |
| computeRecoveryRatio | STL-007, STL-008, STL-009, STL-010 |
| claimSettlement | STL-014, STL-018 |
| redeemWrapper | STL-011, STL-013, STL-021 |
| sweepDust | STL-016 |
| setFeeRates | FEE-006 |
| setSplit | FEE-010 |
| withdrawTreasury | FEE-007 |
| setMinimums | FEE-010 |
| deposit (InsuranceFund) | FEE-009 |
| update (LiveSpotOracle) / updateFee | SPT-001, SPT-002, SPT-004, SPT-006 |
| spotPrice / requireFreshSpot / isSpotFresh | SPT-001, SPT-003 |
| setSource | SPT-005 |
| submitReport | VOL-001 – VOL-008 |
| proveNodes / nodeValue | VOL-009, VOL-013 |
| header / kNodes / reportDigest / surfaceStatus | VOL-001, VOL-011, VOL-015 |
| setQuorum / isPublisher | VOL-014 |
| setSurfaceConfig | VOL-015 |
| addPublisher / removePublisher | VOL-014 |
| setEmergencyMode | VOL-007 |
| registerConfig / setConfigApproved / isConfigUsable / stalledAfter | STL-022 |
| verify / earliestFinalization / isImmediateSuccessor | STL-001, STL-002, STL-003 |
| registerMarket / setMarketStatus | VEN-001, VEN-009 |
| buyThroughVenue | VEN-002, VEN-004, FEE-004 |
| sellThroughVenue | VEN-003, FEE-005 |
| registerAdapter / setAdapterEnabled | VEN-010 |
| pause / unpause | PAU-001, PAU-002 |
| pausedBits / isPaused / requireNotPaused | PAU-001, PAU-003 |
| grantRole / revokeRole | ACL-006 |
| setImplementationAllowed / scheduleUpgrade / executeUpgrade | UPG-002, UPG-007 |
| scheduleEmergencyUpgrade | UPG-004 |
| cancelUpgrade | UPG-006 |
| deployProxy / proxyAdminOf | UPG-005 |
| getOperation | UPG-002, UPG-009 |
| transferGovernance / acceptGovernance / setEmergencyCouncil / setProtocolControl / renounceDeployer | UPG-008 |
| implementationAllowed | UPG-002 |
| All views and previews | PRV-001 – PRV-005 |

## Appendix C — Error → tests

| Error | Tests |
|---|---|
| NotAuthorized | ACC-005, ACL-001 |
| ZeroAmount | CLR-022 |
| InvalidRecipient | CLR-022 |
| UnknownSeries | CLR-022, SER-006 |
| UnknownAccount | ACC-006 |
| AssetMismatch | CLR-008 |
| SeriesNotActive | CLR-006 |
| GroupFinalized | CLR-010, STL-001 |
| GroupNotFinalized | STL-021 |
| ProductCloseOnly | CLR-018 |
| InsuranceBelowMinimum | CLR-018 |
| ActionPaused | PAU-001 |
| StaleSpot | SPT-003 |
| StaleSurface | CLR-005 |
| MissingSurfaceNode | VOL-013 |
| SeriesNotPriceable | SER-004 |
| AssetNotApproved | SER-003, SER-008 |
| UnsupportedDecimals | SER-008 |
| InvalidProductConfig | SER-007 |
| ProductNotEnabled | SER-003, SER-007 |
| InvalidSeriesParams | SER-003 |
| SeriesExists | SER-002 |
| GroupFull | SER-009 |
| InsufficientCash | CLR-022, ACC-007 |
| NotHealthy | CLR-002 |
| InsufficientShort | CLR-022 |
| InsufficientLong | CLR-022 |
| PositionLimit | CLR-020 |
| InvalidLimits | ACC-009 |
| PositionBelowMinimum | CLR-012 |
| OpenInterestCap | CLR-019 |
| FeeTooHigh | FEE-002 |
| DeadlineExpired | VEN-004 |
| SlippageExceeded | LIQ-009 |
| MarketNotVerified | VEN-009 |
| NotLiquidatable | LIQ-001 |
| AuctionNotActive | LIQ-017 |
| AuctionActive | LIQ-017 |
| SliceOutOfBounds | LIQ-005 |
| HealthNotImproved | LIQ-003 |
| NotParticipant | STL-018 |
| SettlementIncomplete | STL-007 |
| RatioAlreadySet | STL-010 |
| RatioNotSet | STL-021 |
| NothingToClaim | STL-018 |
| InvalidSurfaceReport | VOL-002 |
| InvalidSignatures | VOL-005 |
| InvalidSettlementProof | STL-002 |
| FinalizationTooEarly | STL-002 |
| NonExactTransfer | CLR-001 |
| InvalidSpotSource | SPT-005, SPT-006 |
| InvalidSpotPrice | SPT-006 |
| InsufficientProviderFee | SPT-004 |
| RefundFailed | SPT-004 |
| InvalidSurfaceConfig | VOL-014, VOL-015 |
| InvalidPublisher | VOL-014 |
| InvalidSettlementConfig | STL-022 |
| UnknownSettlementConfig | STL-022 |
| SettlementConfigExists | STL-022 |
| ZeroAddress | UPG-008 |
| NotAContract | UPG-009 |
| InvalidScope | PAU-003 |
| InvalidPauseBits | PAU-003 |
| InvalidDelay | UPG-008 |
| UnknownProxy | UPG-005, UPG-009 |
| ImplementationNotAllowed | UPG-002, UPG-007 |
| UnknownUpgrade | UPG-009 |
| UpgradeNotPending | UPG-006 |
| UpgradeNotReady | UPG-002 |
| CodeHashMismatch | UPG-007 |
