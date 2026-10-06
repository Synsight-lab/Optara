# Security

## 1. Security goals

1. Margin always reflects live risk; risk can't be opened on stale or forged data.
2. Losses are absorbed in order: account collateral → liquidation → insurance → equal recovery ratio. Never
   first-come-first-served.
3. Series terms and finalized results can't be rewritten.
4. Nothing outside Optara (venues, wallets) is trusted for accounting.
5. Every function finishes in bounded gas.

## 2. Trust assumptions (disclose to users)

| Trusted party | For | If it fails |
|---|---|---|
| Governance multisig + timelock | Upgrades, parameters | Could change logic after the timelock; users must watch announced upgrades |
| Surface publishers (quorum) | Implied volatility | Wrong IV → wrong margin. Bounded by on-chain sanity checks and IV floors/ceilings; products go close-only on outage |
| Spot provider (Pyth/Chainlink) | Live price | Wrong price → wrong margin and liquidation. Staleness limits; derived pairs explicit |
| Chainlink settlement feeds | Expiry price | Wrong or missing price → wrong payoffs or a stalled group |
| Settlement assets (USDC, USDT) | Value and transferability | Issuer freeze or depeg affects that asset only |

Kuru is **not** trusted for anything in clearing.

## 3. Threats and mitigations

| # | Threat | Mitigation |
|---|---|---|
| T1 | **Forged or replayed surface report** | EIP-712 with chainId + contract; distinct-signer quorum; strictly increasing `surfaceSeq`; `expiresAt` |
| T2 | **Colluding or compromised publishers** set low IV to under-margin | IV floor per product; max ATM move per update; independent signer required in every quorum; guardian can remove publishers instantly; monitoring of IV vs CEX |
| T3 | **Cherry-picking an old but valid report** | Older seq can't overwrite newer; staleness limits; risk-increasing actions need age ≤ `surfaceStaleAfter` |
| T4 | **Merkle leaf substitution** | Leaf hash includes productId, seq, tenor and node indexes; sorted-pair proofs |
| T5 | **Spot manipulation** | Pull-oracle price with confidence check; never DEX or Kuru prices; maxSpotAge |
| T6 | **Stale data inflating equity** | Direction-aware stale IV; longs at intrinsic after `maxLongTimeValueStale` |
| T7 | **Liquidation draining a healthy account** | Auction only below MM; mark-value transfers; health must improve; `maxBonus + penalty < 100%` |
| T8 | **Liquidator griefed by price change** | `minCashToLiquidator` / `maxCashFromLiquidator` |
| T9 | **Self-dealing liquidation** (owner liquidates itself for the bonus) | Bonus comes from the owner's own account; the penalty goes to insurance, so it's net negative |
| T10 | **Settlement-counter griefing** (many dust accounts delay redemption) | `minPositionQty`; escalating keeper reward; batch `settleAccountGroup` calls; anyone can settle |
| T11 | **First-come-first-served drain at expiry** | Redemption closed until all participants settle and one ratio is fixed |
| T12 | **False shortfall from double-counted longs** | Netted claims only ([MATH.md](MATH.md) §13.1) |
| T13 | **Router sandwich or MEV** | `maxPremium`, `minProceeds`, venue fee and deadline limits |
| T14 | **Fake market registered as official** | `registerMarket` reads tokens from the venue contract; base/quote must match |
| T15 | **Reentrancy through tokens or adapters** | `nonReentrant` everywhere; checks-effects-interactions; adapters end with zero balance |
| T16 | **Non-standard settlement token** (fee-on-transfer, rebasing) | Balance-difference check on deposit; only approved standard tokens |
| T17 | **Rounding exploits** (many tiny actions) | Rounding always favors the protocol ([MATH.md](MATH.md) §2); `minPositionQty`; `minSellerFeeNative` |
| T18 | **Gas exhaustion** of margin checks | Position, bucket, scenario and node limits; benchmarked `maxRiskCheckGas` |
| T19 | **Malicious upgrade** | 7-day timelock; allowlisted code hash; protected-storage tests; public monitoring |
| T20 | **Insurance drained by one event** | `maxInsurancePerLiquidation`; open-interest caps; seed minimums |
| T21 | **Operator abuse** | Operators can't add operators; owners revoke instantly |
| T22 | **Oracle outage at expiry** | Round-in-force proofs work late; `ORACLE_STALLED`, never an invented price |
| T23 | **Black-76 numeric error** | Bounded-error CDF; clamped IV; differential tests against a high-precision reference |
| T24 | **Circular margin from venue prices** | Venue prices are never an oracle input (INV-20) |

## 4. Required engineering practices

- Solidity 0.8.x checked arithmetic; full-precision `mulDiv`; no `unchecked` blocks outside reviewed math helpers.
- OpenZeppelin upgradeable contracts with ERC-7201 namespaced storage.
- `SafeERC20` for every token transfer.
- No `tx.origin`, no `delegatecall` to user-supplied addresses, no `selfdestruct`.
- Every external call to an adapter or oracle provider happens after state updates, or is followed by explicit
  post-checks.
- Events for every state change ([PROTOCOL_SPEC.md](PROTOCOL_SPEC.md) §14).
- Static analysis (Slither) clean or every finding justified in writing.
- At least two independent audits before mainnet. Audit scope must include the Black-76 library and
  `VolSurfaceOracle`.

## 5. Monitoring (run from day one)

| Alert | Trigger |
|---|---|
| Account below MM with no auction | Any account, after 1 minute |
| Auction at max bonus | Auction older than `auctionDuration` |
| Surface age | > `surfaceStaleAfter` for any product |
| IV divergence | Published ATM IV vs CEX IV beyond a threshold (ETH, BTC) |
| Insurance ratio | Insurance below 2× minimum seed |
| Settlement progress | Participants > 0 one hour after finalization |
| Custody | INV-7 violated |
| Governance | Any `UpgradeScheduled`, publisher change, or parameter change |
