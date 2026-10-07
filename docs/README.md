# Optara PM — Documentation

**Optara PM** (portfolio margin) is an on-chain options protocol on Monad. It lets users write and trade
**standard, uncapped European calls and puts** with **portfolio margin**, so writers post less collateral than
the full worst case. In return, the protocol needs live oracles, liquidation and an insurance fund.

Long option claims are **ERC-20 wrapper tokens**, so they trade on external venues. Kuru is the first venue.
Optara clears, margins, liquidates and settles; venues only trade the tokens.

```text
Optara = clearing, margin, wrappers, settlement, liquidation
Kuru   = external order book / secondary market / price discovery
```

These documents replace the capped "V2" design. The original design note is
[`better implementation.md`](better%20implementation.md); where it differs from these documents, these documents
win (see [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) for every difference and why).

---

## Who these docs are for

Engineers and coding agents who will build the contracts, keepers, indexer and frontend. You should know Solidity,
ERC-20 and basic options vocabulary (call, put, strike, expiry, premium). Everything else is explained here, and
[GLOSSARY.md](GLOSSARY.md) defines every term.

## Reading order

| # | Document | Read it to learn |
|---|---|---|
| 1 | [GLOSSARY.md](GLOSSARY.md) | Every term used in these docs, in plain language |
| 2 | [PRD.md](PRD.md) | What we are building, for whom, and what "done" means |
| 3 | [ARCHITECTURE.md](ARCHITECTURE.md) | The contracts, how they connect, and who trusts whom |
| 4 | [OPTION_SPEC.md](OPTION_SPEC.md) | What one option series is: terms, payoff, identity, wrapper token |
| 5 | [MATH.md](MATH.md) | Every formula: pricing, equity, margin, fees, liquidation, settlement, rounding |
| 6 | [MARGIN_AND_RISK.md](MARGIN_AND_RISK.md) | Margin policy: stress scenarios, account health, close-only, staleness |
| 7 | [ORACLES.md](ORACLES.md) | Spot oracle, volatility-surface oracle, settlement oracle |
| 8 | [LIQUIDATION.md](LIQUIDATION.md) | Dutch portfolio-slice auctions, wrapper-burn liquidation, bad debt |
| 9 | [SETTLEMENT.md](SETTLEMENT.md) | Expiry, settlement window, recovery ratio, redemption |
| 10 | [FEES.md](FEES.md) | Seller fee, buyer fee, venue fees, fee split, insurance seed |
| 11 | [VENUES_AND_KURU.md](VENUES_AND_KURU.md) | Venue registry, router, Kuru adapter, future in-house matching |
| 12 | [PROTOCOL_SPEC.md](PROTOCOL_SPEC.md) | Every external function: checks, effects, events, errors |
| 13 | [STATE_MACHINE.md](STATE_MACHINE.md) | Lifecycle of series, groups, accounts, products |
| 14 | [INVARIANTS.md](INVARIANTS.md) | Properties that must always hold |
| 15 | [ACCESS_CONTROL.md](ACCESS_CONTROL.md) | Roles, timelocks, upgrades |
| 16 | [SECURITY.md](SECURITY.md) | Threat model and required mitigations |
| 17 | [PARAMETERS.md](PARAMETERS.md) | Every configurable number with its default |
| 18 | [USER_FLOWS.md](USER_FLOWS.md) | Step-by-step journeys for writers, buyers, liquidators, keepers |
| 19 | [FRONTEND.md](FRONTEND.md) | Pages, data, previews, copy and errors for the web app |
| 20 | [INDEXER_AND_KEEPERS.md](INDEXER_AND_KEEPERS.md) | Indexer, settlement keeper, liquidation bot, surface publisher |
| 21 | [TESTING.md](TESTING.md) | How to test: tools, reference model, invariants, gas, gates |
| 22 | [TEST_CASES.md](TEST_CASES.md) | The required test catalog with IDs |
| 23 | [DEPLOYMENT.md](DEPLOYMENT.md) | Deployment order, configuration, manifests, runbook, launch gates |
| 24 | [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) | Why each choice was made, corrections to the plan, open decisions |

Smart-contract engineers: read 1–17 before writing code, and 21–22 before opening a pull request. Every contract
MUST ship with unit, fuzz, invariant and E2E tests ([TESTING.md](TESTING.md) §0). Frontend engineers: 1–4, 9, 11, 18, 19.
Keeper and indexer engineers: 1–3, 7–9, 20.

## The system in one page

1. **A writer deposits stablecoin** (e.g. USDC) into a **subaccount**.
2. **The writer mints wrapper tokens.** `mintExternalLong` records a short (`-qty`) in the writer's subaccount and
   mints `qty` ERC-20 long tokens. The portfolio risk manager checks the writer still has enough **initial margin**.
3. **The writer sells the tokens** on Kuru (or anywhere). The premium arrives in the writer's wallet, outside Optara.
4. **Buyers hold, trade, or unwrap** the tokens. Unwrapping moves the long into a subaccount, where it can offset
   shorts and reduce margin.
5. **Margin is checked with live data.** Every option is priced on-chain (Black-76) from a **live spot price** and a
   **signed implied-volatility surface**, then stress-tested under spot/volatility/time scenarios.
6. **Accounts below maintenance margin are liquidated** by anyone through a Dutch auction that moves a slice of the
   portfolio to a liquidator.
7. **At expiry, one settlement price is finalized** for the whole risk group. Keepers settle every account. Losses
   that collateral cannot cover go to the **insurance fund**. Only if that is exhausted does everyone with a long
   claim receive the same **recovery ratio** below 100%.
8. **Holders redeem** their tokens for the payoff after the ratio is fixed.

## Verified math

The core math and invariants are checked by executable scripts in [`../reference/`](../reference):
`verify_math.py` (24 property checks and every worked example) and `verify_invariants.py` (stateful simulation of
every action, liquidation and full settlement). See [INVARIANTS.md](INVARIANTS.md) §11.

## Status

Specification only. No PM contracts exist yet on this branch. All parameter values are defaults to be confirmed
before launch (see [PARAMETERS.md](PARAMETERS.md) and the open decisions in [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md)).

## Normative language

**MUST / MUST NOT** = required for correctness or safety. **SHOULD** = strongly recommended; deviating needs a
written reason. **MAY** = optional.

When documents disagree: [MATH.md](MATH.md) wins on formulas and rounding, [PROTOCOL_SPEC.md](PROTOCOL_SPEC.md) on
function behavior, [INVARIANTS.md](INVARIANTS.md) on safety properties, [PARAMETERS.md](PARAMETERS.md) on numbers.
