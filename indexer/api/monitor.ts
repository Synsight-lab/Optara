/**
 * The health worker and monitor (INDEXER_AND_KEEPERS.md §1.1 "Health ... is not derivable from events", §1.3
 * reconciliation; SECURITY.md §5 alerts). Health is read from `PortfolioRiskManager.riskOf` (VIEW mode, never
 * reverts) for every account with open positions and cached with its time.
 */
import { erc20Abi, type Address, type PublicClient } from "viem";
import {
  feeControllerAbi,
  insuranceFundAbi,
  liquidationModuleAbi,
  portfolioRiskManagerAbi,
  settlementWindowAbi,
  subAccountsAbi,
  volSurfaceOracleAbi,
  type Manifest,
} from "@optara/sdk";
import type { AccountRow, AuctionRow, Db, GroupRow, PositionRow, SeriesRow } from "./db.ts";

export interface Health {
  accountId: bigint;
  equity: bigint;
  initialMargin: bigint;
  maintenanceMargin: bigint;
  fresh: boolean;
  at: number; // ms
}

export interface Alert {
  kind:
    | "BELOW_MM_NO_AUCTION"
    | "AUCTION_AT_MAX_BONUS"
    | "SURFACE_STALE"
    | "INSURANCE_LOW"
    | "SETTLEMENT_PROGRESS"
    | "CUSTODY"
    | "INDEX_MISMATCH"
    | "INDEX_LAG"
    | "GOVERNANCE";
  severity: "info" | "warning" | "critical";
  subject: string;
  detail: string;
}

const SurfaceStatus = ["NONE", "FRESH", "STALE", "EXPIRED_DATA"] as const;
const GOVERNANCE_KINDS = ["UPGRADE_SCHEDULED", "PUBLISHER_ADDED", "PUBLISHER_REMOVED", "QUORUM_SET", "SHORT_CAP_SET", "PAUSED", "CLOSE_ONLY", "EMERGENCY_ON", "ROLE_GRANTED", "ROLE_REVOKED", "IMPLEMENTATION_ALLOWED", "GOVERNANCE_TRANSFERRED"];

async function pool<T, R>(items: readonly T[], n: number, fn: (x: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let i = 0;
  await Promise.all(
    Array.from({ length: Math.min(n, items.length) }, async () => {
      while (i < items.length) {
        const k = i++;
        out[k] = await fn(items[k]!);
      }
    }),
  );
  return out;
}

export class Monitor {
  readonly health = new Map<bigint, Health>();
  private readonly belowSince = new Map<bigint, number>();
  lastMismatches: Alert[] = [];

  constructor(
    private readonly db: Db,
    private readonly client: PublicClient,
    private readonly manifest: Manifest,
    private readonly concurrency = 16,
  ) {}

  private get p() {
    return this.manifest.proxies;
  }

  /** Accounts with at least one non-zero position. */
  async accountsWithPositions(): Promise<bigint[]> {
    const rows = await this.db.rows<PositionRow>("Position", `balance <> 0`);
    return [...new Set(rows.map((r) => r.accountId))].sort((a, b) => (a < b ? -1 : 1));
  }

  /** Refreshes the health cache; accounts that no longer hold positions are dropped. */
  async refreshHealth(): Promise<void> {
    const ids = await this.accountsWithPositions();
    const keep = new Set(ids);
    for (const k of [...this.health.keys()]) if (!keep.has(k)) (this.health.delete(k), this.belowSince.delete(k));
    await pool(ids, this.concurrency, async (accountId) => {
      const r = await this.client.readContract({ address: this.p.PortfolioRiskManager.proxy, abi: portfolioRiskManagerAbi, functionName: "riskOf", args: [accountId] });
      const h: Health = { accountId, equity: r.equity, initialMargin: BigInt(r.initialMargin), maintenanceMargin: BigInt(r.maintenanceMargin), fresh: r.fresh, at: Date.now() };
      this.health.set(accountId, h);
      if (h.equity < h.maintenanceMargin) {
        if (!this.belowSince.has(accountId)) this.belowSince.set(accountId, Date.now());
      } else this.belowSince.delete(accountId);
    });
  }

  /** INDEXER_AND_KEEPERS.md §1.2 `/liquidatable`: below MM, largest shortfall first. */
  liquidatable(): Health[] {
    return [...this.health.values()].filter((h) => h.equity < h.maintenanceMargin).sort((a, b) => (b.maintenanceMargin - b.equity > a.maintenanceMargin - a.equity ? 1 : -1));
  }

  /**
   * §1.3: the index against on-chain views: every account's cash, every series' long/short totals (catches a
   * missing or wrong position anywhere), wrapper supplies, participant counts and the account count; plus INV-7
   * custody per asset (clearing balance = Σ cash + Σ group pools). Returns the mismatches.
   */
  async reconcile(): Promise<Alert[]> {
    const c = this.client;
    const out: Alert[] = [];
    const mismatch = (subject: string, detail: string) => out.push({ kind: "INDEX_MISMATCH", severity: "critical", subject, detail });
    const [accounts, series, groups] = await Promise.all([
      this.db.rows<AccountRow>("Account"),
      this.db.rows<SeriesRow>("Series"),
      this.db.rows<GroupRow>("SettlementGroup"),
    ]);
    const onChainCount = await c.readContract({ address: this.p.SubAccounts.proxy, abi: subAccountsAbi, functionName: "accountCount" });
    if (onChainCount !== BigInt(accounts.length)) mismatch("accounts", `${accounts.length} indexed, ${onChainCount} on chain`);
    await pool(accounts, this.concurrency, async (a) => {
      const cash = await c.readContract({ address: this.p.SubAccounts.proxy, abi: subAccountsAbi, functionName: "cashOf", args: [a.accountId] });
      if (cash !== a.cash) mismatch(`account ${a.accountId}`, `cash ${a.cash} indexed, ${cash} on chain`);
    });
    await pool(series, this.concurrency, async (s) => {
      const [long, short] = await c.readContract({ address: this.p.SubAccounts.proxy, abi: subAccountsAbi, functionName: "totals", args: [s.id as `0x${string}`] });
      if (long !== s.internalLong || short !== s.internalShort) mismatch(`series ${s.id}`, `totals ${s.internalLong}/${s.internalShort} indexed, ${long}/${short} on chain`);
      const supply = await c.readContract({ address: s.wrapper as Address, abi: erc20Abi, functionName: "totalSupply" });
      if (supply !== s.wrapperSupply) mismatch(`series ${s.id}`, `wrapper supply ${s.wrapperSupply} indexed, ${supply} on chain`);
    });
    const pools = new Map<string, bigint>();
    await pool(groups, this.concurrency, async (g) => {
      const n = await c.readContract({ address: this.p.SubAccounts.proxy, abi: subAccountsAbi, functionName: "participants", args: [g.id as `0x${string}`] });
      if (n !== g.participants) mismatch(`group ${g.id}`, `participants ${g.participants} indexed, ${n} on chain`);
      const acct = await c.readContract({ address: this.p.SettlementWindow.proxy, abi: settlementWindowAbi, functionName: "groupAccounting", args: [g.id as `0x${string}`] });
      pools.set(g.settlementAsset.toLowerCase(), (pools.get(g.settlementAsset.toLowerCase()) ?? 0n) + acct.pool);
    });
    // INV-7 custody, per settlement asset.
    const cashByAsset = new Map<string, bigint>();
    for (const a of accounts) cashByAsset.set(a.settlementAsset.toLowerCase(), (cashByAsset.get(a.settlementAsset.toLowerCase()) ?? 0n) + a.cash);
    for (const asset of new Set([...cashByAsset.keys(), ...pools.keys()])) {
      const held = await c.readContract({ address: asset as Address, abi: erc20Abi, functionName: "balanceOf", args: [this.p.OptionClearing.proxy] });
      const owed = (cashByAsset.get(asset) ?? 0n) + (pools.get(asset) ?? 0n);
      if (held !== owed) out.push({ kind: "CUSTODY", severity: "critical", subject: asset, detail: `clearing holds ${held}, cash + pools ${owed} (INV-7)` });
    }
    this.lastMismatches = out;
    return out;
  }

  /** SECURITY.md §5. `now` in seconds (chain time). */
  async alerts(now: bigint): Promise<Alert[]> {
    const c = this.client;
    const out: Alert[] = [...this.lastMismatches];
    const auctions = await this.db.rows<AuctionRow>("Auction", `active = true`);
    const activeAccounts = new Set(auctions.map((a) => a.accountId));
    for (const [accountId, since] of this.belowSince) {
      if (!activeAccounts.has(accountId) && Date.now() - since > 60_000) {
        out.push({ kind: "BELOW_MM_NO_AUCTION", severity: "critical", subject: `account ${accountId}`, detail: `below MM for ${Math.round((Date.now() - since) / 1000)} s with no auction` });
      }
    }
    const params = await c.readContract({ address: this.p.LiquidationModule.proxy, abi: liquidationModuleAbi, functionName: "liquidationParams" });
    for (const a of auctions) {
      if (now - a.startTime > BigInt(params.auctionDuration)) out.push({ kind: "AUCTION_AT_MAX_BONUS", severity: "warning", subject: `account ${a.accountId} ${a.underlying}`, detail: `auction running ${now - a.startTime} s` });
    }
    for (const p of await this.db.rows<{ id: string }>("Product")) {
      const [status, stale] = await c.readContract({ address: this.p.VolSurfaceOracle.proxy, abi: volSurfaceOracleAbi, functionName: "surfaceStatus", args: [p.id as `0x${string}`] });
      if (SurfaceStatus[status] !== "FRESH") out.push({ kind: "SURFACE_STALE", severity: SurfaceStatus[status] === "EXPIRED_DATA" ? "critical" : "warning", subject: p.id, detail: `${SurfaceStatus[status]} (${stale} s past surfaceStaleAfter)` });
    }
    const assets = new Set((await this.db.rows<{ id: string }>("Insurance")).map((r) => r.id));
    for (const asset of assets) {
      const [balance, cfg] = await Promise.all([
        c.readContract({ address: this.p.InsuranceFund.proxy, abi: insuranceFundAbi, functionName: "balanceOf", args: [asset as Address] }),
        c.readContract({ address: this.p.FeeController.proxy, abi: feeControllerAbi, functionName: "assetConfig", args: [asset as Address] }),
      ]);
      if (balance < 2n * cfg.minimumInsuranceSeed) out.push({ kind: "INSURANCE_LOW", severity: balance < cfg.minimumInsuranceSeed ? "critical" : "warning", subject: asset, detail: `insurance ${balance} < 2 × minimum seed ${cfg.minimumInsuranceSeed}` });
    }
    for (const g of await this.db.rows<GroupRow>("SettlementGroup", `finalized = true AND participants > 0`)) {
      if (now - g.finalizedAt > 3600n) out.push({ kind: "SETTLEMENT_PROGRESS", severity: "warning", subject: g.id, detail: `${g.participants} participant(s) unsettled ${now - g.finalizedAt} s after finalization` });
    }
    const week = now - 7n * 86_400n;
    for (const e of await this.db.rows<{ kind: string; contract: string; detail: string; timestamp: bigint }>("GovernanceEvent", `timestamp >= $1 AND kind = ANY($2)`, [week.toString(), GOVERNANCE_KINDS])) {
      out.push({ kind: "GOVERNANCE", severity: e.kind === "UPGRADE_SCHEDULED" ? "warning" : "info", subject: `${e.contract} ${e.kind}`, detail: e.detail });
    }
    const head = await c.getBlockNumber();
    const progress = BigInt(await this.db.progressBlock());
    if (head - progress > 50n) out.push({ kind: "INDEX_LAG", severity: "warning", subject: "indexer", detail: `${head - progress} blocks behind` });
    return out;
  }
}
