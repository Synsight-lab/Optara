import type { Address, Hex, PublicClient } from "viem";
import { optaraCoreAbi, optaraConfigAbi, erc20Abi } from "./abi.ts";
import type { Store } from "./db.ts";
import type { IndexerConfig } from "./config.ts";

const denominator = (decimals: number): bigint => 10n ** BigInt(54 - decimals);

function phi(optionType: number, strike: bigint, cap: bigint, price: bigint): bigint {
  const intrinsic = optionType === 0 ? price - strike : strike - price;
  if (intrinsic <= 0n) return 0n;
  return intrinsic < cap ? intrinsic : cap;
}

export interface ReconcileReport {
  checkedAccounts: number;
  alerts: { kind: string; subject: string; detail: string }[];
}

/**
 * Monitoring (LIQUIDATION.md section 91, DEPLOYMENT.md section 68, SECURITY.md section 103). Every check reads
 * authoritative on-chain views; the index only tells us which accounts and groups exist. Alerts are advisory.
 */
export async function reconcile(client: PublicClient, store: Store, cfg: IndexerConfig, now: number): Promise<ReconcileReport> {
  const core = cfg.manifest.contracts.OptaraCore;
  const configAddr = cfg.manifest.contracts.OptaraConfig;
  const alerts: ReconcileReport["alerts"] = [];
  const active = new Map<string, Set<string>>();
  const raise = (kind: string, subject: string, detail: string) => {
    alerts.push({ kind, subject, detail });
    store.raiseAlert(kind, subject, detail, now);
    if (!active.has(kind)) active.set(kind, new Set());
    active.get(kind)!.add(subject);
  };

  const accounts = store.all<{ account: string }>(
    "SELECT account FROM positions UNION SELECT account FROM cash ORDER BY account",
  ).map((r) => r.account as Address);
  const assets = cfg.manifest.assets;

  // 1. Account solvency and index/chain consistency.
  for (const account of accounts) {
    for (const asset of assets) {
      const deficit = await client.readContract({ address: core, abi: optaraCoreAbi, functionName: "deficit", args: [account, asset] });
      if (deficit > 0n) raise("DEFICIT", `${account}:${asset}`, `deficit ${deficit} native units`);
      const onChainCash = await client.readContract({ address: core, abi: optaraCoreAbi, functionName: "cashBalance", args: [account, asset] });
      const indexed = BigInt(store.get<{ amount: string }>("SELECT amount FROM cash WHERE account = ? AND asset = ?", account, asset.toLowerCase())?.amount ?? "0");
      if (onChainCash !== indexed) raise("INDEX_MISMATCH", `cash:${account}:${asset}`, `chain ${onChainCash} index ${indexed}`);
    }
    for (const p of store.all<{ series_id: string; short_qty: string; locked_qty: string }>("SELECT * FROM positions WHERE account = ?", account)) {
      const pos = await client.readContract({ address: core, abi: optaraCoreAbi, functionName: "positionOf", args: [account, p.series_id as Hex] });
      if (pos.shortQty !== BigInt(p.short_qty) || pos.lockedQty !== BigInt(p.locked_qty)) {
        raise("INDEX_MISMATCH", `position:${account}:${p.series_id}`, `chain ${pos.shortQty}/${pos.lockedQty} index ${p.short_qty}/${p.locked_qty}`);
      }
    }
  }

  // 2. Expired groups: awaiting price vs ORACLE_STALLED (STATE_MACHINE.md section 101).
  for (const g of store.all<{ group_id: string; expiry: number; finalized: number }>("SELECT group_id, expiry, finalized FROM groups")) {
    if (g.finalized || g.expiry > now) continue;
    const stalled = await client.readContract({ address: core, abi: optaraCoreAbi, functionName: "isOracleStalled", args: [g.group_id as Hex] });
    raise(stalled ? "ORACLE_STALLED" : "AWAITING_FINALIZATION", g.group_id, `expired at ${g.expiry}`);
  }

  // 3. Exposure caps near their limits (PROTOCOL_SPEC.md section 42).
  const seen = new Set<string>();
  for (const s of store.all<{ settlement_asset: string; underlying: string; oracle_config_id: string }>("SELECT DISTINCT settlement_asset, underlying, oracle_config_id FROM series")) {
    const pairId = await client.readContract({ address: configAddr, abi: optaraConfigAbi, functionName: "pairIdOf", args: [s.underlying as Address, s.settlement_asset as Address] });
    const key = `${pairId}:${s.oracle_config_id}:${s.settlement_asset}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const [pairN, oracleN, assetN] = await client.readContract({ address: core, abi: optaraCoreAbi, functionName: "exposureOf", args: [pairId, s.oracle_config_id as Hex, s.settlement_asset as Address] });
    const [, pairL, oracleL, assetL] = await client.readContract({ address: configAddr, abi: optaraConfigAbi, functionName: "exposureLimits", args: [pairId, s.oracle_config_id as Hex, s.settlement_asset as Address] });
    const check = (scope: string, used: bigint, limit: bigint) => {
      if (limit === 0n || used * 10_000n >= limit * cfg.capAlertBps) raise("CAP_PRESSURE", `${scope}`, `used ${used} of ${limit}`);
    };
    check(`pair:${pairId}`, pairN, pairL);
    check(`oracle:${s.oracle_config_id}`, oracleN, oracleL);
    check(`asset:${s.settlement_asset}`, assetN, assetL);
  }

  // 4. Asset incidents.
  for (const asset of assets) {
    const [status, rho] = await client.readContract({ address: core, abi: optaraCoreAbi, functionName: "assetStatus", args: [asset] });
    if (status === 1) raise("ASSET_RESTRICTED", asset.toLowerCase(), "all outflows of this asset are blocked");
    if (status === 2) raise("ASSET_WIND_DOWN", asset.toLowerCase(), `outflows pay rho ${rho}`);
  }

  // 5. Pooled vault solvency per asset (MATH.md section 64): VB * D >= sum(effective cash) * D + external claims N.
  for (const asset of assets) {
    const decimals = await client.readContract({ address: asset, abi: erc20Abi, functionName: "decimals" });
    const d = denominator(decimals);
    let effective = 0n;
    for (const account of accounts) {
      effective += await client.readContract({ address: core, abi: optaraCoreAbi, functionName: "effectiveCash", args: [account, asset] });
    }
    let externalN = 0n;
    const settled = store.all<{ series_id: string; option_token: string; option_type: number; strike_wad: string; cap_wad: string; contract_size_wad: string; price: string }>(
      `SELECT s.series_id, s.option_token, s.option_type, s.strike_wad, s.cap_wad, s.contract_size_wad, g.settlement_price_wad AS price
       FROM series s JOIN groups g ON g.group_id = s.group_id WHERE g.finalized = 1 AND s.settlement_asset = ?`,
      asset.toLowerCase(),
    );
    for (const s of settled) {
      const supply = await client.readContract({ address: s.option_token as Address, abi: erc20Abi, functionName: "totalSupply" });
      const locked = store.all<{ locked_qty: string }>("SELECT locked_qty FROM positions WHERE series_id = ?", s.series_id)
        .reduce((acc, r) => acc + BigInt(r.locked_qty), 0n);
      const external = supply - locked;
      externalN += phi(s.option_type, BigInt(s.strike_wad), BigInt(s.cap_wad), BigInt(s.price)) * BigInt(s.contract_size_wad) * external;
    }
    const vault = await client.readContract({ address: asset, abi: erc20Abi, functionName: "balanceOf", args: [core] });
    if (vault * d < effective * d + externalN) {
      raise("VAULT_SHORTFALL", asset.toLowerCase(), `vault ${vault} < claims ${(effective * d + externalN) / d}`);
    }
  }

  for (const kind of ["DEFICIT", "INDEX_MISMATCH", "ORACLE_STALLED", "AWAITING_FINALIZATION", "CAP_PRESSURE", "ASSET_RESTRICTED", "ASSET_WIND_DOWN", "VAULT_SHORTFALL"]) {
    store.clearAlertsExcept(kind, active.get(kind) ?? new Set());
  }
  return { checkedAccounts: accounts.length, alerts };
}
