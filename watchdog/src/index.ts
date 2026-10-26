/**
 * Optara watchdog (Cloudflare Worker, runs every minute). Checks every part of the testnet stack from outside Railway
 * and sends a Telegram message when a check fails and again when it recovers; one message per change, never one per
 * minute. A daily summary at 08:00 UTC confirms the watchdog itself is alive.
 *
 *   GET /status   the current result of every check, as JSON (no secrets)
 *   GET /test     sends the summary to Telegram now (at most once every 5 minutes)
 *   POST /telegram  Telegram webhook: /status replies with every check; answers only TELEGRAM_CHAT_ID
 *
 * A check must fail two runs in a row before it alerts, so one network blip stays quiet. State lives in KV and is
 * written only when it changes.
 */

/** The parts of Cloudflare's runtime types this Worker uses. */
interface KVNamespace {
  get(key: string): Promise<string | null>;
  put(key: string, value: string): Promise<void>;
}
interface ScheduledController {
  cron: string;
}

export interface Env {
  STATE: KVNamespace;
  /** Service binding to the price node Worker (same-account workers.dev fetches are blocked by Cloudflare). */
  PRICENODE?: { fetch(input: string): Promise<Response> };
  TELEGRAM_BOT_TOKEN: string;
  TELEGRAM_CHAT_ID: string;
  /** Telegram sends it in X-Telegram-Bot-Api-Secret-Token on every webhook call (set with setWebhook). */
  TELEGRAM_WEBHOOK_SECRET: string;
  RPC_URL: string;
  PUBLISHER_URL: string;
  INDEXER_API_URL: string;
  PRICE_NODE_URL: string;
  FRONTEND_URL: string;
  /** JSON: [{ "label": "MON / USDC", "address": "0x…" }] testnet settlement feeds the keeper pushes. */
  SETTLEMENT_FEEDS: string;
  /** JSON: [{ "label": "keeper", "address": "0x…", "minMon": 20 }] wallets that must keep gas. */
  WALLETS: string;
  /** JSON: { "<productId>": "WETH" } names for alerts. */
  PRODUCT_NAMES?: string;
  NETWORK_LABEL?: string;
}

type Check = { name: string; ok: boolean; detail: string };

const TIMEOUT_MS = 12_000;
const FEED_MAX_AGE_S = 20 * 60; // the keeper pushes every 5 minutes
const SURFACE_MAX_AGE_S = 5 * 60; // the publisher signs every minute
const INDEXER_MAX_LAG = 600; // blocks (~4 minutes on Monad testnet)

async function get(url: string, init?: RequestInit): Promise<Response> {
  return fetch(url, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS), headers: { "user-agent": "optara-watchdog", ...(init?.headers ?? {}) } });
}
async function getJson(url: string, init?: RequestInit): Promise<any> {
  const r = await get(url, init);
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}
async function rpc(env: Env, method: string, params: unknown[]): Promise<any> {
  const r = await getJson(env.RPC_URL, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  if (r.error) throw new Error(r.error.message ?? "rpc error");
  return r.result;
}
const ago = (s: number) => (s < 120 ? `${Math.round(s)} s` : s < 7200 ? `${Math.round(s / 60)} min` : `${(s / 3600).toFixed(1)} h`);
const msg = (e: unknown) => ((e as Error)?.message ?? String(e)).split("\n")[0]!.slice(0, 160);

async function run(name: string, fn: () => Promise<string>): Promise<Check> {
  try {
    return { name, ok: true, detail: await fn() };
  } catch (e) {
    return { name, ok: false, detail: msg(e) };
  }
}

async function checks(env: Env): Promise<Check[]> {
  const now = Math.floor(Date.now() / 1000);
  const feeds = JSON.parse(env.SETTLEMENT_FEEDS || "[]") as { label: string; address: string }[];
  const wallets = JSON.parse(env.WALLETS || "[]") as { label: string; address: string; minMon: number }[];
  const names = JSON.parse(env.PRODUCT_NAMES || "{}") as Record<string, string>;
  const nameOf = (id: string) => names[id.toLowerCase()] ?? id.slice(0, 10);

  const list: Promise<Check>[] = [
    run("Monad RPC", async () => `block ${parseInt(await rpc(env, "eth_blockNumber", []), 16)}`),

    run("Frontend", async () => {
      const r = await get(env.FRONTEND_URL);
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return "loads";
    }),

    run("Publisher", async () => {
      const h = await getJson(`${env.PUBLISHER_URL}/health`);
      const products = Object.values(h.products ?? {}) as { at: string; result?: { ok?: boolean; reason?: string } }[];
      if (products.length === 0) throw new Error("no volatility surfaces signed yet (still starting, or stuck)");
      const stale = products.filter((p) => now - Date.parse(p.at) / 1000 > SURFACE_MAX_AGE_S);
      const failing = products.filter((p) => p.result && p.result.ok === false);
      if (stale.length) throw new Error(`${stale.length} product(s) not signed for over ${ago(SURFACE_MAX_AGE_S)}`);
      if (failing.length) throw new Error(`signing fails: ${failing.map((p) => p.result?.reason).join(", ")}`);
      return `${products.length} products signing`;
    }),

    run("Indexer", async () => {
      const ok = await get(`${env.INDEXER_API_URL}/health`);
      if (!ok.ok) throw new Error(`API HTTP ${ok.status}`);
      const s = await getJson(`${env.INDEXER_API_URL}/system`);
      const lag = Number(s.indexer.head) - Number(s.indexer.progressBlock);
      if (lag > INDEXER_MAX_LAG) throw new Error(`${lag} blocks behind the chain`);
      return `${lag} blocks behind`;
    }),

    run("Price node (MON, ETH)", async () => {
      const url = `${env.PRICE_NODE_URL}/health`;
      const r = env.PRICENODE ? await env.PRICENODE.fetch(url) : await get(url);
      const h = (await r.json().catch(() => ({}))) as any;
      const errors = Object.entries((h.errors ?? {}) as Record<string, string>).map(([k, e]) => `${k}: ${e}`);
      if (!r.ok) throw new Error(`HTTP ${r.status}${errors.length ? `: ${errors.join("; ")}` : h.error ? `: ${h.error}` : ""}`);
      if (!h.ok) throw new Error(errors.join("; ") || h.error || "not ok");
      return ["MON", "ETH"].map((k) => `${k} $${Number(h[k].price).toPrecision(4)} (${h[k].sources.length} exchanges)`).join(", ");
    }),

    // End to end: the publisher can build fresh prices for one live option of each product (what every trade needs).
    run("Fresh prices", async () => {
      const series = (await getJson(`${env.INDEXER_API_URL}/series`)) as { id: string; productId: string; expiry: string }[];
      const byProduct = new Map<string, string>();
      for (const s of series) if (Number(s.expiry) > now + 3600 && !byProduct.has(s.productId)) byProduct.set(s.productId, s.id);
      if (byProduct.size === 0) throw new Error("no live options listed");
      const failed: string[] = [];
      for (const [product, id] of byProduct) {
        const r = await get(`${env.PUBLISHER_URL}/oracle-update?series=${id}`);
        const body = r.ok ? await r.json() as { spotProductIds?: string[] } : undefined;
        if (!r.ok || !body?.spotProductIds?.some((p) => p.toLowerCase() === product.toLowerCase())) failed.push(nameOf(product));
      }
      if (failed.length) throw new Error(`no fresh price for ${failed.join(", ")} (trading in it fails)`);
      return `${[...byProduct.keys()].map(nameOf).join(", ")} priced`;
    }),

    ...feeds.map((f) =>
      run(`Settlement feed ${f.label}`, async () => {
        // latestRoundData() -> (roundId, answer, startedAt, updatedAt, answeredInRound)
        const out = await rpc(env, "eth_call", [{ to: f.address, data: "0xfeaf968c" }, "latest"]);
        const updatedAt = parseInt(out.slice(2 + 64 * 3, 2 + 64 * 4), 16);
        const age = now - updatedAt;
        if (age > FEED_MAX_AGE_S) throw new Error(`last push ${ago(age)} ago (keeper not pushing)`);
        return `pushed ${ago(age)} ago`;
      }),
    ),

    ...wallets.map((w) =>
      run(`Gas: ${w.label}`, async () => {
        const bal = Number(BigInt(await rpc(env, "eth_getBalance", [w.address, "latest"]))) / 1e18;
        if (bal < w.minMon) throw new Error(`${bal.toFixed(2)} MON left (below ${w.minMon})`);
        return `${bal.toFixed(1)} MON`;
      }),
    ),
  ];
  return Promise.all(list);
}

async function telegram(env: Env, text: string): Promise<void> {
  const r = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: env.TELEGRAM_CHAT_ID, text, parse_mode: "HTML", disable_web_page_preview: true }),
  });
  if (!r.ok) throw new Error(`telegram ${r.status}: ${(await r.text()).slice(0, 200)}`);
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/**
 * Alerts when a check fails two runs in a row (one blip is ignored) and when a reported failure clears.
 * State: `pending` failed once, `failing` already reported. Written only when it changes.
 */
async function watch(env: Env): Promise<void> {
  const results = await checks(env);
  const saved = JSON.parse((await env.STATE.get("state")) ?? '{"pending":[],"failing":[]}') as { pending: string[]; failing: string[] };
  const pending = new Set(saved.pending);
  const reported = new Set(saved.failing);
  const failed = results.filter((c) => !c.ok);
  const down = failed.filter((c) => pending.has(c.name) && !reported.has(c.name));
  const names = new Set(results.map((c) => c.name));
  const up = [
    ...results.filter((c) => c.ok && reported.has(c.name)),
    ...[...reported].filter((n) => !names.has(n)).map((name) => ({ name, ok: true, detail: "no longer checked (config changed)" })),
  ];
  const net = env.NETWORK_LABEL ?? "Optara testnet";
  if (down.length) {
    await telegram(env, `🔴 <b>${esc(net)}: ${down.length === 1 ? "something is down" : `${down.length} problems`}</b>\n` + down.map((c) => `• <b>${esc(c.name)}</b>: ${esc(c.detail)}`).join("\n"));
  }
  if (up.length) {
    await telegram(env, `🟢 <b>${esc(net)}: recovered</b>\n` + up.map((c) => `• <b>${esc(c.name)}</b>: ${esc(c.detail)}`).join("\n"));
  }
  const next = {
    pending: failed.filter((c) => !reported.has(c.name) && !pending.has(c.name)).map((c) => c.name),
    failing: failed.filter((c) => reported.has(c.name) || pending.has(c.name)).map((c) => c.name),
  };
  if (JSON.stringify(next) !== JSON.stringify(saved)) await env.STATE.put("state", JSON.stringify(next));
}

async function summary(env: Env, title = "daily check"): Promise<void> {
  const results = await checks(env);
  const bad = results.filter((c) => !c.ok);
  const net = env.NETWORK_LABEL ?? "Optara testnet";
  await telegram(
    env,
    `${bad.length ? "🟠" : "✅"} <b>${esc(net)} ${title}</b>: ${bad.length ? `${bad.length} problem(s)` : "all good"}\n` +
      results.map((c) => `${c.ok ? "✓" : "✗"} ${esc(c.name)}: ${esc(c.detail)}`).join("\n"),
  );
}

const HELP =
  "<b>Optara watchdog</b>\n/status  every check, right now\n\nAlerts arrive on their own: 🔴 when something is down (two failed runs in a row), 🟢 when it recovers, and a summary daily at 08:00 UTC.";

/** Telegram webhook. Ignores anything not from TELEGRAM_CHAT_ID, so nobody else can use the bot. */
async function onTelegram(update: any, env: Env): Promise<void> {
  const m = update?.message;
  if (!m || String(m.chat?.id) !== String(env.TELEGRAM_CHAT_ID)) return;
  const cmd = String(m.text ?? "").trim().split(/[\s@]/)[0]!.toLowerCase();
  if (cmd === "/status") {
    await telegram(env, "⏳ Checking…");
    return summary(env, "status");
  }
  return telegram(env, HELP);
}

export default {
  async scheduled(event: ScheduledController, env: Env): Promise<void> {
    if (event.cron === "0 8 * * *") return summary(env);
    return watch(env);
  },
  async fetch(req: Request, env: Env, ctx: { waitUntil(p: Promise<unknown>): void }): Promise<Response> {
    const url = new URL(req.url);
    if (req.method === "POST" && url.pathname === "/telegram") {
      if (!env.TELEGRAM_WEBHOOK_SECRET || req.headers.get("x-telegram-bot-api-secret-token") !== env.TELEGRAM_WEBHOOK_SECRET) {
        return new Response("forbidden", { status: 403 });
      }
      const update = await req.json();
      // Answer Telegram at once and run the checks after, so it never retries the update.
      ctx.waitUntil(onTelegram(update, env).catch((e) => console.log("telegram command failed", msg(e))));
      return new Response("ok");
    }
    if (url.pathname === "/status") {
      const results = await checks(env);
      return new Response(JSON.stringify({ ok: results.every((c) => c.ok), checks: results }, null, 2), {
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    }
    if (url.pathname === "/test") {
      const last = Number((await env.STATE.get("lastTest")) ?? 0);
      if (Date.now() - last < 5 * 60_000) return new Response("A test was sent less than 5 minutes ago.", { status: 429 });
      await env.STATE.put("lastTest", String(Date.now()));
      await summary(env);
      return new Response("Test summary sent to Telegram.");
    }
    return new Response("Optara watchdog. See /status.", { status: 200 });
  },
};
