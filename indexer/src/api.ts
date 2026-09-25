import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { isAddress, type Address, type Hex, type PublicClient } from "viem";
import type { Store } from "./db.ts";
import type { IndexerConfig } from "./config.ts";
import { optaraCoreAbi } from "./abi.ts";
import { buildFinalizationProof } from "./proof.ts";

export interface KuruMarket {
  seriesId: Hex;
  market: Address;
  base: Address;
  quote: Address;
  chainId: number;
}

/**
 * Official market metadata is integration metadata, never series economics (KURU_INTEGRATION.md sections 11-12).
 * An entry is listed only if base == the series' option token, quote == its settlement asset and the chain matches
 * (KI-INV-08/09, DEPLOY-TEST-012). Invalid entries are rejected with a reason.
 */
export function validateKuruMarkets(store: Store, chainId: number, markets: KuruMarket[]): { valid: KuruMarket[]; rejected: { entry: KuruMarket; reason: string }[] } {
  const valid: KuruMarket[] = [];
  const rejected: { entry: KuruMarket; reason: string }[] = [];
  for (const m of markets) {
    const s = store.get<{ option_token: string; settlement_asset: string }>("SELECT option_token, settlement_asset FROM series WHERE series_id = ?", m.seriesId.toLowerCase());
    if (m.chainId !== chainId) rejected.push({ entry: m, reason: "wrong chain" });
    else if (!s) rejected.push({ entry: m, reason: "unknown series" });
    else if (m.base.toLowerCase() !== s.option_token) rejected.push({ entry: m, reason: "base is not the series option token" });
    else if (m.quote.toLowerCase() !== s.settlement_asset) rejected.push({ entry: m, reason: "quote is not the series settlement asset" });
    else valid.push(m);
  }
  return { valid, rejected };
}

const json = (res: ServerResponse, status: number, body: unknown) => {
  res.writeHead(status, { "content-type": "application/json", "access-control-allow-origin": "*" });
  res.end(JSON.stringify(body, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
};

export interface ApiDeps {
  store: Store;
  client: PublicClient;
  cfg: IndexerConfig;
  cursor: () => bigint;
}

/** Read-only HTTP API. Data is eventually consistent; safety-critical flows must read the chain (SECURITY.md 78). */
export function handle(deps: ApiDeps, req: IncomingMessage, res: ServerResponse): Promise<void> | void {
  const { store, cfg } = deps;
  const url = new URL(req.url ?? "/", "http://localhost");
  const parts = url.pathname.split("/").filter(Boolean);
  if (req.method !== "GET") return json(res, 405, { error: "method not allowed" });

  if (parts[0] === "health") {
    return json(res, 200, { ok: true, chainId: cfg.chainId, network: cfg.manifest.network, indexedTo: deps.cursor().toString() });
  }
  if (parts[0] === "manifest") return json(res, 200, cfg.manifest);
  if (parts[0] === "series" && parts.length === 1) {
    return json(res, 200, store.all(
      `SELECT s.*, g.finalized, g.settlement_price_wad FROM series s JOIN groups g ON g.group_id = s.group_id ORDER BY s.expiry, s.underlying, s.option_type, CAST(s.strike_wad AS REAL)`,
    ));
  }
  if (parts[0] === "series" && parts[1]) {
    const row = store.get("SELECT * FROM series WHERE series_id = ?", parts[1].toLowerCase());
    return row ? json(res, 200, row) : json(res, 404, { error: "unknown series" });
  }
  if (parts[0] === "groups" && parts.length === 1) return json(res, 200, store.all("SELECT * FROM groups ORDER BY expiry"));
  if (parts[0] === "groups" && parts[1] && parts[2] === "finalization-proof") {
    const g = store.get<{ group_id: string; oracle_config_id: string; expiry: number }>("SELECT * FROM groups WHERE group_id = ?", parts[1].toLowerCase());
    if (!g) return json(res, 404, { error: "unknown group" });
    return buildFinalizationProof(deps.client, cfg.manifest.contracts.OracleRegistry, cfg.manifest.contracts.ChainlinkSettlementAdapter, {
      groupId: g.group_id as Hex,
      oracleConfigId: g.oracle_config_id as Hex,
      expiry: BigInt(g.expiry),
    }).then((p) => json(res, 200, p)).catch((e: Error) => json(res, 500, { error: e.message }));
  }
  if (parts[0] === "groups" && parts[1]) {
    const row = store.get("SELECT * FROM groups WHERE group_id = ?", parts[1].toLowerCase());
    return row ? json(res, 200, row) : json(res, 404, { error: "unknown group" });
  }
  if (parts[0] === "accounts" && parts[1]) {
    if (!isAddress(parts[1], { strict: false })) return json(res, 400, { error: "invalid account address" });
    const account = parts[1].toLowerCase();
    if (parts[2] === "events") {
      const like = `%${account.slice(2)}%`;
      return json(res, 200, store.all("SELECT * FROM events WHERE args LIKE ? ORDER BY block_number DESC, log_index DESC LIMIT 500", like));
    }
    if (parts[2] === "risk") {
      // Authoritative numbers come straight from the core views.
      const reads = cfg.manifest.assets.map((asset) =>
        deps.client.readContract({ address: cfg.manifest.contracts.OptaraCore, abi: optaraCoreAbi, functionName: "accountRiskState", args: [account as Address, asset] })
          .then((r) => ({ asset, ...r })));
      return Promise.all(reads).then((r) => json(res, 200, r)).catch((e: Error) => json(res, 500, { error: e.message }));
    }
    return json(res, 200, {
      account,
      cash: store.all("SELECT asset, amount FROM cash WHERE account = ?", account),
      positions: store.all("SELECT p.*, s.group_id FROM positions p JOIN series s ON s.series_id = p.series_id WHERE p.account = ?", account),
      longs: store.all(
        "SELECT b.token, b.amount, s.series_id FROM balances b JOIN series s ON s.option_token = b.token WHERE b.holder = ? AND b.amount != '0'",
        account,
      ),
    });
  }
  if (parts[0] === "alerts") return json(res, 200, store.all("SELECT * FROM alerts WHERE active = 1 ORDER BY kind, subject"));
  if (parts[0] === "assets") return json(res, 200, store.all("SELECT * FROM asset_status"));
  if (parts[0] === "markets") {
    if (!cfg.kuruMarketsPath || !existsSync(cfg.kuruMarketsPath)) return json(res, 200, { valid: [], rejected: [] });
    const all = JSON.parse(readFileSync(cfg.kuruMarketsPath, "utf8")) as KuruMarket[];
    return json(res, 200, validateKuruMarkets(store, cfg.chainId, all));
  }
  return json(res, 404, { error: "not found" });
}

export function startApi(deps: ApiDeps): Server {
  const server = createServer((req, res) => {
    Promise.resolve(handle(deps, req, res)).catch((e: Error) => json(res, 500, { error: e.message }));
  });
  server.listen(deps.cfg.port);
  return server;
}
