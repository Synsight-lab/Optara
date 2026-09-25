# Deployment configs

`script/Deploy.s.sol` reads one JSON file (`OPTARA_DEPLOY_CONFIG`) and refuses to deploy if any required value is
missing or malformed (DEPLOYMENT.md section 84). The `*.template.json` files mark every production value as
`REQUIRED`; the script fails on those markers until real, verified values are filled in. Copy a template to
`monad-mainnet.json` / `monad-testnet.json`, fill it, and review it with a second person (section 60).

Values that must come from the launch decisions in PRD.md section 20 (never invented by the build):
stablecoin addresses and decimals, underlyings, pairs and series bounds, Chainlink feed proxies and the
direct/derived path for each pair, observation window and finalization delays, position limits (from gas
benchmarks), exposure caps, governance multisig and timelock delay, guardian/operator addresses.

Units:
- `*Wad` values are 18-decimal fixed point (`10 USDT per MON` = `10000000000000000000`).
- `*Native` values are in the settlement token's own units (6-decimal USDT: `1 USDT` = `1000000`).
  The script converts exposure caps to exact max-payoff numerators: `N = native * 10^(54 - decimals)`.

Safe mode and activation (DEPLOYMENT.md sections 24, 58, 66). A finished deployment has `WRITE` and
`SERIES_CREATION` paused globally, and `verify()` refuses one that is not. Nobody can create risk until the
deployment, manifest and smoke reads have been checked. Activation is then a separate transaction by the unpauser
(or governance through the timelock). `SAFE_MODE_BITS` = `WRITE | SERIES_CREATION` = `4 | 512` = `516`:

```text
OptaraConfig.unpause(0x0000000000000000000000000000000000000000000000000000000000000000, 516)
```

Local development uses `script/local/DeployLocal.s.sol`, which deploys mocks and writes
`deployments/local.json` (never use it for a public network).

```bash
anvil --code-size-limit 131072
forge script script/local/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --code-size-limit 131072

OPTARA_DEPLOY_CONFIG=deploy/monad-testnet.json GIT_COMMIT=$(git rev-parse HEAD) \
  forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC --broadcast --account deployer
```
