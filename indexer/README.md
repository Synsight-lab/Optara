# @optara/indexer

Non-authoritative read model for Optara V2: event index, reconciliation monitor, read API and optional
permissionless keeper. Nothing here can authorize a state change; safety-critical flows read the chain
(SECURITY.md sections 78-79, COMPOSABILITY.md sections 44-46).

## What it does

- Indexes `OptaraCore`, `OptaraConfig`, `OracleRegistry` and every `OptionToken` (discovered from `SeriesCreated`)
  up to `head - CONFIRMATIONS`, in bounded `BATCH_SIZE` ranges.
- Detects reorgs by comparing stored block hashes, rolls back to the last matching block and rebuilds all derived
  tables by replaying stored events (idempotent under duplicate delivery).
- Reconciles against on-chain views and raises alerts (LIQUIDATION.md section 91): `DEFICIT`, `INDEX_MISMATCH`,
  `ORACLE_STALLED`, `AWAITING_FINALIZATION`, `CAP_PRESSURE`, `ASSET_RESTRICTED`, `ASSET_WIND_DOWN`,
  `VAULT_SHORTFALL` (pooled per-asset identity, MATH.md section 64).
- Builds the unique Chainlink finalization proof for a group (round in force at the observation end, with its
  immediate successor or latest-round proof) and previews it with `quoteSettlementPrice`.
- `--keeper` mode finalizes provable groups and syncs finalized account groups. It never chooses a price.

## Run

```bash
npm install
OPTARA_MANIFEST=../deployments/local.json CHAIN_ID=31337 RPC_URL=http://127.0.0.1:8545 npm start
# optional: KEEPER_PRIVATE_KEY=0x... npm run keeper
```

Environment: `OPTARA_MANIFEST`, `CHAIN_ID`, `RPC_URL` (required; chain id must match the manifest and the RPC);
`START_BLOCK`, `CONFIRMATIONS` (2), `BATCH_SIZE` (1000), `POLL_INTERVAL_MS` (2000), `RECONCILE_EVERY_TICKS` (10),
`DB_PATH`, `PORT` (8787), `CAP_ALERT_BPS` (9000), `KURU_MARKETS` (verified market metadata JSON).

## API

`GET /health`, `/manifest`, `/series`, `/series/:id`, `/groups`, `/groups/:id`, `/groups/:id/finalization-proof`,
`/accounts/:addr` (indexed cash, positions, long balances), `/accounts/:addr/risk` (live `accountRiskState`),
`/accounts/:addr/events`, `/alerts`, `/assets`, `/markets` (only entries whose base is the series option token and
quote its settlement asset, on the configured chain).

## Tests

`npm test` runs unit tests and an end-to-end suite that starts its own anvil, deploys with
`contract/script/local/DeployLocal.s.sol`, and exercises indexing, reorg rollback, reconciliation, proof building,
keeper finalization/sync, redemption and the API.
