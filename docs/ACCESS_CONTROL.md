# Access Control

## 1. Roles

| Role | Held by | Can | Cannot |
|---|---|---|---|
| `GOVERNANCE` | Timelock controlled by a multisig (≥ 4/7) | Upgrades, approve products, raise risk limits, fees, publishers, treasury, unpause, clear close-only | Change series terms, finalized prices, ratios; move user cash |
| `GUARDIAN` | Fast multisig (e.g. 2/4) | Pause, product close-only, emergency surface mode, remove a publisher, disable adapters/markets | Unpause, upgrade, move funds, raise limits |
| `RISK_ADMIN` | Risk team multisig | Make parameters **more** conservative instantly; propose less conservative changes (timelocked) | Fees, upgrades, funds |
| `SERIES_CREATOR` | Ops multisig or bot | Create series within product bounds | Edit series, create outside bounds |
| `ORACLE_ADMIN` | Ops multisig | Register settlement oracle configs, set spot sources (timelocked) | Change existing configs |
| `VENUE_ADMIN` | Ops multisig | Register verified markets and adapters (adapters timelocked) | Touch clearing |
| Account owner | User | Everything on its subaccount; manage operators | Act on other accounts |
| Operator | Approved by the owner | Act on the subaccount, except managing operators | — |
| Anyone | — | Deposit, unwrap into own account, update oracles, finalize, settle, ratio, redeem, liquidate | — |

Roles live in `ProtocolControl` ([PROTOCOL_SPEC.md](PROTOCOL_SPEC.md) §11.1). `GOVERNANCE` is the AccessControl
default admin role, held by the governance timelock, so only governance grants or revokes roles and every
governance action is delayed by `parameterTimelock`. `UpgradeAdmin` keeps its own governance seat and emergency
council (not roles in `ProtocolControl`), so a broken `ProtocolControl` can still be upgraded.

Internal module permissions (`OptionClearing`, `LiquidationModule`, `SettlementWindow` writing the ledger; wrapper
mint/burn) are fixed addresses set at deployment. Changing them requires a governance upgrade.

## 2. Timelocks

| Action | Delay |
|---|---|
| Upgrade an implementation | `upgradeTimelock` (7 days) |
| Emergency upgrade | `emergencyUpgradeTimelock` (24 h), higher multisig threshold; affected products auto close-only |
| Risk-increasing parameter change | `parameterTimelock` (48 h) |
| Publisher set or quorum change | `publisherSetTimelock` (48 h) |
| Fee change, treasury withdrawal | `parameterTimelock` |
| Pause, close-only, emergency mode, risk-reducing parameter change | Instant |

Users with open shorts may not be able to exit within a timelock window. The UI must say so.

## 3. Upgrade process

1. Publish the new implementation, its source and its code hash.
2. Add the code hash to the `UpgradeAdmin` allowlist (governance, so already announced `parameterTimelock` ahead).
3. Schedule the upgrade (event `UpgradeScheduled(id, proxy, impl, codeHash, eta, emergency)`); `eta = now +
   upgradeDelay`.
4. Required before execution: storage-layout diff check, full test suite, fork test on current state, and
   "protected storage unchanged" test (§5).
5. Anyone executes after `eta` (event `UpgradeExecuted`). Execution re-checks that the implementation's code hash
   is unchanged and still allowlisted.
6. Governance may cancel at any time before execution (or block it by removing the hash from the allowlist).

## 4. Emergency upgrade

- For live exploits only.
- Scheduled by the emergency council (higher multisig threshold), `eta = now + emergencyDelay`; no allowlist entry
  is needed, and the code hash is published in the event.
- Sets the listed products close-only in `ProtocolControl` at scheduling time, so new risk stops immediately.
- Governance or the council may cancel it.
- A post-mortem must be published before close-only is cleared.

## 5. Protected storage

These values must never be writable by any function or upgrade. Each has a dedicated upgrade test.

| Data | Location |
|---|---|
| Series terms and wrapper address | `OptionSeriesRegistry` |
| Wrapper bytecode | Immutable clones |
| Settlement price, finalization timestamp | `SettlementWindow` |
| Wrapper supply snapshots, recovery ratio, credits, redeemed amounts | `SettlementWindow` |

Implementation rule: protected data lives in dedicated storage structs at fixed slots (ERC-7201 namespaces). They are
written only in their write-once functions, and new implementations must not declare setters for them.

## 6. Key management

- Governance and guardian keys are hardware-backed multisigs with distinct signers.
- Publisher keys are held by independent operators (or an approved provider) in HSMs or remote signers.
- Keeper keys hold only gas money and the keeper's own rewards. They need no role.
- No private key may appear in repositories, frontends or SDKs.
