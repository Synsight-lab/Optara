/**
 * Optara testnet price node (Cloudflare Worker). A stand-in for RedStone's public gateways, which RedStone switched
 * off in October 2026, and for Pyth on testnet, whose API now needs a paid key: it serves MON/USD, ETH/USD and USDC/USD
 * as RedStone-format signed data packages, so LiveSpotOracle
 * accepts them unchanged once governance authorizes this node's signers (`setRedstoneSigners`).
 *
 *   GET /data-packages/latest/<dataServiceId>   RedStone gateway shape: { MON: [pkg × signers], ETH: [...], USDC: [...] }
 *   GET /health                                  the prices, the exchanges behind them and the signer addresses
 *
 * Every request fetches fresh prices (cached for a couple of seconds) from several exchanges, takes the median,
 * drops outliers, and refuses to sign a feed when too few sources agree. Feeds are independent: one that cannot be
 * priced is left out (and named in `errors`) without stopping the others; USDC is needed by every product. All signers sign the same median at one
 * timestamp: the contract needs `threshold` distinct authorized signers on one timestamp and checks their spread.
 *
 * TESTNET ONLY: whoever holds these keys sets MON's price inside Optara. Mainnet uses Pyth and RedStone.
 */
import { DataPackage, NumericDataPoint } from "@redstone-finance/protocol";
import { privateKeyToAccount } from "viem/accounts";

export interface Env {
  /** Comma-separated signer private keys (a Worker secret). */
  SIGNER_KEYS: string;
  /** Drop a source further than this from the median (default 200 = 2%). */
  MAX_DEVIATION_BPS?: string;
  /** Fewest agreeing sources needed to sign MON or ETH (default 3). */
  MIN_SOURCES?: string;
}

const TIMEOUT_MS = 4_000;
const CACHE_MS = 2_000;
const DECIMALS = 8; // RedStone's numeric value decimals (LiveSpotOracle reads 8)

type Quote = { source: string; price: number };

async function getJson(url: string): Promise<any> {
  const res = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS), headers: { "user-agent": "optara-pricenode" } });
  if (!res.ok) throw new Error(`${res.status}`);
  return res.json();
}
const mid = (bid: unknown, ask: unknown) => (Number(bid) + Number(ask)) / 2;

/** USDT in USD (Kraken), to convert USDT-quoted MON markets. */
async function usdtUsd(): Promise<number> {
  const r = await getJson("https://api.kraken.com/0/public/Ticker?pair=USDTUSD");
  const t = r.result?.USDTZUSD ?? Object.values(r.result ?? {})[0];
  return mid(t.b[0], t.a[0]);
}

/** One asset's USD price from six exchanges; USDT-quoted markets are converted with `usdt`. */
function exchangeSources(base: string): Record<string, (usdt: number) => Promise<number>> {
  return {
    kraken: async () => {
      const r = (await getJson(`https://api.kraken.com/0/public/Ticker?pair=${base}USD`)).result;
      const t = r[`${base}USD`] ?? Object.values(r)[0]; // Kraken names ETH/USD "XETHZUSD"
      return mid(t.b[0], t.a[0]);
    },
    coinbase: async () => Number((await getJson(`https://api.coinbase.com/v2/prices/${base}-USD/spot`)).data.amount),
    okx: async (u) => {
      const t = (await getJson(`https://www.okx.com/api/v5/market/ticker?instId=${base}-USDT`)).data[0];
      return mid(t.bidPx, t.askPx) * u;
    },
    bybit: async (u) => {
      const t = (await getJson(`https://api.bybit.com/v5/market/tickers?category=spot&symbol=${base}USDT`)).result.list[0];
      return mid(t.bid1Price, t.ask1Price) * u;
    },
    gate: async (u) => {
      const t = (await getJson(`https://api.gateio.ws/api/v4/spot/tickers?currency_pair=${base}_USDT`))[0];
      return mid(t.highest_bid, t.lowest_ask) * u;
    },
    kucoin: async (u) => {
      const t = (await getJson(`https://api.kucoin.com/api/v1/market/orderbook/level1?symbol=${base}-USDT`)).data;
      return mid(t.bestBid, t.bestAsk) * u;
    },
  };
}

/** Feeds priced from exchanges, besides USDC. */
const ASSETS = ["MON", "ETH"] as const;

const USDC_SOURCES: Record<string, () => Promise<number>> = {
  kraken: async () => {
    const t = (await getJson("https://api.kraken.com/0/public/Ticker?pair=USDCUSD")).result.USDCUSD;
    return mid(t.b[0], t.a[0]);
  },
  coinbase: async () => Number((await getJson("https://api.coinbase.com/v2/prices/USDC-USD/spot")).data.amount),
};

function median(xs: number[]): number {
  const s = [...xs].sort((a, b) => a - b);
  const n = s.length;
  return n % 2 ? s[(n - 1) / 2]! : (s[n / 2 - 1]! + s[n / 2]!) / 2;
}

/** Median of the sources within maxDevBps of the raw median; throws when fewer than minSources agree. */
function aggregate(feed: string, quotes: Quote[], maxDevBps: number, minSources: number) {
  const ok = quotes.filter((q) => Number.isFinite(q.price) && q.price > 0);
  if (ok.length === 0) throw new Error(`${feed}: no source answered`);
  const m0 = median(ok.map((q) => q.price));
  const kept = ok.filter((q) => Math.abs(q.price / m0 - 1) * 10_000 <= maxDevBps);
  if (kept.length < minSources) throw new Error(`${feed}: only ${kept.length} of ${ok.length} sources agree (need ${minSources})`);
  return { price: median(kept.map((q) => q.price)), used: kept, dropped: ok.filter((q) => !kept.includes(q)) };
}

async function settle<T>(entries: [string, () => Promise<number>][]): Promise<Quote[]> {
  const r = await Promise.allSettled(entries.map(([, f]) => f()));
  return r.flatMap((x, i) => (x.status === "fulfilled" ? [{ source: entries[i]![0], price: x.value }] : []));
}

type Priced = ReturnType<typeof aggregate>;

/** USDC must price (every product is quoted in it); each asset is priced on its own and may fail alone. */
async function prices(env: Env) {
  const maxDev = Number(env.MAX_DEVIATION_BPS ?? 200);
  const minSources = Number(env.MIN_SOURCES ?? 3);
  const usdt = await usdtUsd().catch(() => 1);
  if (!(usdt > 0.97 && usdt < 1.03)) throw new Error(`USDT/USD ${usdt} is off peg`);
  const [usdc, ...assets] = await Promise.all([
    settle(Object.entries(USDC_SOURCES)),
    ...ASSETS.map((a) => settle(Object.entries(exchangeSources(a)).map(([k, f]) => [k, () => f(usdt)]))),
  ]);
  const USDC = aggregate("USDC", usdc!, maxDev, 1);
  if (!(USDC.price > 0.97 && USDC.price < 1.03)) throw new Error(`USDC/USD ${USDC.price} is off peg`);
  const feeds: Record<string, Priced> = { USDC };
  const errors: Record<string, string> = {};
  ASSETS.forEach((a, i) => {
    try {
      feeds[a] = aggregate(a, assets[i]!, maxDev, minSources);
    } catch (e) {
      errors[a] = (e as Error).message;
    }
  });
  return { feeds, errors, usdt };
}

function signers(env: Env) {
  const keys = (env.SIGNER_KEYS ?? "").split(",").map((k) => k.trim()).filter(Boolean);
  if (keys.length === 0) throw new Error("SIGNER_KEYS is not set");
  return keys.map((k) => ({ key: (k.startsWith("0x") ? k : `0x${k}`) as `0x${string}`, address: privateKeyToAccount((k.startsWith("0x") ? k : `0x${k}`) as `0x${string}`).address }));
}

/** One feed's packages: every signer signs the same value at the same timestamp. */
function packagesFor(feed: string, price: number, timestampMs: number, keys: ReturnType<typeof signers>) {
  const value = Math.round(price * 10 ** DECIMALS) / 10 ** DECIMALS;
  return keys.map(({ key, address }) => {
    const signed = new DataPackage([new NumericDataPoint({ dataFeedId: feed, value, decimals: DECIMALS })], timestampMs, feed).sign(key);
    return { ...signed.toObj(), dataPackageId: feed, signerAddress: address };
  });
}

let cache: { at: number; body: string } | undefined;

const json = (body: unknown, status = 200) =>
  new Response(typeof body === "string" ? body : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "access-control-allow-origin": "*", "cache-control": "no-store" },
  });

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    try {
      if (url.pathname === "/health") {
        const p = await prices(env);
        const view = (f: Priced) => ({ price: f.price, sources: f.used, dropped: f.dropped });
        return json(
          {
            ok: Object.keys(p.errors).length === 0,
            ...Object.fromEntries(Object.entries(p.feeds).map(([k, f]) => [k, view(f)])),
            errors: p.errors,
            usdtUsd: p.usdt,
            signers: signers(env).map((s) => s.address),
          },
          Object.keys(p.errors).length === ASSETS.length ? 503 : 200,
        );
      }
      if (/^\/data-packages\/latest\/[\w-]+\/?$/.test(url.pathname)) {
        if (cache && Date.now() - cache.at < CACHE_MS) return json(cache.body);
        const p = await prices(env);
        if (Object.keys(p.errors).length === ASSETS.length) throw new Error(Object.values(p.errors).join("; "));
        const keys = signers(env);
        const ts = Math.floor(Date.now() / 1000) * 1000; // whole seconds, shared by every signer
        const body = JSON.stringify(Object.fromEntries(Object.entries(p.feeds).map(([k, f]) => [k, packagesFor(k, f.price, ts, keys)])));
        cache = { at: Date.now(), body };
        return json(body);
      }
      return json({ error: "not found" }, 404);
    } catch (e) {
      // Never sign a price we don't trust: no packages is better than a wrong one.
      return json({ error: (e as Error).message }, 503);
    }
  },
};
