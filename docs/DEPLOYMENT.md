# Deployment

## 1. Environments

| Environment | Purpose | How |
|---|---|---|
| Local (anvil) | Development; mock oracles, mock publishers, mock venue | `script/local/LocalStack.s.sol` (§4.1) |
| Fork rehearsal | The production scripts end to end on an anvil fork of testnet or mainnet: real Pyth, real Kuru router, throwaway roles | `script/rehearse_fork.sh` (§4.2) |
| Monad testnet | Full rehearsal with real Pyth/Chainlink, real publishers (Kuru: mainnet only, see below) | `script/Deploy.s.sol` (§4.3) |
| Monad mainnet | Production, phased activation | `script/Deploy.s.sol` (§4.3) |

`KuruAdapter` targets Kuru's mainnet Router (verified on a mainnet fork, VEN-008). Testnet's Kuru is a different
deployment ("Spot V2") that this adapter has not been verified against, so the testnet config has no Kuru router and
no adapter is deployed there.

## 2. Deployment order

Implemented by `contract/script/OptaraDeploy.sol` (shared by the broadcast script and the E2E tests, so the tests
run exactly what ships); it checks every predicted address and that the deployer ends with nothing.

1. `UpgradeAdmin` (timelock + allowlist), with governance and guardian multisigs.
2. Implementations and proxies, each deployed by `UpgradeAdmin.deployProxy` and initialized in the same transaction
   (no takeover window). Proxy addresses are computed in advance from `UpgradeAdmin`'s nonce (one `CREATE` per proxy),
   so every initializer receives the final addresses of the modules it calls; there are no later wiring setters:
   `SubAccounts`, `OptionSeriesRegistry`, `ExternalOptionFactory` (with the wrapper implementation),
   `LiveSpotOracle`, `VolSurfaceOracle`, `SettlementOracle`, `PortfolioRiskManager`, `FeeController`,
   `InsuranceFund`, `OptionClearing`, `LiquidationModule`, `SettlementWindow`, `VenueRegistry`, `VenueRouter`.
3. Wire internal permissions (ledger writers, wrapper minter/burner, insurance cover callers, fee collectors).
4. `KuruAdapter` (constructor: the `VenueRouter` and Kuru's Router); register it in the `VenueRegistry` (disabled).
   Kuru's `deployProxy` is owner-gated, so each series' Kuru market (base = wrapper, quote = settlement asset) must be
   created by Kuru; the venue admin then registers it. Agree this with Kuru before launch.
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

### 3.1 Files

| File | Written by | Contents |
|---|---|---|
| `deployments/config/<network>.json` | Ops (committed; public addresses only) | Chain id, role holders (multisigs / timelock), Pyth, Kuru Router, delays, quorum, account limits. `Deploy.s.sol` refuses any zero role address |
| `deployments/<network>.json` | `Deploy.s.sol` | The manifest (§3.2) |
| `deployments/config/<network>.<listing>.json` | Ops (committed templates) | One product listing (§3.3). `ProposeListing.s.sol` refuses zero addresses and a zero insurance seed or keeper reserve minimum |
| `deployments/<network>.<listing>.proposals.json` | `ProposeListing.s.sol` | The ordered calls of the listing (§3.3), unsent |
| `deployments/abi/<Contract>.json` | `script/export_abis.py` | ABIs of the 15 modules (call a proxy with its module's ABI), `UpgradeAdmin`, `ExternalOptionWrapper`, `KuruAdapter`. CI fails if they differ from the build. Errors raised by one module surface through others, so decode reverts against all of them |
| `deployments/local.json` | `LocalStack.s.sol` | The local manifest plus the mocks, ids, series and books under `extra` |

A dry run (no `--broadcast`) writes `<network>.dry-run.json` instead of the manifest. Fork rehearsals write
`rehearsal-*` files and broadcast logs under `deployments/rehearsal-broadcast/` (all git-ignored), so
`contract/broadcast/<chainId>/` only ever holds real deployments.

### 3.2 Manifest

```text
network, chainId
deployedAtBlock      the block the script simulated against: a lower bound for indexers
deployer             holds nothing after deployment (Verify.s.sol checks)
upgradeAdmin         UpgradeAdmin (not a proxy)
kuruAdapter          zero when the network has no Kuru router
roles                governance, guardian, council, riskAdmin, oracleAdmin, seriesCreator, venueAdmin,
                     upgradeDelay, emergencyDelay
proxies.<Module>     proxy, implementation (EIP-1967 slot), proxyAdmin, implementationCodeHash
extra                network-specific (local: mocks, product / config / risk-set ids, series, Kuru books, accounts)
```

`script/Verify.s.sol` re-reads every value from the chain: each proxy's implementation slot, admin slot,
`UpgradeAdmin.proxyAdminOf` record, ProxyAdmin owner and implementation code hash; `ProtocolControl.upgradeAdmin`;
UpgradeAdmin's governance, emergency council, delays and renounced deployer seat; every role holder; and that the
deployer holds none of the six roles. ProtocolControl is not enumerable, so additional role holders are found from
`RoleGranted` events (indexer), not by this script.

### 3.3 Listing a product

`script/ListingCalls.sol` builds the ordered calls with the PARAMETERS.md defaults (risk set, surface config, spot
source limits); the listing file supplies the product-specific values. Each call names the role that must send it:

| # | Role | Call |
|---|---|---|
| 1 | governance | `OptionSeriesRegistry.setSettlementAssetApproved` (when the asset is new) |
| 2 | governance | `OptionSeriesRegistry.approveProduct` (series bounds, symbols) |
| 3–5 | governance | `PortfolioRiskManager.createRiskSet`, `assignProductRiskSet`, `setProductShortCap` |
| 6 | governance | `LiveSpotOracle.setSource` (Pyth feeds; `maxSpotAge` 60, `maxConfidenceBps` 100) |
| 7 | governance | `VolSurfaceOracle.setSurfaceConfig` |
| 8… | governance | `VolSurfaceOracle.addPublisher` per publisher |
| next | oracleAdmin | `SettlementOracle.registerConfig` |
| next | governance | `SettlementOracle.setConfigApproved` |
| next | governance | `FeeController.setMinSellerFee`, `setRewards`; `LiquidationModule.setMaxInsurancePerLiquidation` |
| next | riskAdmin | `FeeController.setMinimums` (insurance seed, keeper reserve): the asset's products are close-only until both are funded |
| next | governance | `VenueRegistry.setAdapterEnabled(KURU)` (when the network has the adapter) |
| last 4 | treasury | approve + `InsuranceFund.deposit`; approve + `FeeController.fundKeeperReserve` |

Governance calls go through the parameter timelock, so propose them as one batch and send the oracleAdmin call
before the timelock executes (the approval needs the registered config). Execute in file order. The fork rehearsal
(§4.2) sends every call from a distinct key per role, which checks each call's role.

After listing: the series creator creates series (`OptionSeriesRegistry.createSeries`); Kuru creates each series'
market (base = wrapper, quote = settlement asset; `deployProxy` is owner-gated); the venue admin registers it
(`VenueRegistry.registerMarket`); publishers start reporting; the spot updater starts pushing.

## 4. Runbook

All commands run from `contract/`. Contracts exceed EIP-170's 24 KB (`PortfolioRiskManager`: 26.2 KB; Monad allows
128 KB), so anvil runs with `--code-size-limit 131072` and `forge script` with `--disable-code-size-limit`.

### 4.1 Local stack

```bash
anvil --code-size-limit 131072
forge script script/local/LocalStack.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --disable-code-size-limit
NETWORK=local forge script script/Verify.s.sol --rpc-url http://127.0.0.1:8545
forge script script/local/Smoke.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

The stack uses the production `OptaraDeploy`, the same listing batch a real network proposes, and anvil's default
mnemonic: account 0 deployer and treasury, 1 governance and every admin role, 2 and 3 publishers, 4 keeper, 5–9
users with 100,000 mock USDC each. It lists ETH/USDC (mock Pyth, mock Chainlink-style settlement feed, mock Kuru),
creates two weekly expiries × 4 strikes × call/put with a Kuru book each, publishes a first spot (4,000) and a
signed 60% surface, and writes `deployments/local.json`. Smoke: account 5 deposits, mints one 4500 call with a fresh
oracle update in the same transaction and sells it through the router; account 6 buys it back through the router.
CI runs all four commands on every push (`deploy` job).

### 4.2 Fork rehearsal

```bash
script/rehearse_fork.sh monad-mainnet https://rpc.monad.xyz
script/rehearse_fork.sh monad-testnet https://testnet-rpc.monad.xyz   # step 7 needs PYTH_UPDATE (below)
```

On an anvil fork, with throwaway role holders: `Deploy.s.sol`, `Verify.s.sol`, stand-in tokens and settlement
feeds with the real Pyth feed ids, `ProposeListing.s.sol`, every proposal sent by its role's key, then a smoke:
a real signed Pyth update (the newest ETH/USD push found on the live chain, or `PYTH_UPDATE=<hex>`) replayed
through `OptionClearing.updateOracles`, a signed surface, and one ATM weekly call written against the live
ETH/USD ÷ USDC/USD spot. Nightly CI runs it on a mainnet fork.

Observed 2026-10-07: mainnet Pyth ETH/USD and USDC/USD are pushed every ~30–60 s by a third party; testnet's had
not been updated for 8 days, so testnet needs Optara's own spot updater (INDEXER_AND_KEEPERS.md §2). Hermes'
update endpoint (`/v2/updates/price/latest`) now answers 401 without an API key: the spot updater needs one.

### 4.3 Testnet and mainnet

1. Fill `deployments/config/<network>.json` with the role holders (multisigs, timelock). Fund the deployer:
   dry runs on 2026-10-07 estimated 54.5M gas on testnet (≈ 11 MON at 203 gwei) and 71M on mainnet (≈ 14.3 MON at
   202 gwei).
2. Dry run (simulates against the live chain, sends nothing, writes `<network>.dry-run.json`):
   `NETWORK=<network> DEPLOYER_PRIVATE_KEY=… forge script script/Deploy.s.sol --rpc-url <rpc> --disable-code-size-limit`
3. Broadcast: the same with `--broadcast --slow` (add `--verify` with the explorer's verifier settings; or verify
   afterwards with `forge verify-contract`). Commit `deployments/<network>.json` and
   `contract/broadcast/Deploy.s.sol/<chainId>/run-latest.json`.
4. `NETWORK=<network> forge script script/Verify.s.sol --rpc-url <rpc>`; publish the manifest's code hashes.
5. `python3 script/export_abis.py` (CI checks they match the build).
6. Fill `deployments/config/<network>.<listing>.json`;
   `NETWORK=<network> LISTING=<listing> forge script script/ProposeListing.s.sol --rpc-url <rpc>`; propose
   `deployments/<network>.<listing>.proposals.json` to the role holders (§3.3).
7. After execution: series, Kuru markets and their registration (§3.3); start publishers, keepers, indexer.

## 5. Launch gates (all must be true)

- [ ] Two independent audits complete; all high and critical findings fixed.
- [ ] All tests in [TEST_CASES.md](TEST_CASES.md) pass; coverage gates met; nightly invariant runs clean for 7 days.
- [ ] Gas benchmarks within targets at the configured maximums.
- [ ] Publishers live on testnet for 14 days with ≥ 99.9% report uptime.
- [ ] Settlement keeper and liquidation bot (≥ 2 instances each) tested on testnet through at least 3 expiries,
      including a forced liquidation and a forced shortfall.
- [ ] Insurance seed and keeper reserve funded at or above the minimums.
- [ ] Monitoring and alerts live ([SECURITY.md](SECURITY.md) §5).
- [ ] Frontend disclosures reviewed.
- [ ] Incident runbooks (§7) rehearsed.
- [ ] Fork rehearsal (§4.2) passes for the final commit on both networks; testnet deployed from the same commit and
      verified (`Verify.s.sol`); explorer source verification done; code hashes published.
- [ ] Role holders in `deployments/config/monad-mainnet.json` are the audited multisigs / timelock; deployer funded
      from a fresh key and left holding nothing.
- [ ] Listing files filled (tokens, settlement feeds checked against the feed operator's registry, publishers,
      reserve minimums from the risk review); proposals reviewed call by call before proposing.
- [ ] Kuru has created the launch series' markets; the venue admin has registered them.

## 6. Phased activation

| Phase | Enabled | Limits |
|---|---|---|
| 0 | Contracts deployed, everything close-only | — |
| 1 | ETH/USDC only, a few weekly expiries | Low OI caps; router + Kuru enabled |
| 2 | BTC/USDC; monthly expiries | Raise caps based on insurance size |
| 3 | MON/USDT | Synthetic IV policy, conservative caps and floors |
| 4 | Parameter tuning (OD-1 horizon calibration) | After observed liquidation performance |

Each phase change is a timelocked governance action announced in advance.

## 7. Incident runbooks

| Incident | Immediate action | Follow-up |
|---|---|---|
| Publisher outage | Nothing (auto close-only at `maxSurfaceStale`); guardian may set close-only earlier | Restore publishers; confirm the surface; clear close-only |
| Suspicious surface (IV divergence) | Guardian: product close-only; remove the publisher | Investigate; rotate keys |
| Spot provider outage | New risk blocks automatically | Switch the source (timelocked) if prolonged |
| Settlement oracle missing at expiry | Nothing; keepers retry with the round proof | `ORACLE_STALLED` after the deadline; announce |
| Insurance below minimum | Products go close-only automatically | Recapitalize via `InsuranceFund.deposit` |
| Exploit | Guardian pauses affected bits | Emergency upgrade; post-mortem before unpausing |
| Kuru outage | Guardian disables the Kuru adapter (optional) | Nothing else; clearing unaffected |
