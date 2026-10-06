# State Machines

## 1. Series and settlement group

A series' state is its group's state. Everything below is per group.

```text
                 now ≥ expiry                finalizeGroup
   ACTIVE ───────────────────> EXPIRED ─────────────────────> FINALIZED
                                  │                              │ participants == 0
                                  │ now ≥ expiry +               v
                                  │ maxFinalizationDelay     ALL_SETTLED
                                  v                              │ computeRecoveryRatio
                           (flag) ORACLE_STALLED                 v
                           still EXPIRED; can still          REDEEMABLE
                           be finalized later
```

| State | Price | New risk | Unwrap / wrap | Close with wrapper | Liquidation | Settle accounts | Redeem / claim |
|---|---|---|---|---|---|---|---|
| ACTIVE | — | Yes (if healthy, fresh) | Yes | Yes | Yes | No | No |
| EXPIRED | — | No | No | Yes | Unexpired legs only | No | No |
| ORACLE_STALLED | — | No | No | Yes | Unexpired legs only | No | No |
| FINALIZED | Fixed | No | No | No | No (finalized legs) | **Yes** | No |
| ALL_SETTLED | Fixed | No | No | No | No | Done | No |
| REDEEMABLE | Fixed | No | No | No | No | Done | **Yes** |

No backward transitions. The price and the ratio are written once.

## 2. Account health

Computed on demand, not stored ([MATH.md](MATH.md) §9.1).

```text
            equity ≥ IM
   HEALTHY ◄──────────────► CLOSE_ONLY        (MM ≤ equity < IM)
      ▲                         │ ▲
      │                         v │
      └──── recovers ──── LIQUIDATABLE        (equity < MM)
                                │
                                v  nothing left to liquidate, equity < 0
                            INSOLVENT ──> settles at expiry; shortfall → insurance → ratio
```

| Action | HEALTHY | CLOSE_ONLY | LIQUIDATABLE |
|---|---|---|---|
| deposit, unwrap, close short | ✔ | ✔ | ✔ |
| mint, wrap, withdraw, move a long out | ✔ (if still healthy after) | ✖ | ✖ |
| be liquidated | ✖ | ✖ | ✔ |

## 3. Liquidation auction (per account × underlying)

```text
   NONE ──startAuction (equity < MM)──> ACTIVE ──slices──> ACTIVE
                                           │  bonus rises to maxBonusBps over auctionDuration
                                           │  after auctionDuration: whole-bucket mode
                                           v
                       equity ≥ IM × (1 + targetHealthBuffer)  or bucket empty
                                           v
                                         ENDED ──(falls below MM again)──> new auction
```

## 4. Product (underlying × settlement asset)

```text
   NOT_APPROVED ──approveProduct (timelock)──> ENABLED
   ENABLED ◄──────────────► CLOSE_ONLY        set by guardian, stale surface (> maxSurfaceStale),
                                              low confidence, emergency mode, or insurance below minimum
   ENABLED / CLOSE_ONLY ──disable──> DISABLED (no new series; existing series run to settlement)
```

CLOSE_ONLY clears automatically for automatic causes (a fresh, confident surface arrives; insurance is topped up).
It needs governance for guardian-set causes and emergency mode.

## 5. Surface data per product

| State | Condition | Effect |
|---|---|---|
| FRESH | age ≤ `surfaceStaleAfter`, before `expiresAt` | Everything allowed |
| STALE | `surfaceStaleAfter` < age ≤ `maxSurfaceStale` | No new risk; liquidation with direction-aware penalties; longs at intrinsic after `maxLongTimeValueStale` |
| EXPIRED_DATA | age > `maxSurfaceStale` | Product CLOSE_ONLY |
| EMERGENCY | guardian flag in `VolSurfaceOracle` (governance clears) | Large IV moves accepted; product CLOSE_ONLY while on |
| LOW_CONFIDENCE | current report's `confidenceBps > maxConfidenceBps` | Report stored; product CLOSE_ONLY until a confident report arrives |

## 6. Subaccount position in a group (for the participant counter)

```text
   NONE ──first non-zero balance in the group──> PARTICIPANT (participants += 1)
   PARTICIPANT ──all balances in the group back to 0──> NONE (participants −= 1)
   PARTICIPANT ──settleAccountGroup──> SETTLED (participants −= 1; credit or debt recorded)
   SETTLED ──claimSettlement (if credit)──> CLAIMED
```

## 7. Wrapper token units

```text
   minted (mintExternalLong / wrapLong)
      ├─> transferred freely (wallet, Kuru, anywhere)
      ├─> burned by unwrapLong            -> becomes an internal long
      ├─> burned by closeShortWithWrapper -> cancels an internal short
      ├─> burned by liquidateWithWrapper  -> cancels an account's short
      └─> burned by redeemWrapper         -> paid payoff × ratio
```

A wrapper unit can be burned only once and only by its holder's own call.
