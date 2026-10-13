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
 *   GET /history/:owner                     (trades, writes, redemptions, balance changes, settlements, liquidations:
 *                                            the frontend's profit and loss; ids are block_logIndex)
 *   GET /series/:id/positions               (every account's non-zero position in one series: who wrote it)
 *   GET /auctions/active                    (liquidation auctions not yet ended)
 *   GET /upgrades                           (UpgradeScheduled events; the caller reads each one's state on-chain)
 *   GET /visits/:page, POST /visits/:page   (page visit counts; POST body = the browser's random visitor id)
 */
import { createHash } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
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
/** Pages whose visits are counted. */
const COUNTED_PAGES = new Set(["system"]);

/** A short request body (the visitor id); undefined if it is too long. */
const readBody = (req: IncomingMessage, max = 256) =>
  new Promise<string | undefined>((resolve, reject) => {
    let body = "";
    req.on("data", (chunk: Buffer) => {
      body += chunk.toString();
      if (body.length > max) {
        resolve(undefined);
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });

export function startApi(deps: { db: Db; monitor: Monitor; client: PublicClient; manifest: Manifest }, port: number): Promise<Server> {
  const { db, monitor, client, manifest } = deps;
  const server = createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? "/", "http://x");
      const [a, b, c] = url.pathname.split("/").filter(Boolean);
      // Sent as text/plain, so browsers make no CORS preflight.
      if (req.method === "POST" && a === "visits" && b && COUNTED_PAGES.has(b) && !c) {
        const visitor = (await readBody(req))?.trim();
        if (!visitor || !/^[A-Za-z0-9-]{8,64}$/.test(visitor)) return send(res, 400, { error: "visitor id required" });
        await db.recordVisit(b, createHash("sha256").update(visitor).digest("hex"));
        return send(res, 200, await db.visitStats(b));
      }
      if (req.method !== "GET") return send(res, 405, { error: "GET only" });
      if (a === "visits" && b && COUNTED_PAGES.has(b) && !c) return send(res, 200, await db.visitStats(b));

      if (a === "series" && !b) return send(res, 200, await db.rows("Series", "TRUE", [], "ORDER BY expiry, \"strikeWad\""));
      if (a === "series" && b && isHex32(b) && c === "positions") {
        return send(res, 200, await db.rows("Position", `"seriesId" = $1 AND balance <> 0`, [b], `ORDER BY balance`));
      }
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
      if (a === "history" && b && isAddress(b)) {
        const accounts = await db.rows<{ accountId: bigint }>("Account", `lower(owner) = lower($1)`, [b], `ORDER BY "accountId"`);
        const ids = accounts.map((x) => x.accountId.toString());
        const byAccount = <T>(table: string, extra = "") =>
          ids.length ? db.rows<T>(table, `"accountId" = ANY($1)${extra}`, [ids]) : Promise.resolve([] as T[]);
        const [trades, mints, redeems, balances, settled, liquidated, liquidating] = await Promise.all([
          db.rows("Trade", `lower(trader) = lower($1)`, [b]),
          byAccount("Mint"),
          db.rows("SettlementEvent", `kind = 'REDEEMED' AND lower(holder) = lower($1)`, [b]),
          byAccount("BalanceChange"),
          byAccount("SettlementEvent", ` AND kind = 'SETTLED'`),
          byAccount("Liquidation"),
          ids.length ? db.rows("Liquidation", `"liquidatorAccountId" = ANY($1)`, [ids]) : Promise.resolve([]),
        ]);
        return send(res, 200, { accountIds: ids, trades, mints, redeems, balances, settled, liquidations: [...liquidated, ...liquidating] });
      }
      if (a === "auctions" && b === "active") return send(res, 200, await db.rows("Auction", `active = true`, [], `ORDER BY "startTime"`));
      if (a === "upgrades") return send(res, 200, await db.rows("GovernanceEvent", `kind = 'UPGRADE_SCHEDULED'`, [], "ORDER BY timestamp DESC"));
      if (a === "liquidatable") return send(res, 200, monitor.liquidatable());
      if (a === "surfaces" && b && isHex32(b) && c === "latest") {
        const [s] = await db.rows("Surface", `"productId" = $1`, [b], "ORDER BY seq DESC LIMIT 1");
        return s ? send(res, 200, s) : send(res, 404, { error: "no surface" });
      }
      if (a === "markets") return send(res, 200, await db.rows("Market"));
      // A wallet's Kuru maker orders (newest first), optionally for one series: ?series=<seriesId>.
      if (a === "kuru-orders" && b && isAddress(b)) {
        const series = url.searchParams.get("series");
        if (series && !isHex32(series)) return send(res, 400, { error: "series must be a 32-byte id" });
        const where = series ? `owner = lower($1) AND "seriesId" = $2` : `owner = lower($1)`;
        return send(res, 200, await db.rows("KuruOrder", where, series ? [b, series] : [b], `ORDER BY "updatedBlock" DESC, "orderId" DESC LIMIT 500`));
      }
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
  // HOST="::" listens on IPv6 and IPv4 (needed for IPv6-only private networks such as Railway's); default IPv4.
  return new Promise((resolve) => server.listen(port, process.env.HOST ?? "0.0.0.0", () => resolve(server)));
}
