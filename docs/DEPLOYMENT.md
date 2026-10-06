# Deployment

## 1. Environments

| Environment | Purpose |
|---|---|
| Local (anvil) | Development; mock oracles, mock publishers, mock venue |
| Monad testnet | Full rehearsal with real Pyth/Chainlink, real Kuru, real publishers |
| Monad mainnet | Production, phased activation |

## 2. Deployment order

1. `UpgradeAdmin` (timelock + allowlist), with governance and guardian multisigs.
2. Implementations and proxies, each deployed by `UpgradeAdmin.deployProxy` and initialized in the same transaction
   (no takeover window). Proxy addresses are computed in advance from `UpgradeAdmin`'s nonce (one `CREATE` per proxy),
   so every initializer receives the final addresses of the modules it calls; there are no later wiring setters:
   `SubAccounts`, `OptionSeriesRegistry`, `ExternalOptionFactory` (with the wrapper implementation),
   `LiveSpotOracle`, `VolSurfaceOracle`, `SettlementOracle`, `PortfolioRiskManager`, `FeeController`,
   `InsuranceFund`, `OptionClearing`, `LiquidationModule`, `SettlementWindow`, `VenueRegistry`, `VenueRouter`.
3. Wire internal permissions (ledger writers, wrapper minter/burner, insurance cover callers, fee collectors).
4. `KuruAdapter`; register it in the router (disabled).
5. Grant roles; renounce the deployer's roles. Verify the deployer holds nothing.
6. Verify all contracts on the explorer; publish code hashes.

## 3. Configuration (before any risk)

| Item | Source |
|---|---|
| Approved settlement assets (USDC, USDT) with decimals | Ops review |
| Products (ETH/USDC, BTC/USDC, MON/USDT…) with series bounds | [PARAMETERS.md](PARAMETERS.md) §9 |
| Spot sources per product (Pyth feed ids) | Verified at deploy time |
| Settlement oracle configs (Chainlink feeds, offsets, delays) | Verified at deploy time |
| Publisher set and quorum; independent-group membership | Signed agreements |
| Risk parameter sets per product | [PARAMETERS.md](PARAMETERS.md) §2–§5 |
| Fee rates and split | [PARAMETERS.md](PARAMETERS.md) §6 |
| Insurance seed and keeper reserve deposited | Treasury |
| OI caps (start low) | Risk review |

The deployment manifest `deployments/<network>.json` lists all addresses, ABIs, code hashes and configuration.
Frontend, SDK, indexer and keepers read it.

## 4. Launch gates (all must be true)

- [ ] Two independent audits complete; all high and critical findings fixed.
- [ ] All tests in [TEST_CASES.md](TEST_CASES.md) pass; coverage gates met; nightly invariant runs clean for 7 days.
- [ ] Gas benchmarks within targets at the configured maximums.
- [ ] Publishers live on testnet for 14 days with ≥ 99.9% report uptime.
- [ ] Settlement keeper and liquidation bot (≥ 2 instances each) tested on testnet through at least 3 expiries,
      including a forced liquidation and a forced shortfall.
- [ ] Insurance seed and keeper reserve funded at or above the minimums.
- [ ] Monitoring and alerts live ([SECURITY.md](SECURITY.md) §5).
- [ ] Frontend disclosures reviewed.
- [ ] Incident runbooks (§6) rehearsed.

## 5. Phased activation

| Phase | Enabled | Limits |
|---|---|---|
| 0 | Contracts deployed, everything close-only | — |
| 1 | ETH/USDC only, a few weekly expiries | Low OI caps; router + Kuru enabled |
| 2 | BTC/USDC; monthly expiries | Raise caps based on insurance size |
| 3 | MON/USDT | Synthetic IV policy, conservative caps and floors |
| 4 | Parameter tuning (OD-1 horizon calibration) | After observed liquidation performance |

Each phase change is a timelocked governance action announced in advance.

## 6. Incident runbooks

| Incident | Immediate action | Follow-up |
|---|---|---|
| Publisher outage | Nothing (auto close-only at `maxSurfaceStale`); guardian may set close-only earlier | Restore publishers; confirm the surface; clear close-only |
| Suspicious surface (IV divergence) | Guardian: product close-only; remove the publisher | Investigate; rotate keys |
| Spot provider outage | New risk blocks automatically | Switch the source (timelocked) if prolonged |
| Settlement oracle missing at expiry | Nothing; keepers retry with the round proof | `ORACLE_STALLED` after the deadline; announce |
| Insurance below minimum | Products go close-only automatically | Recapitalize via `InsuranceFund.deposit` |
| Exploit | Guardian pauses affected bits | Emergency upgrade; post-mortem before unpausing |
| Kuru outage | Guardian disables the Kuru adapter (optional) | Nothing else; clearing unaffected |
