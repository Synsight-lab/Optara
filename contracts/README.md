# Optara contracts

Solidity implementation of the Optara V1 spec in [`../simple-workflow/`](../simple-workflow/README.md). If this code and the spec ever disagree, that is a bug: fix one of them.

Fully collateralized European call and put options on Monad. Each series is one ERC-20 whose price at expiry comes from one Chainlink feed, proven on chain.

## Layout

```
src/
  OptionSeriesFactory.sol      anyone creates a series; the registry; the two roles; settings
  OptionSeriesVault.sol        one per series: the option ERC-20 and the collateral
  VaultDeployer.sol            holds the vault's creation code (keeps the factory under the size limit)
  PremiumExecutionGuard.sol    read-only advisory checks for a buy or sell
  libraries/OptionMath.sol     every formula that decides who gets what
  libraries/ChainlinkAnchor.sol  the round in force at expiry, and the reference read
  Types.sol  Errors.sol  interfaces/
test/                          unit, fuzz, invariant and reentrancy tests, plus mocks
script/                        Deploy, ConfigurePair, HandOverAdmin, and local/ (mocks + rehearsal)
```

## Setup

Requires [Foundry](https://book.getfoundry.sh/). Dependencies are not committed:

```bash
cd contracts
forge install --no-git foundry-rs/forge-std
forge install --no-git OpenZeppelin/openzeppelin-contracts@v5.1.0
forge build
```

## Test

```bash
forge test                              # 262 tests, about 7 s
FOUNDRY_PROFILE=ci forge test           # 10,000 fuzz runs, 1,024 invariant runs at depth 128
forge coverage --report summary --ir-minimum --no-match-test test_deployment_factoryFitsTheContractSizeLimit
slither . --filter-paths "lib|test|script"
./script/local/rehearsal.sh             # the whole deployment runbook and a full option lifecycle on a local Anvil chain
```

| Suite | What it proves |
|---|---|
| `OptionMath.t.sol` | All six normative vectors from `math.md` bit for bit; the rate identity and single and fragmented solvency, fuzzed |
| `ChainlinkAnchor.t.sol` | Exactly one round qualifies for any expiry (fuzzed); phase boundaries; forged proofs; settling late gives the same price |
| `Vault.t.sol` | Construction, mint, settle, redeem, claim, fees and the freeze; Vectors 1, 3, 5, 6 end to end through the real vault |
| `VaultPayout.t.sol` | Keeper batch payout: pays everyone, never the caller, skips contracts, one failing recipient never blocks the rest, fails loudly on too little gas |
| `VaultMultiWriter.t.sol` | Several writers pooled in one vault: a malicious writer cannot take anyone else's collateral by any route, each writer gets exactly `floor(short * rate / scale)`, and a writer's actions never change what another writer or holder receives (fuzzed) |
| `VaultReentrancy.t.sol` | A hostile token cannot re-enter mint, redeem, claim, sweep or payout |
| `Factory.t.sol` | Permissionless creation, the approved feed per pair, expiry slot, strike step, duplicates revert, generated names, roles, freeze |
| `Guard.t.sol` | Exact-integer bounds by hand, rounding toward rejection, totals not per-option, fee-inclusive limits, empty range |
| `VaultInvariant.t.sol` | 10 invariants on a call vault and on a put vault under random sequences of every action |

Results at the time of writing: 262 tests pass at default and at CI settings. Line coverage is 97 to 100% on every contract in `src/`.

### Mutation checks

Tests are only useful if they fail when the code is wrong. These deliberate bugs were introduced one at a time and each was caught, then reverted:

- removing `nonReentrant` from `mint` and `redeem` (reentrancy tests fail)
- computing `writerResidualRate` independently instead of by subtraction (identity invariant fails)
- rounding claims up instead of down (solvency invariant fails)
- taking the mint fee out of the collateral (three invariants fail)
- letting a writer claim against the pooled short amount instead of only their own (three multi-writer tests fail, and the fuzz test finds a counterexample at once)

### Static analysis

Slither reports two findings, both reviewed as false positives: the "reentrancy" in `createSeries` (the function is `nonReentrant`, and the only other function that touches that state is admin-only), and an intentional destructure of Chainlink's return tuple.

## Sizes (EIP-170 limit 24,576 bytes)

| Contract | Runtime bytes |
|---|---|
| OptionSeriesFactory | 9,133 |
| OptionSeriesVault | 12,179 |
| VaultDeployer | 17,581 |
| PremiumExecutionGuard | 5,092 |

## Status

Built and tested against the spec. **Not audited. Not deployed.** Before any mainnet use:

- an independent audit, and a bug bounty
- confirm Chainlink has a direct feed for every launch pair on Monad, and that two people check each feed before `ConfigurePair` runs
- the keeper (settle with a proof, then `payout`), the proof builder and the frontend do not exist yet
- Kuru's fee behavior is unverified; nothing in the contracts calls Kuru, so this only affects the frontend
- the outage risk (a feed that never publishes after expiry locks that series for ever) is accepted in the V1 design and must be disclosed to users

See `../simple-workflow/security-and-launch.md` for the founder decisions and the launch checklist.
