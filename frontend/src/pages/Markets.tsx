/** `/markets`: find a contract — search, filter by expiry, sort, page through 15 at a time. */
import { Fragment, useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate } from "react-router";
import type { Hex } from "viem";
import { ChevronRight, Coins, Plus, Search, TrendingDown, TrendingUp } from "lucide-react";
import { Card, EmptyState, Pill, Skeleton, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { fmtDuration, fmtExpiryShort, fmtLevel, fmtPrice, seriesName } from "../lib/optara/format.ts";
import { useQueries } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import { useAccountView, useChainTime, useProductMarket, useSeriesList, useSeriesMarket, useWalletWrappers } from "../lib/optara/hooks.ts";
import { getSeriesMarket } from "../lib/optara/reads.ts";
import { breakeven, chartRange, legOf, moveNeeded, moveText, priceLevel, profitAt } from "../lib/optara/payoff.ts";
import type { Series } from "../lib/optara/types.ts";
import { useAccountState, useQuickGuide } from "../state.tsx";
import { tradeMap } from "../lib/optara/activity.ts";

type Intent = "call" | "put" | "earn";
type SortKey = "closest" | "easiest" | "cheapest";

const PAGE_SIZE = 15;
/** Above this many contracts we skip the quote prefetch and sort with static data only. */
const PREFETCH_CAP = 60;

export function MarketsPage() {
  const { data: series, isLoading, error } = useSeriesList();
  const { data: now } = useChainTime();
  const { open: openGuide } = useQuickGuide();

  const products = useMemo(() => [...new Map((series ?? []).map((s) => [s.productId, s])).values()], [series]);
  const [productId, setProductId] = useState<Hex | undefined>();
  const product = products.find((p) => p.productId === productId) ?? products[0];

  const all = (series ?? []).filter((s) => s.productId === product?.productId);
  const open = all.filter((s) => now === undefined || s.expiry > now);
  const nextExpiry = open.reduce<bigint | undefined>((m, s) => (m === undefined || s.expiry < m ? s.expiry : m), undefined);
  const [intent, setIntent] = useState<Intent>("call");
  const [query, setQuery] = useState("");

  if (error) return <Card><EmptyState title="Couldn't load markets" body={(error as Error).message} /></Card>;
  if (isLoading) return <div className="space-y-3"><Skeleton className="h-32 w-full rounded-3xl" /><Skeleton className="h-64 w-full rounded-3xl" /></div>;
  if (!product) return <Card><EmptyState title="No markets listed yet" body="Be the first to list one." action={<Link to="/app/new" className="btn-primary mt-3 text-xs">New market</Link>} /></Card>;

  return (
    <div className="space-y-4">
      <div className="grid gap-4 lg:grid-cols-[300px_minmax(0,1fr)] lg:items-start">
        <aside className="space-y-3 lg:sticky lg:top-[84px]">
          <MarketHero product={product} />
          <MarketStats assetCount={products.length} openCount={open.length} nextExpiry={nextExpiry} now={now} />

          {products.length > 1 && (
            <div className="card p-2">
              <div className="grid grid-cols-2 gap-1.5 lg:grid-cols-1">
                {products.map((p) => (
                  <button
                    key={p.productId}
                    onClick={() => setProductId(p.productId)}
                    className={cx("flex min-h-[44px] shrink-0 items-center gap-2 rounded-xl border px-3 text-[13px] font-semibold cursor-pointer", p.productId === product.productId ? "border-primary/50 bg-primary-soft text-primary" : "border-line bg-surface text-muted")}
                  >
                    <TokenIcon symbol={p.underlyingSymbol} className="h-4 w-4" />
                    <span>{p.underlyingSymbol}/{p.assetSymbol}</span>
                  </button>
                ))}
              </div>
            </div>
          )}

          <div className="page-band space-y-2">
            <div className="text-[11px] font-bold uppercase text-faint">Choose an action</div>
            <div className="grid grid-cols-3 gap-1.5 lg:grid-cols-1">
            <IntentButton active={intent === "call"} onClick={() => setIntent("call")} tone="up" icon={<TrendingUp className="h-4 w-4" />} title="Up" sub="Buy calls" />
            <IntentButton active={intent === "put"} onClick={() => setIntent("put")} tone="down" icon={<TrendingDown className="h-4 w-4" />} title="Down" sub="Buy puts" />
            <IntentButton active={intent === "earn"} onClick={() => setIntent("earn")} tone="earn" icon={<Coins className="h-4 w-4" />} title="Earn" sub="Write options" />
            </div>
          </div>
        </aside>

        <MarketList
          product={product}
          all={all}
          now={now}
          intent={intent}
          query={query}
          onQuery={setQuery}
          onGuide={openGuide}
        />
      </div>
    </div>
  );
}

function MarketStats({ assetCount, openCount, nextExpiry, now }: { assetCount: number; openCount: number; nextExpiry?: bigint; now?: bigint }) {
  return (
    <div className="grid grid-cols-3 gap-2">
      <MarketStat label="Assets" value={assetCount.toString()} />
      <MarketStat label="Open" value={openCount.toString()} />
      <MarketStat label="Next expiry" value={nextExpiry !== undefined && now !== undefined ? fmtDuration(nextExpiry - now) : "—"} />
    </div>
  );
}

function MarketStat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border border-line bg-surface-2/70 p-2.5">
      <div className="text-[10px] font-bold uppercase text-faint">{label}</div>
      <div className="num mt-1 truncate font-display text-base font-bold">{value}</div>
    </div>
  );
}

function IntentButton({ active, onClick, tone, icon, title, sub }: { active: boolean; onClick(): void; tone: "up" | "down" | "earn"; icon: React.ReactNode; title: string; sub: string }) {
  const ring = tone === "up" ? "border-good/60 bg-good/8" : tone === "down" ? "border-bad/60 bg-bad/8" : "border-accent/50 bg-accent/8";
  const fg = tone === "up" ? "text-good" : tone === "down" ? "text-bad" : "text-accent";
  return (
    <button onClick={onClick} aria-pressed={active} className={cx("flex min-h-[64px] flex-col items-start justify-center rounded-lg border p-2.5 cursor-pointer", active ? ring : "border-line bg-surface")}>
      <span className={cx("flex items-center gap-1 text-sm font-bold", active ? fg : "text-ink")}>{icon}{title}</span>
      <span className="mt-0.5 text-[11px] text-muted">{sub}</span>
    </button>
  );
}

function MarketHero({ product }: { product: Series }) {
  const { data: m } = useProductMarket(product.productId);
  return (
    <section className="card rise overflow-hidden p-4">
      <div className="flex items-center gap-2.5">
        <TokenIcon symbol={product.underlyingSymbol} className="h-10 w-10" />
        <div className="min-w-0 flex-1">
          <h1 className="font-display truncate text-lg font-bold tracking-tight">{product.underlyingSymbol} options</h1>
          <p className="truncate text-xs text-muted">Cash-settled in {product.assetSymbol}</p>
        </div>
        <div className="text-right">
          <div className="text-[11px] text-muted">Spot</div>
          <div className="num font-display whitespace-nowrap text-xl font-bold leading-none tracking-tight">{m ? `$${fmtLevel(m.spotWad)}` : <Skeleton className="h-7 w-20" />}</div>
        </div>
        <Link to="/app/new" aria-label="List a new market" title="List a new market" className="btn-ghost !px-2.5 !py-2 shrink-0">
          <Plus className="h-4 w-4" />
        </Link>
      </div>
      <div className="mt-2.5 flex items-center gap-1.5">
        {m && <Pill tone={m.spotFresh ? "good" : "warn"} dot>{m.spotFresh ? "Live" : "Delayed"}</Pill>}
        {m?.closeOnly && <Pill tone="warn">Close only</Pill>}
        <span className="text-[11px] text-faint">Buyers can't be liquidated</span>
      </div>
    </section>
  );
}

function premiumOf(mk: { mark?: bigint; quote?: { ask?: bigint; bid?: bigint } } | undefined, intent: Intent): bigint | undefined {
  if (!mk) return undefined;
  return intent === "earn" ? (mk.quote?.bid ?? mk.mark) : (mk.quote?.ask ?? mk.mark);
}

/** How far the price must move, in the option's direction, before a buyer at this price profits (0.05 = 5%). */
function moveToProfit(s: Series, spotN: number | undefined, premium: bigint | undefined): number | undefined {
  if (spotN === undefined || premium === undefined) return undefined;
  const leg = legOf(s);
  const be = breakeven(leg, Number(premium) / 1e18);
  return be === undefined ? undefined : moveNeeded(leg, spotN, be);
}

type StatusKey = "all" | "active" | "expiring" | "expired" | "yours";
type SortKey2 = SortKey | "strikeAsc" | "strikeDesc" | "expirySoon" | "expiryLate" | "newest" | "oldest" | "recent";

/** Expiries within this window count as expiring soon. */
const EXPIRING_WINDOW = 7n * 86_400n;

function MarketList({
  product, all, now, intent, query, onQuery, onGuide,
}: {
  product: Series; all: Series[]; now?: bigint; intent: Intent;
  query: string; onQuery(q: string): void;
  onGuide(): void;
}) {
  const navigate = useNavigate();
  const { address } = useConnection();
  const { selected } = useAccountState();
  const { data: m } = useProductMarket(product.productId);
  const { data: wallet } = useWalletWrappers(address);
  const { data: account } = useAccountView(selected);
  const spot = m?.spotWad;
  const spotN = spot !== undefined ? Number(spot) / 1e18 : undefined;
  const [status, setStatus] = useState<StatusKey>("all");
  const [sort, setSort] = useState<SortKey2>("closest");
  const [visible, setVisible] = useState(PAGE_SIZE);
  const [loadingMore, setLoadingMore] = useState(false);
  const sentinelRef = useRef<HTMLDivElement>(null);

  const want = intent === "call" ? 0 : intent === "put" ? 1 : undefined;
  const walletIds = useMemo(() => new Set((wallet ?? []).filter((w) => w.balance > 0n).map((w) => w.series.id.toLowerCase())), [wallet]);
  const positionIds = useMemo(() => new Set((account?.positions ?? []).filter((pos) => pos.balance !== 0n).map((pos) => pos.seriesId.toLowerCase())), [account]);
  const trades = useMemo(() => tradeMap(address), [address, wallet, account]);

  const base = useMemo(() => {
    const q = query.trim().toLowerCase();
    return all.filter((s) => {
      if (want !== undefined && s.optionType !== want) return false;
      const expired = now !== undefined && s.expiry <= now;
      if (status === "active" && expired) return false;
      if (status === "expired" && !expired) return false;
      if (status === "expiring" && (expired || now === undefined || s.expiry - now > EXPIRING_WINDOW)) return false;
      if (status === "yours") {
        const id = s.id.toLowerCase();
        if (!walletIds.has(id) && !positionIds.has(id) && !trades.has(id)) return false;
      }
      if (!q) return true;
      if (seriesName(s).toLowerCase().includes(q)) return true;
      const digits = q.replace(/[^0-9]/g, "");
      if (digits && String(Math.round(Number(s.strikeWad) / 1e18)).includes(digits)) return true;
      if (fmtExpiryShort(s.expiry).toLowerCase().includes(q)) return true;
      if ("call".includes(q) && s.optionType === 0) return true;
      if ("put".includes(q) && s.optionType === 1) return true;
      return false;
    });
  }, [all, want, query, status, now, walletIds, positionIds, trades]);

  useEffect(() => { setVisible(PAGE_SIZE); setLoadingMore(false); }, [query, status, sort, intent, product.productId]);


  // Prefetch quotes so price-based sorts cover the whole result — skipped past the cap.
  const prefetch = base.length <= PREFETCH_CAP;
  const markets = useQueries({
    queries: (prefetch ? base : []).map((s) => ({
      queryKey: ["seriesMarket", s.id],
      queryFn: () => getSeriesMarket(s),
      staleTime: 15_000,
    })),
  });
  const enriched = useMemo(() => base.map((s, i) => {
    const premium = prefetch ? premiumOf(markets[i]?.data, intent) : undefined;
    const strike = Number(s.strikeWad) / 1e18;
    const expired = now !== undefined && s.expiry <= now;
    return {
      s, premium, expired,
      move: moveToProfit(s, spotN, premium),
      dist: spotN === undefined ? Infinity : Math.abs(strike - spotN),
      tradedAt: trades.get(s.id.toLowerCase())?.at ?? 0,
    };
  }), [base, prefetch, markets, intent, spotN, now, trades]);

  const sorted = useMemo(() => {
    const arr = [...enriched].sort((a, b) => {
      switch (sort) {
        case "easiest": return (a.move ?? Infinity) - (b.move ?? Infinity);
        case "cheapest":
          if (a.premium === undefined) return 1;
          if (b.premium === undefined) return -1;
          return a.premium < b.premium ? -1 : 1;
        case "strikeAsc": return a.s.strikeWad < b.s.strikeWad ? -1 : 1;
        case "strikeDesc": return a.s.strikeWad > b.s.strikeWad ? -1 : 1;
        case "expirySoon": return a.s.expiry < b.s.expiry ? -1 : 1;
        case "expiryLate": return a.s.expiry > b.s.expiry ? -1 : 1;
        case "newest": return (b.s.listedAt ?? 0) - (a.s.listedAt ?? 0);
        case "oldest": return (a.s.listedAt ?? 0) - (b.s.listedAt ?? 0);
        case "recent": return b.tradedAt - a.tradedAt;
        default: return a.dist - b.dist;
      }
    });
    // Settled contracts always sink to the bottom.
    return [...arr.filter((r) => !r.expired), ...arr.filter((r) => r.expired)];
  }, [enriched, sort]);

  const shown = sorted.slice(0, visible);
  // Infinite scroll: nearing the end appends the next page with a brief shimmer.
  const visibleRef = useRef(visible);
  visibleRef.current = visible;
  useEffect(() => {
    const el = sentinelRef.current;
    if (!el || loadingMore) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const io = new IntersectionObserver(
      (entries) => {
        if (entries[0]!.isIntersecting && visibleRef.current < sorted.length) {
          setLoadingMore(true);
          timer = setTimeout(() => {
            setVisible((v) => Math.min(v + PAGE_SIZE, sorted.length));
            setLoadingMore(false);
          }, 450);
        }
      },
      { rootMargin: "320px" }
    );
    io.observe(el);
    return () => {
      io.disconnect();
      if (timer) clearTimeout(timer);
    };
  }, [sorted.length, loadingMore, shown.length]);
  const grouped = sort === "closest" || sort === "easiest" || sort === "cheapest" || sort === "strikeAsc" || sort === "strikeDesc";
  const needsQuotes = sort === "easiest" || sort === "cheapest";

  return (
    <div className="space-y-2">
      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-faint" />
        <input
          value={query}
          onChange={(e) => onQuery(e.target.value)}
          placeholder="Search by name, strike or date…"
          aria-label="Search markets"
          className="input !pl-9"
        />
      </div>

      <div className="flex gap-1.5 overflow-x-auto scrollbar-none" role="tablist" aria-label="Status">
        {([
          ["all", "All"],
          ["active", "Active"],
          ["expiring", "Expiring soon"],
          ["expired", "Expired"],
          ["yours", "Yours"],
        ] as [StatusKey, string][]).map(([v, label]) => (
          <button
            key={v}
            role="tab"
            aria-selected={status === v}
            onClick={() => setStatus(v)}
            className={cx("min-h-[40px] shrink-0 rounded-xl border px-3 text-[13px] font-semibold cursor-pointer", status === v ? "border-primary/60 bg-primary-soft text-primary" : "border-line bg-surface text-muted")}
          >
            {label}
          </button>
        ))}
      </div>

      <div className="flex items-center gap-1.5">
        <label className="sr-only" htmlFor="market-sort">Sort</label>
        <select
          id="market-sort"
          value={sort}
          onChange={(e) => setSort(e.target.value as SortKey2)}
          className="input min-h-[44px] flex-1 cursor-pointer !py-2 text-[13px] font-semibold"
        >
          <option value="closest">Closest to spot</option>
          <option value="easiest" disabled={!prefetch || intent === "earn"}>Smallest move to profit{!prefetch ? " (narrow search first)" : ""}</option>
          <option value="cheapest" disabled={!prefetch}>Cheapest first{!prefetch ? " (narrow search first)" : ""}</option>
          <option value="strikeAsc">Strike low to high</option>
          <option value="strikeDesc">Strike high to low</option>
          <option value="expirySoon">Expiring soonest</option>
          <option value="expiryLate">Expiring latest</option>
          <option value="newest">Newest listed</option>
          <option value="oldest">Oldest listed</option>
          <option value="recent">Recently traded</option>
        </select>
      </div>
      {needsQuotes && !prefetch && (
        <p className="px-1 text-xs text-muted">Too many results to rank by price ({base.length}). Search or filter to narrow it down.</p>
      )}

      <p className="px-1 text-[13px] leading-snug text-muted">
        {intent === "call" && <>Calls pay if the price ends above the target. Each row shows how far it has to rise for you to profit.</>}
        {intent === "put" && <>Puts pay if the price ends below the target. Each row shows how far it has to fall for you to profit.</>}
        {intent === "earn" && <>Write an option and collect its price now. You owe the payout if it ends past the target. Needs a margin account.</>}
        {" "}<button onClick={onGuide} className="font-semibold text-primary cursor-pointer">Learn</button>
      </p>

      <div className="card overflow-hidden p-1.5">
        {sorted.length === 0 ? (
          <EmptyState
            title={all.length === 0 ? "No markets here yet" : "No matches"}
            body={all.length === 0 ? "List the first contract." : "Try another name, strike, or status."}
            action={<Link to="/app/new" className="btn-ghost mt-2 text-xs">New market</Link>}
          />
        ) : (
          <>
            <div className="px-2 pb-1 pt-1 text-[11px] font-semibold text-faint">
              {sorted.length} contract{sorted.length === 1 ? "" : "s"}{sorted.length > shown.length ? ` · showing ${shown.length}` : ""}
            </div>
            <ul className="divide-y divide-line/60">
              {shown.map(({ s, expired }, i) => (
                <Fragment key={s.id}>
                  {grouped && (i === 0 || shown[i - 1]!.s.expiry !== s.expiry) && (
                    <li className="px-2.5 pb-0.5 pt-2 text-[11px] font-bold text-muted">
                      {fmtExpiryShort(s.expiry)}{now !== undefined && !expired ? ` · in ${fmtDuration(s.expiry - now)}` : expired ? " · settled" : ""}
                    </li>
                  )}
                  <OptionRow
                    s={s} spot={spot} spotN={spotN} intent={intent} expired={expired}
                    held={walletIds.has(s.id.toLowerCase()) || positionIds.has(s.id.toLowerCase())}
                    onOpen={() => navigate(expired ? `/app/series/${s.id}?tab=redeem` : intent === "earn" ? `/app/write/${s.id}` : `/app/series/${s.id}?tab=trade`)}
                  />
                </Fragment>
              ))}
            </ul>
            {sorted.length > shown.length && (
              <div ref={sentinelRef} className="py-2">
                {loadingMore ? (
                  <ul aria-label="Loading more markets" className="divide-y divide-line/60">
                    {[0, 1, 2].map((i) => (
                      <li key={i} className="flex min-h-[68px] items-center gap-2.5 px-2.5 py-2.5">
                        <span className="min-w-0 flex-1">
                          <Skeleton className="h-5 w-28" />
                          <Skeleton className="mt-1.5 h-3.5 w-40" />
                        </span>
                        <Skeleton className="h-6 w-14" />
                      </li>
                    ))}
                  </ul>
                ) : (
                  <div className="flex flex-col items-center gap-2 py-2.5">
                    <button
                      type="button"
                      onClick={() => setVisible((v) => Math.min(v + PAGE_SIZE, sorted.length))}
                      className="btn-ghost text-xs"
                    >
                      Load more markets
                    </button>
                    <p className="text-center text-[11px] font-semibold text-faint">
                      {sorted.length - shown.length} left
                    </p>
                  </div>
                )}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}

function OptionRow({ s, spot, spotN, intent, expired, held, onOpen }: { s: Series; spot?: bigint; spotN?: number; intent: Intent; expired?: boolean; held?: boolean; onOpen(): void }) {
  const { data: mk } = useSeriesMarket(s);
  const leg = legOf(s);
  const quote = intent === "earn" ? mk?.quote?.bid : mk?.quote?.ask;
  // With no order on the book, show the protocol's fair value, labelled as such.
  const price = quote ?? mk?.mark;
  const priceN = price !== undefined ? Number(price) / 1e18 : undefined;
  const be = priceN !== undefined ? breakeven(leg, priceN) : undefined;
  const beMove = be !== undefined && spotN !== undefined ? moveNeeded(leg, spotN, be) : undefined;
  const itm = spot !== undefined && (s.optionType === 0 ? spot > s.strikeWad : spot < s.strikeWad);
  const toStrike = spotN !== undefined ? moveNeeded(leg, spotN, leg.strike) : undefined;

  const detail = expired
    ? `${seriesName(s)} · expired`
    : intent === "earn"
    ? toStrike === undefined
      ? seriesName(s)
      : itm
      ? "In the money now: a writer would owe a payout"
      : `You keep it all unless the price ${moveText(leg, toStrike, 1, true)}`
    : be === undefined || beMove === undefined
    ? seriesName(s)
    : beMove <= 0
    ? `Profitable at today's price (breakeven ${priceLevel(be)})`
    : `Profit if the price ${moveText(leg, beMove, 1, true)}, past ${priceLevel(be)}`;

  return (
    <li>
      <button onClick={onOpen} className="flex min-h-[68px] w-full items-center gap-2.5 rounded-2xl px-2.5 py-2.5 text-left transition active:scale-[0.99] hover:bg-primary-soft/50 cursor-pointer">
        <span className="min-w-0 flex-1">
          <span className="flex flex-wrap items-center gap-1.5">
            <span className={cx("num font-display text-[17px] font-bold tracking-tight", expired && "text-muted")}>{priceLevel(leg.strike)}</span>
            <span className={cx("text-xs font-semibold", s.optionType === 0 ? "text-good" : "text-bad")}>{s.optionType === 0 ? "Call" : "Put"}</span>
            {expired && <span className="pill border border-line bg-surface-2 text-muted !text-[11px]">Expired</span>}
            {held && !expired && <span className="pill bg-primary-soft text-primary !text-[11px]">Yours</span>}
            {itm && !expired && <span className="pill border border-good/25 bg-good/10 text-good !text-[11px]">In the money</span>}
          </span>
          <span className="mt-0.5 block truncate text-xs text-muted">{detail}</span>
        </span>
        <Sparkline optionType={s.optionType} strike={leg.strike} size={leg.size} spot={spotN} premium={priceN} side={intent === "earn" ? "short" : "long"} />
        <span className="shrink-0 text-right">
          <span className="num font-display block text-[15px] font-semibold">{price !== undefined ? fmtPrice(price) : "—"}</span>
          <span className="block text-[11px] text-muted">
            {expired ? "" : quote === undefined ? (price !== undefined ? "fair value, no orders" : "no orders") : intent === "earn" ? "you collect" : "per option"}
          </span>
        </span>
        <ChevronRight className="h-4 w-4 shrink-0 text-faint" />
      </button>
    </li>
  );
}

function Sparkline({
  optionType,
  strike,
  size,
  spot,
  premium,
  side,
}: {
  optionType: number;
  strike: number;
  size: number;
  spot?: number;
  premium?: number;
  side: "long" | "short";
}) {
  const cost = premium ?? 0;
  const leg = { optionType, strike, size };
  const be = premium !== undefined ? breakeven(leg, cost) : undefined;
  const [lo, hi] = chartRange([spot ?? strike, strike, be ?? strike]);
  const samples: [number, number][] = [];
  for (let i = 0; i <= 32; i++) {
    const px = lo + ((hi - lo) * i) / 32;
    samples.push([px, profitAt(leg, side, 1, cost, px)]);
  }
  const min = Math.min(0, ...samples.map(([, v]) => v));
  const max = Math.max(0, ...samples.map(([, v]) => v));
  const span = max - min || 1;
  const pts = samples.map(([px, v]) => `${((px - lo) / (hi - lo)) * 64},${22 - ((v - min) / span) * 20}`);
  const color = side === "long" ? (optionType === 0 ? "var(--good)" : "var(--bad)") : "var(--accent)";
  const zeroY = 22 - ((0 - min) / span) * 20;
  return (
    <svg width="64" height="24" viewBox="0 0 64 24" className="shrink-0 opacity-80" aria-hidden>
      <line x1="0" x2="64" y1={zeroY} y2={zeroY} stroke="var(--muted)" strokeOpacity="0.35" strokeDasharray="2 3" />
      <polyline points={pts.join(" ")} fill="none" stroke={color} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
