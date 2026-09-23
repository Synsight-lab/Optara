# Optara Simple V1: Build Spec

This folder is the complete, lean specification for Optara V1. It is enough to build the protocol without reading anything in `../workflow/`. That folder is the earlier, larger design and is kept only for reference.

## What Optara Is

Fully collateralized European call and put options on Monad. Each option series is one ERC-20 token. Writers lock collateral and mint the token. Anyone can trade the token, for example on Kuru. After expiry, the price from a Chainlink feed is used to settle the series once, and then holders redeem and writers reclaim what is left.

```text
The one promise:
Trading changes who owns an option token. It never changes how much collateral the vault owes.
```

## Read In This Order

1. [math.md](./math.md): units, collateral, payout rates, rounding, solvency proof, test vectors.
2. [contracts.md](./contracts.md): the factory and the vault, storage, functions, roles, fees, errors.
3. [oracle.md](./oracle.md): how the Chainlink expiry price is proven and read.
4. [premium-guard.md](./premium-guard.md): the `PremiumExecutionGuard` contract, plus what the frontend must do around Kuru.
5. [testing.md](./testing.md): required tests, invariants, fuzz targets.
6. [security-and-launch.md](./security-and-launch.md): threats, founder decisions, deployment order, launch checklist.

## Contracts (four)

| Contract | Job |
|---|---|
| `OptionSeriesFactory` | Lets anyone create a series within fixed limits, is the canonical registry, holds the two roles, allowlisted assets, the approved feed for each pair, default fees and the fee recipient. |
| `OptionSeriesVault` | One per series. It is the option ERC-20 and holds the collateral. Mint, settle, redeem, claim, sweep fees, plus an optional keeper batch payout (`payout`). Deployed as an EIP-1167 clone, not a plain deployment - see `contracts.md`. |
| `VaultDeployer` | Deploys the one vault implementation, then clones it for every series (EIP-1167). Only the factory can use it. |
| `PremiumExecutionGuard` | Read-only helper that checks a proposed buy or sell against oracle-based bounds and buyer limits. |

Plus two small libraries: `OptionMath` (rounding and rate formulas) and `ChainlinkAnchor` (proof verification and reference reads).

Nothing in these contracts calls Kuru.

## Non-Negotiable Rules

- Fully collateralized. No leverage, margin, borrowing, liquidation or early exercise.
- Calls are collateralized in the underlying. Puts are collateralized in the quote asset.
- One ERC-20 option token per series, deployed by the factory as an EIP-1167 clone. Its parameters are fixed at initialization; there is no setter.
- The settlement price comes only from the series' Chainlink feed, pinned to expiry and proven on chain. It never comes from Kuru.
- Settlement happens once. Its result never changes.
- `writerResidualRate` is always computed as `collateralPerOption - buyerPayoutRate`.
- Protocol fees never come out of the collateral that backs claims.
- Fee rates and every series parameter are fixed at creation.
- Two roles only: `ADMIN` and `PAUSER`. There is no creator role: anyone can create a series.
- A user chooses only the option type, the two assets, the strike, the expiry (at most 30 days out, on a daily slot) and the feed. The feed must be the one `ADMIN` approved for that pair. Everything else is fixed by the factory.
- Creating a series that already exists reverts.
- Payouts are pull-based. A keeper may trigger them for people, but always pays the owner, never the caller.
- `ADMIN` or `PAUSER` can freeze minting on a series or freeze series creation. `PAUSER` cannot unfreeze. A freeze never blocks settle, redeem, claim, payout or transfers.
- No role can move collateral, change a series, change a settlement result, or block settle, redeem or claim.

## What Was Deliberately Left Out

These were in the larger design and are not needed for a safe V1:

| Left out | Why |
|---|---|
| Second oracle (Pyth), quorum, deviation and confidence checks | One oracle is simpler. Caps in the guarded launch limit the exposure. Corroboration is a V2 option. |
| OracleRouter and oracle adapters | The vault reads Chainlink directly through a library. |
| Separate registry and `ProtocolConfig` contracts | Folded into the factory. |
| Pause on settle, redeem or transfer | Only minting can be paused, so no role can block users' money. |
| Creator role and user-chosen series parameters | Users choose only six things. The factory fixes contract size, minimum amount, cap, age window, fees and the generated name. |
| Depth, spread and price-impact checks on chain | These need Kuru order-book reads. The frontend does them. |

## Build Order

1. `OptionMath` and its tests, starting with the six vectors in `math.md`.
2. `OptionSeriesVault` with a mock Chainlink feed: mint, settle, redeem, claim.
3. `ChainlinkAnchor` and its anchor tests.
4. `OptionSeriesFactory`.
5. `PremiumExecutionGuard`.
6. Invariant and fuzz tests.
7. Frontend and keeper (see `premium-guard.md` and the keeper procedure in `security-and-launch.md`).

## Implementation

The contracts are in [`../contracts/`](../contracts/README.md): 286 tests (unit, fuzz, invariant, reentrancy, multi-writer, exhaustive successor proof), all passing, plus deployment scripts and a local rehearsal of the whole runbook. They are not audited and not deployed.

## Pointers

- Solidity `^0.8.24`, Foundry, OpenZeppelin Contracts 5.x (`ERC20`, `AccessControl`, `ReentrancyGuard`, `SafeERC20`, `Math`).
- The larger design is in `../workflow/`. If it conflicts with a file here, this folder wins.
