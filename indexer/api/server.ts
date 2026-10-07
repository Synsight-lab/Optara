/**
 * INDEXER_AND_KEEPERS.md §1.2 (non-authoritative; bigints as decimal strings):
 *   GET /series, /series/:id
 *   GET /groups, /groups/:id                (+ participant account ids, for keepers)
 *   GET /accounts/:owner                    (that owner's accounts with cash and positions)
 *   GET /accounts/:id/health, /accounts/:id/events
 *   GET /liquidatable                       (equity < MM, largest shortfall first)
 *   GET /surfaces/:productId/latest
 *   GET /markets
 *   GET /system                             (products: spot, surface, close-only; insurance; indexer progress)
 *   GET /positions                          (every non-zero position; keepers' participant source)
 *   GET /alerts                             (SECURITY.md §5)
 */
import { createServer, type Server, type ServerResponse } from "node:http";
import { isAddress, type PublicClient } from "viem";
import { portfolioRiskManagerAbi, toJson } from "@optara/sdk";
import type { Manifest } from "@optara/sdk";
import type { Db, PositionRow } from "./db.ts";
import type { Monitor } from "./monitor.ts";

const send = (res: ServerResponse, code: number, body: unknown) => {
  res.writeHead(code, { "content-type": "application/json", "access-control-allow-origin": "*" });
  res.end(toJson(body));
};
const isId = (s: string) => /^\d+$/.test(s);
const isHex32 = (s: string) => /^0x[0-9a-fA-F]{64}$/.test(s);

export function startApi(deps: { db: Db; monitor: Monitor; client: PublicClient; manifest: Manifest }, port: number): Promise<Server> {
  const { db, monitor, client, manifest } = deps;
  const server = createServer(async (req, res) => {
    try {
      if (req.method !== "GET") return send(res, 405, { error: "GET only" });
      const url = new URL(req.url ?? "/", "http://x");
      const [a, b, c] = url.pathname.split("/").filter(Boolean);

      if (a === "series" && !b) return send(res, 200, await db.rows("Series", "TRUE", [], "ORDER BY expiry, \"strikeWad\""));
      if (a === "series" && b && isHex32(b)) {
        const s = await db.one("Series", b);
        return s ? send(res, 200, s) : send(res, 404, { error: "unknown series" });
      }
      if (a === "groups" && !b) return send(res, 200, await db.rows("SettlementGroup", "TRUE", [], "ORDER BY expiry"));
      if (a === "groups" && b && isHex32(b)) {
        const g = await db.one("SettlementGroup", b);
        if (!g) return send(res, 404, { error: "unknown group" });
        const series = await db.rows<{ id: string }>("Series", `group_id = $1`, [b]);
        const holders = series.length
          ? await db.rows<PositionRow>("Position", `"seriesId" = ANY($1) AND balance <> 0`, [series.map((s) => s.id)])
          : [];
        return send(res, 200, { ...g, series: series.map((s) => s.id), participantIds: [...new Set(holders.map((h) => h.accountId))] });
      }
      if (a === "accounts" && b && isAddress(b)) {
        const accounts = await db.rows<{ accountId: bigint }>("Account", `lower(owner) = lower($1)`, [b], "ORDER BY \"accountId\"");
        const positions = accounts.length
          ? await db.rows<PositionRow>("Position", `"accountId" = ANY($1) AND balance <> 0`, [accounts.map((x) => x.accountId.toString())])
          : [];
        return send(res, 200, accounts.map((x) => ({ ...x, positions: positions.filter((p) => p.accountId === x.accountId) })));
      }
      if (a === "accounts" && b && isId(b) && c === "health") {
        const id = BigInt(b);
        const cached = monitor.health.get(id);
        if (cached) return send(res, 200, cached);
        const r = await client.readContract({ address: manifest.proxies.PortfolioRiskManager.proxy, abi: portfolioRiskManagerAbi, functionName: "riskOf", args: [id] });
        return send(res, 200, { accountId: id, ...r, at: Date.now() });
      }
      if (a === "accounts" && b && isId(b) && c === "events") {
        const [liquidations, settlements, fees] = await Promise.all([
          db.rows("Liquidation", `"accountId" = $1 OR "liquidatorAccountId" = $1`, [b], "ORDER BY timestamp"),
          db.rows("SettlementEvent", `"accountId" = $1`, [b], "ORDER BY timestamp"),
          db.rows("Fee", `"accountId" = $1`, [b], "ORDER BY timestamp"),
        ]);
        return send(res, 200, { liquidations, settlements, fees });
      }
      if (a === "liquidatable") return send(res, 200, monitor.liquidatable());
      if (a === "surfaces" && b && isHex32(b) && c === "latest") {
        const [s] = await db.rows("Surface", `"productId" = $1`, [b], "ORDER BY seq DESC LIMIT 1");
        return s ? send(res, 200, s) : send(res, 404, { error: "no surface" });
      }
      if (a === "markets") return send(res, 200, await db.rows("Market"));
      if (a === "positions") return send(res, 200, await db.rows("Position", `balance <> 0`));
      if (a === "system") {
        const [products, insurance, progress, head] = await Promise.all([db.rows("Product"), db.rows("Insurance"), db.progressBlock(), client.getBlockNumber()]);
        return send(res, 200, { products, insurance, indexer: { progressBlock: progress, head } });
      }
      if (a === "alerts") return send(res, 200, await monitor.alerts((await client.getBlock()).timestamp));
      if (a === "health") return send(res, 200, { ok: true });
      send(res, 404, { error: "not found" });
    } catch (e) {
      send(res, 500, { error: (e as Error).message.split("\n")[0] });
    }
  });
  return new Promise((resolve) => server.listen(port, "0.0.0.0", () => resolve(server)));
}
