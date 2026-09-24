# Optara V2 — Composability Specification

**Document type:** Normative composability, integration-boundary, and external-protocol specification  
**Protocol:** Optara  
**Target:** V2 solvency-first MVP on Monad  
**Version:** 0.2.0-draft  
**Date:** 2026-09-24  
**Status:** Engineering specification; external integrations are non-authoritative

---

## 1. Purpose

This document defines how Optara V2 composes safely with:

- wallets;
- smart-contract accounts;
- Kuru;
- other exchanges;
- market makers;
- vaults;
- routers;
- aggregators;
- bots;
- indexers;
- external DeFi protocols;
- SDKs;
- future lending or structured-product integrations.

Optara is designed to make the **long option claim composable** while keeping the **short liability and solvency accounting controlled by Optara**.

The central design principle is:

```text
long claim
=
freely composable ERC-20

short liability
=
non-transferable internal margin obligation
```

This asymmetry is intentional.

This document must be read together with:

- `ARCHITECTURE.md`
- `PROTOCOL_SPEC.md`
- `OPTION_SPEC.md`
- `INVARIANTS.md`
- `MARGIN_AND_RISK.md`
- `KURU_INTEGRATION.md`
- `ORACLE_AND_SETTLEMENT.md`
- `STATE_MACHINE.md`
- `USER_FLOWS.md`

---

# 2. Composability goals

Optara should support:

```text
permissionless long-token transfer
external exchange trading
market making
smart-wallet custody
vault custody
bot automation
indexing
portfolio analytics
external strategy construction
permissionless holder redemption
```

without allowing external systems to bypass:

```text
margin enforcement
locked-hedge custody
short accounting
series immutability
settlement rules
redemption burn
stablecoin isolation
```

---

# 3. Composability does not mean delegated trust

An external integration may:

```text
read
quote
route
trade
hold
batch
simulate
```

but cannot become authoritative for:

```text
account health
margin requirement
claim existence
short closure
settlement price
redemption amount
```

Only Optara contracts decide those.

---

# 4. System layering

Canonical architecture:

```text
Applications
    |
    +------------------------------+
    |                              |
    v                              v
@optara/sdk                   @optara/kuru
    |                              |
    +------------+                 v
    |            |               Kuru
    v            v
@optara/math   Optara Contracts
                  |
                  +--> ClearingHouse
                  +--> MarginVault
                  +--> RiskEngine
                  +--> SettlementEngine
                  +--> SeriesFactory
                  +--> OptionToken
                  +--> OracleAdapter
```

`@optara/math`, `@optara/sdk`, and `@optara/kuru` are off-chain/non-authoritative packages.

---

# 5. Source-of-truth hierarchy

For economic state:

```text
Optara contracts
>
SDK/indexer/cache/frontend
```

If an indexer says:

```text
free collateral = 5
```

but the contract computes:

```text
free collateral = 3
```

the contract wins.

If Kuru says a user bought a long but the ERC-20 has not returned to Optara custody:

```text
Optara does not recognize it as locked hedge or closed short
```

---

# Part I — Long-token composability

## 6. ERC-20 long token

Every series has a fungible long claim represented by an ERC-20-compatible token.

Recommended properties:

```text
18 decimals
standard transfer
standard transferFrom
non-rebasing
no transfer tax
no arbitrary holder-specific balance mutation
authorized mint/burn only
```

---

## 7. What one long token represents

A long token represents only:

```text
right to the series' deterministic settlement payout
```

It does not represent:

```text
writer identity
writer collateral
premium paid
Kuru position
short liability
```

---

## 8. Transferability

While externally held, a long may be transferred:

```text
wallet -> wallet
wallet -> Kuru
wallet -> vault
wallet -> router
vault -> wallet
Kuru -> wallet
```

subject to standard ERC-20 allowance/custody semantics.

---

## 9. Long ownership controls settlement claim

After finalization:

```text
actual surviving long-token ownership
```

controls redemption rights.

Historical ownership is irrelevant.

---

## 10. Premium history does not travel with token

Suppose:

```text
Alice sold to Bob for 0.50 USDT
Bob sold to Carol for 1.20 USDT
Carol redeems 3 USDT
```

Optara pays:

```text
3 USDT
```

based only on option terms and final settlement.

Optara does not track:

```text
0.50
1.20
```

for claim calculation.

---

# Part II — Short-liability isolation

## 11. Short is internal

A short is recorded:

```text
shortQty[account][seriesId]
```

inside Optara.

It is not a freely transferable ERC-20.

---

## 12. Why short is not composable like long

A short carries:

```text
margin requirement
settlement liability
locked-hedge relationships
per-stablecoin cash encumbrance
```

Transferring it without atomic collateral/risk migration could break solvency.

Therefore core V2 intentionally sacrifices short-token composability for safety.

---

## 13. No synthetic short transfer

Forbidden:

```text
user transfers NFT/token/wrapper
-> Optara assumes short liability moved
```

A future transferable-short design would require:

```text
recipient risk check
collateral migration
hedge migration
same-asset accounting
atomic acceptance
```

and is outside core V2.

---

# Part III — Locked hedge boundary

## 14. External long versus locked long

External long:

```text
composable
transferable
tradeable
not recognized for Optara margin
```

Locked long:

```text
Optara-controlled
non-transferable while locked
recognized by RiskEngine if compatible
cannot simultaneously be externally used
```

---

## 15. Lock transition

To gain margin credit:

```text
external protocol/wallet
        |
        | actual ERC-20 transfer
        v
Optara hedge custody
        |
        v
lockedLongQty
```

A receipt or external accounting balance is not enough.

---

## 16. Unlock transition

Before token leaves Optara:

```text
simulate portfolio without locked quantity
        |
        v
verify post-unlock account health
        |
   +----+----+
   |         |
 safe      unsafe
   |         |
 release   revert
```

---

## 17. No double-use

One long-token unit cannot simultaneously be:

```text
Kuru inventory
Optara locked hedge
external vault collateral
short-close input
redemption claim
```

Custody determines which use is currently possible.

---

# Part IV — Kuru composability

## 18. Kuru role

Kuru provides:

```text
secondary trading
price discovery
liquidity
market making
writer buyback venue
```

Optara provides:

```text
issuance
risk
margin
settlement
redemption
```

---

## 19. Canonical market

For each series:

```text
Base  = exact Optara long ERC-20
Quote = exact series settlement stablecoin
```

Example:

```text
MON/USDT option
-> oMON-USDT-... / USDT
```

---

## 20. Kuru accounting is external

Always preserve:

```text
Kuru USDT balance
!=
Optara USDT margin

Kuru option balance
!=
Optara locked long

Kuru fill
!=
Optara short close
```

---

## 21. Kuru buy-to-close composition

High-level off-chain flow through `@optara/kuru` may be:

```text
discover correct Kuru market
        |
        v
buy exact same-series long
        |
        v
obtain ERC-20 custody
        |
        v
approve/transfer to Optara
        |
        v
closeShort()
```

The final Optara close remains authoritative.

---

# Part V — SDK composability

## 22. `@optara/sdk`

The core SDK may expose:

```text
series discovery
account reads
margin previews
write transaction builder
close transaction builder
lock/unlock
deposit/withdraw
settlement status
redeem
event decoding
```

It is a developer convenience layer.

---

## 23. SDK must not become a trusted oracle

Forbidden:

```text
contract accepts sdkComputedMargin
contract accepts sdkSettlementPrice
contract accepts sdkProofOfKuruFill
```

unless such data is independently verified through an on-chain cryptographic/provider protocol.

---

## 24. SDK preview semantics

Example:

```text
previewWrite()
```

may return:

```text
estimated post-write margin
additional collateral required
affected settlement asset
```

But execution must recompute against current on-chain state.

---

## 25. Stale preview handling

Between preview and transaction inclusion:

```text
account state may change
series state may expire
another transaction may consume collateral
```

Therefore SDK APIs should communicate that previews are:

```text
advisory snapshots
```

not guarantees.

---

# Part VI — `@optara/math`

## 26. Purpose

`@optara/math` is the reference off-chain implementation of:

```text
call payoff
put payoff
critical points
portfolio loss
worst-case loss
margin preview
fixed-point conversion
settlement preview
```

---

## 27. Differential testing

The most important use is:

```text
Solidity RiskEngine
        ==
independent @optara/math result
```

over large fuzzed input sets.

---

## 28. Independence principle

The off-chain implementation SHOULD be independent enough to catch Solidity mistakes.

Do not mechanically generate both implementations from the same buggy code path and call that independent verification.

---

# Part VII — Wallet and smart-account composability

## 29. EOA support

Standard EOA users may:

```text
approve
deposit
write
transfer
lock
close
redeem
```

---

## 30. Smart-contract accounts

Optara SHOULD not assume:

```text
msg.sender is always an EOA
```

where avoidable.

Support standard smart accounts/multisigs through:

```text
ERC-20 allowance
contract calls
recipient parameters
```

---

## 31. Account abstraction

Account-abstraction wallets may wrap transaction submission.

They remain clients.

Optara contracts still enforce all safety conditions.

---

## 32. Recipient flexibility

Functions MAY accept explicit recipient parameters where safe:

```text
write(..., longRecipient)
withdraw(..., recipient)
redeem(..., recipient)
```

Risk ownership must remain unambiguous.

---

# Part VIII — Vault composability

## 33. External vault may hold long tokens

A generic ERC-20 vault may hold Optara longs.

Optara sees:

```text
vault contract
```

as the long-token owner.

The vault may issue its own shares externally.

Those shares are not Optara claims.

---

## 34. Vault redemption responsibility

If an external vault owns long tokens:

```text
vault
```

must redeem or transfer those actual longs.

A vault-share holder cannot directly redeem against Optara unless they first obtain the underlying long token or the vault itself integrates redemption.

---

## 35. Vault shares are not recognized hedges

If a user holds:

```text
ERC-4626-like share
```

whose vault contains Optara longs, Optara core V2 does not recognize the share as margin hedge.

Only actual Optara long tokens under Optara custody count.

---

## 36. Vault insolvency independence

If an external vault mismanages its shares:

```text
Optara option accounting remains unchanged
```

Optara owes only against actual surviving long tokens.

---

# Part IX — Lending composability

## 37. External lending may accept Optara longs

A third-party lending protocol MAY choose to value Optara long tokens as collateral.

That is external policy.

Optara does not guarantee:

```text
liquidity
market value
loan-to-value
liquidation price
```

---

## 38. Lending liquidation transfers claim ownership

If a lending protocol liquidates a borrower and transfers the long token:

```text
new token owner
```

receives the eventual Optara claim.

Optara does not care why ownership changed.

---

## 39. Optara does not recognize debt positions externally

A user's debt in a lending protocol:

```text
does not change
Optara required margin
```

Core V2 only reasons about its own:

```text
cash
shorts
locked longs
```

---

# Part X — Router and aggregator composability

## 40. Off-chain router

A router may orchestrate:

```text
approve stablecoin
deposit
write
move long to Kuru
sell
move proceeds
```

But each Optara call independently enforces safety.

---

## 41. On-chain router

A future on-chain router MAY atomically compose calls.

It must not:

```text
bypass margin check
retain user collateral unexpectedly
fake long custody
close short without burn
substitute settlement asset
```

---

## 42. Router failure atomicity

For a multi-step atomic workflow:

```text
step N fails
```

the transaction SHOULD revert completely unless partial completion is explicitly safe and documented.

---

## 43. Approval minimization

Routers and SDKs SHOULD minimize:

```text
unlimited ERC-20 approvals
```

especially for:

```text
settlement stablecoins
option tokens
```

Permit-style flows MAY be supported if token contracts and security review permit.

---

# Part XI — Indexer composability

## 44. Indexers are read layers

Indexers may reconstruct:

```text
series
positions
events
Kuru markets
settlement state
```

but they are not authoritative.

---

## 45. Indexer eventual consistency

A frontend must tolerate:

```text
indexer lag
chain reorg handling
event delay
```

Safety-critical actions should obtain fresh on-chain reads or rely on transaction revalidation.

---

## 46. Event reconstruction

Events should be sufficient to reconstruct:

```text
series creation
writes
closes
locks
unlocks
deposits
withdrawals
finalizations
syncs
redemptions
```

but core contracts store authoritative state.

---

# Part XII — Bot and keeper composability

## 47. Bots

Bots may automate:

```text
market making
writer buyback
margin monitoring
oracle finalization
matured group synchronization
```

---

## 48. Keeper safety

A keeper performing deterministic maintenance must not choose:

```text
settlement price
writer payout
long payout
recipient of writer collateral
```

The keeper only triggers a pre-defined transition.

---

## 49. No keeper dependency for solvency

Failure of bots/keepers should not make:

```text
active core-V2 bounded option liability
```

exceed collateral.

Keepers improve liveness, not core pre-expiry solvency.

---

# Part XIII — Oracle composability

## 50. Oracle adapters are constrained integrations

Oracle providers are external.

`OracleAdapter` converts provider data into:

```text
one validated normalized pair price
```

for SettlementEngine.

---

## 51. SDK oracle helpers are advisory

The SDK may:

```text
fetch provider data
prepare update bytes
estimate fee
preview normalized price
```

but on-chain adapter validation remains mandatory.

---

# Part XIV — DEX / alternative venue composability

## 52. Kuru is preferred but not exclusive at token level

Because the long is an ERC-20:

```text
another compatible venue
```

may list it.

Optara does not require all trading to occur on Kuru.

---

## 53. Official integrations versus permissionless markets

Anyone may potentially create an external market.

The official frontend/SDK should distinguish:

```text
verified/canonical market metadata
```

from:

```text
arbitrary permissionless market
```

---

## 54. Alternative venue does not alter settlement

If a token trades elsewhere:

```text
Optara payoff remains unchanged
```

No venue market price changes the option's contract.

---

# Part XV — Stablecoin composability

## 55. Each pair chooses its own stablecoin

A protocol-wide integration must not assume:

```text
settlementAsset == USDC
```

Every workflow must read:

```text
series.settlementAsset
```

---

## 56. Generic stablecoin interfaces

SDKs/routers should accept:

```text
settlementAsset address
decimals
symbol only for display
```

Economic logic must use address/config, not symbol text.

---

## 57. No cross-stablecoin convenience conversion in core

A frontend may help users swap externally:

```text
USDC -> USDT
```

before deposit.

But Optara core should receive:

```text
the exact required settlement asset
```

before counting collateral.

---

## 58. Swap router boundary

If a future convenience router swaps collateral before deposit:

```text
swap occurs externally/in router
Optara credits only actual received target stablecoin
```

No expected swap output counts before receipt.

---

# Part XVI — Settlement composability

## 59. Permissionless redemption

Any holder/authorized owner of a settled long should be able to redeem.

No dependency on:

```text
original buyer
original writer
Kuru
official frontend
```

---

## 60. Redemption through wrapper contracts

A wrapper may call Optara redemption if it actually owns/controls the long.

It may then distribute proceeds according to its own rules.

Optara has no responsibility for wrapper-share accounting.

---

## 61. `redeemToMargin`

If implemented, this provides useful composability:

```text
settled long
-> burn
-> credit same stablecoin inside Optara
```

This can help an active writer reuse settlement proceeds without external ERC-20 transfer.

---

## 62. Settled claim transferability

After settlement and before redemption, long tokens may remain transferable.

They represent a fixed stablecoin claim.

External protocols may choose to value them accordingly.

---

# Part XVII — Series metadata composability

## 63. Immutable metadata

Integrators must be able to resolve:

```text
seriesId
underlying
settlementAsset
optionType
strike
cap
contractSize
expiry
oracleConfigId
optionToken
```

---

## 64. Do not parse symbol for economics

Token symbol such as:

```text
oMON-USDT-10C-C5-...
```

is presentation metadata.

Integrations must use canonical on-chain series data.

---

## 65. Deterministic series identity

A deterministic series ID helps:

```text
SDK
indexer
Kuru registry
bots
vaults
auditors
```

agree on the same economic contract.

Duplicate economic series should be prevented/canonicalized.

---

# Part XVIII — Cross-chain composability

## 66. Cross-chain is not core V2

Core V2 should not officially bridge canonical option claims without a separate cross-chain specification.

---

## 67. Why naive bridging is dangerous

If an option is locked on Monad and a wrapped claim is minted elsewhere:

```text
canonical ownership
redemption authority
bridge failure
double-mint
settlement timing
```

become new security assumptions.

---

## 68. Wrapped option is not canonical by default

A third-party bridge may create:

```text
wrapped Optara option
```

but Optara itself recognizes only the canonical long token on its home deployment unless an official adapter is explicitly designed.

---

## 69. No double redemption through bridge

Any future official bridge must guarantee:

```text
canonical long cannot redeem
while wrapped representation also claims settlement
```

This requires its own design and invariants.

---

# Part XIX — Composable strategy examples

## 70. Strategy A — buy and hold

```text
buy long on Kuru
-> wallet
-> expiry
-> redeem
```

Simple external composability.

---

## 71. Strategy B — buy then resell

```text
buy on Kuru
-> hold
-> sell on Kuru
```

No Optara state change other than token ownership.

---

## 72. Strategy C — writer buy-to-close

```text
writer short on Optara
-> buy same long on Kuru
-> obtain custody
-> closeShort
```

Uses both systems without merging accounting.

---

## 73. Strategy D — external long becomes hedge

```text
buy long externally
-> transfer to Optara
-> lockLong
-> margin recalculated
```

Margin credit begins only after Optara custody.

---

## 74. Strategy E — settled long into margin

If `redeemToMargin` exists:

```text
settled long
-> redeemToMargin
-> cashBalance[series settlementAsset] increases
-> cash can support other groups using same settlement asset
```

No cross-stablecoin credit occurs.

---

## 75. Strategy F — market maker

```text
obtain long inventory
obtain pair stablecoin
-> Kuru market making
```

If the market maker also wrote the long:

```text
Optara short remains independently margined
```

---

# Part XX — Unsafe composition patterns

## 76. Unsafe: external receipt counted as hedge

Bad:

```text
Kuru says Alice owns long
-> Optara lowers margin
```

Correct:

```text
actual long transferred into Optara custody
-> then margin may fall
```

---

## 77. Unsafe: SDK-computed health proof

Bad:

```text
SDK signs "account safe"
contract releases collateral
```

Core V2 must recompute on-chain.

---

## 78. Unsafe: wrapper share closes short

Bad:

```text
vault share representing option exposure
-> closeShort
```

Correct:

```text
exact canonical same-series long
-> burn
-> closeShort
```

---

## 79. Unsafe: venue fill closes short automatically

A fill only proves an external trade.

Optara short changes only after canonical close state transition.

---

## 80. Unsafe: symbol-based settlement asset

Do not infer:

```text
token symbol contains "USDT"
```

therefore collateral is a particular USDT address.

Use canonical configured addresses.

---

## 81. Unsafe: cross-stablecoin aggregator credit

A router cannot promise:

```text
"I will swap USDC to USDT later"
```

and receive immediate USDT margin credit.

Optara credits only received USDT.

---

## 82. Unsafe: external oracle preview used as settlement

Off-chain price previews are not finalization.

OracleAdapter must validate the actual settlement input on-chain.

---

# Part XXI — Reentrancy and callback safety

## 83. External integration is a hostile boundary

Any external call may be malicious or reentrant.

Examples:

```text
ERC-20 transfer
router
oracle provider
future adapter
```

---

## 84. State ordering

Safety-critical flows should use:

```text
checks
-> internal effects
-> controlled interactions
```

or an equivalent audited pattern.

---

## 85. No unsafe intermediate state

No callback may observe:

```text
collateral released while margin still assumes it exists

locked hedge transferred while RiskEngine still counts it

long paid but not burned

short reduced without long consumption
```

---

# Part XXII — Approval and authorization model

## 86. ERC-20 allowance

Standard flows may use:

```text
approve
transferFrom
```

for:

```text
settlement stablecoins
option long tokens
```

---

## 87. Permit support

Permit-style approvals MAY be added where supported and audited.

Permit is UX infrastructure, not economic logic.

---

## 88. Operator risk

SDKs should avoid asking users for broader approvals than necessary.

Integration contracts should have:

```text
minimal authorization scope
```

---

# Part XXIII — Versioning and upgrade compatibility

## 89. SDK versioning

SDK version must not redefine protocol economics.

A new SDK may change:

```text
API
types
caching
routing
UX
```

but not what the contracts mean.

---

## 90. Contract version awareness

SDK should detect:

```text
deployment/version
chainId
contract addresses
ABI compatibility
```

rather than silently assuming one deployment.

---

## 91. Integration feature detection

If optional functions exist:

```text
redeemToMargin
multicall
future router
```

SDK should feature-detect/configure them.

---

# Part XXIV — Composability invariants

## 92. COMP-INV-01 — Canonical claim

Only actual canonical Optara long-token units represent direct Optara long claims.

---

## 93. COMP-INV-02 — External custody gets no margin credit

A long outside Optara custody contributes:

```text
0
```

to locked-long margin credit.

---

## 94. COMP-INV-03 — Short liability cannot move through ERC-20 transfer

Transferring long tokens never transfers writer short liability.

---

## 95. COMP-INV-04 — External market price does not change payoff

Option payoff is independent of:

```text
Kuru price
other DEX price
vault share price
lending oracle price
```

---

## 96. COMP-INV-05 — External integrations cannot bypass margin

Every risk-increasing/collateral-decreasing Optara transition runs canonical on-chain validation.

---

## 97. COMP-INV-06 — Exact settlement asset

All generic integrations must use:

```text
series.settlementAsset
```

rather than a global stablecoin constant.

---

## 98. COMP-INV-07 — Same-series close

Only actual same-series long quantity can close a short.

---

## 99. COMP-INV-08 — Burn on claim consumption

Any long quantity consumed by:

```text
close
internal matured hedge settlement
redemption
```

must cease to exist as an external claim.

---

## 100. COMP-INV-09 — Kuru independence

Optara settlement remains functional without Kuru.

---

## 101. COMP-INV-10 — SDK non-authority

SDK output cannot create or destroy protocol rights without a corresponding valid contract transition.

---

## 102. COMP-INV-11 — Wrapper isolation

Failure of an external vault/wrapper must not mutate Optara's canonical series or accounting.

---

## 103. COMP-INV-12 — Indexer non-authority

Stale/missing indexer data cannot change protocol state.

---

# Part XXV — Integration test matrix

## 104. ERC-20 transfer tests

Test:

```text
wallet -> wallet
wallet -> Kuru-compatible address
wallet -> generic vault
vault -> wallet
```

Supply unchanged.

---

## 105. Locking tests

Test:

```text
external long -> Optara lock
margin recalculation
no simultaneous external transfer
safe unlock
unsafe unlock revert
```

---

## 106. Kuru tests

Test:

```text
writer mint -> Kuru
buyer purchase
buyer withdraw
writer buyback
closeShort
Kuru outage
```

---

## 107. Smart-account tests

Test:

```text
multisig owns long
contract account redeems
contract account writes
recipient is contract
```

where supported.

---

## 108. External vault tests

Test:

```text
vault receives long
vault transfers long
vault redeems long
share holder cannot bypass vault ownership
```

---

## 109. Settlement composability tests

Test:

```text
long changes owner before finalization
long changes owner after finalization
current holder redeems
previous holder cannot redeem
```

---

## 110. SDK differential tests

Compare:

```text
@optara/math preview
against
Solidity PayoffMath/RiskEngine
```

for fuzzed valid states.

---

## 111. Router tests

If a router exists:

```text
partial failure reverts safely
no retained user funds
no bypassed margin
correct approvals
same-series token checks
```

---

# Part XXVI — Developer integration guidelines

## 112. To read a series

Use canonical series metadata.

Do not parse token name/symbol.

---

## 113. To display margin

Use SDK/on-chain reads, but label previews clearly.

Transaction success depends on execution-time state.

---

## 114. To trade

Resolve:

```text
optionToken
settlementAsset
verified market metadata
```

Then use the venue-specific package.

---

## 115. To close a short

Obtain:

```text
exact same-series canonical long
```

then call Optara.

---

## 116. To use a long as hedge

Transfer actual long to Optara custody and lock it.

---

## 117. To redeem

Ensure:

```text
series settled
actual long custody/approval
```

then call Optara directly or via SDK.

---

# Part XXVII — Canonical composability diagrams

## 118. Long-token composability

```text
                   +--> Wallet
                   |
OptionToken -------+--> Kuru
                   |
                   +--> External Vault
                   |
                   +--> Lending Protocol
                   |
                   +--> Router
                   |
                   +--> Optara Hedge Custody
                           |
                           v
                     Margin credit
```

Only the final branch receives Optara margin credit.

---

## 119. Short isolation

```text
              OPTARA CLEARINGHOUSE
                     |
                     v
             shortQty[account]
                     |
        +------------+-------------+
        |                          |
 transferable?                  margin?
        |                          |
       NO                         YES
```

---

## 120. SDK trust boundary

```text
Frontend / Bot
      |
      v
@optara/sdk
      |
      +--> @optara/math preview
      |
      +--> @optara/kuru workflow
      |
      v
Optara Contracts
      |
      v
authoritative validation
```

---

# 121. Final principle

> **Optara maximizes composability of the asset that is safe to move—the long claim—while keeping the liability that requires solvency controls—the short—inside the clearing system.**

Everything external may help users:

```text
trade
route
hold
lend
vault
automate
analyze
```

but no external system may bypass:

```text
margin
custody
settlement
burn
stablecoin isolation
```

That boundary is the foundation of safe Optara composability.
