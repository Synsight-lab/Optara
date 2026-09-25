# Kuru secondary-market fork tests

These tests run Optara long tokens through the **real Kuru Spot V2 contracts** on a Monad testnet fork (chain 10143,
deployment of 2026-09-01: AccountCore `0x6384…eE22`, SpotRouter `0xba24…c697`, test USDC `0xEe07…f97E`).

```bash
cd contract
FOUNDRY_PROFILE=fork forge test -vv                          # public RPC https://testnet-rpc.monad.xyz
MONAD_TESTNET_RPC=<your rpc> KURU_FORK_BLOCK=<n> FOUNDRY_PROFILE=fork forge test   # own RPC / pinned block
```

The default `forge test` excludes this folder (it needs network access).

What the fixture does: it deploys a fresh Optara V2 stack on the fork, settled in Kuru's test USDC, and creates a
MON/USDC capped call. It then impersonates **Kuru governance** to whitelist the option token, enable it in
AccountCore and deploy an OPTION/USDC OrderBook. On the live testnet, listing is permissioned: only Kuru's
governance role can do this (`ProtocolAuthority.governance()`).

Kuru's contracts are never imported by Optara's source. Everything here is venue-side behaviour observed against
Optara's unchanged core.
