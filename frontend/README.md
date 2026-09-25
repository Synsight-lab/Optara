# Optara web app

Vite + React + wagmi. All margin, payoff and settlement numbers are read from the core's views; the app never
computes an authoritative value (PROTOCOL_SPEC.md section 2.1). `src/lib/optara/` is a thin client layer whose
function names follow the planned `@optara/sdk`, so the SDK can replace it by changing imports.

- Markets: series catalog from chain (no indexer needed), max payout per option, lifecycle state.
- Series: terms, write with exact margin preview, lock/unlock, close/cancel/redeem chosen from the execution-time
  lifecycle (KUR-015), sync, and a buy/sell section gated by the settlement-liveness disclosure (KUR-013).
- Portfolio: per-asset cash, effective cash, required margin, free collateral, deficit and incident status;
  exact-amount approvals; cure-deposit rules while restricted.
- Settlement: expired groups, the unique Chainlink finalization proof from the indexer, permissionless finalize.

```bash
npm install
VITE_NETWORK=local VITE_INDEXER_URL=http://localhost:8787 npm run dev
# public networks also need VITE_RPC_URL; the manifest deployments/<VITE_NETWORK>.json must exist
npm test   # unit + component + anvil integration (spawns its own anvil and deployment)
```
