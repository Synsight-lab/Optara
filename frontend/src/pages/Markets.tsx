/** `/`: find a contract — search, filter by expiry, sort, page through 15 at a time. */
import { Fragment, useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate } from "react-router";
import type { Hex } from "viem";
import { ChevronRight, Coins, Plus, Search, TrendingDown, TrendingUp } from "lucide-react";
import { Card, EmptyState, Pill, Skeleton, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { fmtDuration, fmtExpiryShort, fmtPrice, fmtWad, seriesName } from "../lib/optara/format.ts";
import { useQueries } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import { useAccountView, useChainTime, useProductMarket, useSeriesList, useSeriesMarket, useWalletWrappers } from "../lib/optara/hooks.ts";
import { getSeriesMarket } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { useAccountState, useQuickGuide } from "../state.tsx";
import { tradeMap } from "../lib/optara/activity.ts";

type Intent = "call" | "put" | "earn";
type SortKey = "closest" | "leverage" | "cheapest";

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
  const [intent, setIntent] = useState<Intent>("call");
  const [query, setQuery] = useState("");

  if (error) return <Card><EmptyState title="Couldn't load markets" body={(error as Error).message} /></Card>;
  if (isLoading) return <div className="space-y-3"><Skeleton className="h-32 w-full rounded-3xl" /><Skeleton className="h-64 w-full rounded-3xl" /></div>;
  if (!product) return <Card><EmptyState title="No markets listed yet" body="Be the first to list one." action={<Link to="/new" className="btn-primary mt-3 text-xs">New market</Link>} /></Card>;

  return (
    <div className="space-y-3">
      <MarketHero product={product} />

      {products.length > 1 && (
        <div className="flex gap-1.5 overflow-x-auto scrollbar-none">
          {products.map((p) => (
            <button
              key={p.productId}
              onClick={() => setProductId(p.productId)}
              className={cx("flex min-h-[44px] shrink-0 items-center gap-1.5 rounded-2xl border px-3 text-[13px] font-semibold cursor-pointer", p.productId === product.productId ? "border-primary/50 bg-primary-soft text-primary" : "border-line bg-surface text-muted")}
            >
              <TokenIcon symbol={p.underlyingSymbol} className="h-4 w-4" />
              {p.underlyingSymbol}
            </button>
          ))}
        </div>
      )}

      <div className="grid grid-cols-3 gap-1.5">
        <IntentButton active={intent === "call"} onClick={() => setIntent("call")} tone="up" icon={<TrendingUp className="h-4 w-4" />} title="Up" sub="Calls" />
        <IntentButton active={intent === "put"} onClick={() => setIntent("put")} tone="down" icon={<TrendingDown className="h-4 w-4" />} title="Down" sub="Puts" />
        <IntentButton active={intent === "earn"} onClick={() => setIntent("earn")} tone="earn" icon={<Coins className="h-4 w-4" />} title="Earn" sub="Write" />
      </div>

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
  );
}

function IntentButton({ active, onClick, tone, icon, title, sub }: { active: boolean; onClick(): void; tone: "up" | "down" | "earn"; icon: React.ReactNode; title: string; sub: string }) {
  const ring = tone === "up" ? "border-good/60 bg-good/8" : tone === "down" ? "border-bad/60 bg-bad/8" : "border-accent/50 bg-accent/8";
  const fg = tone === "up" ? "text-good" : tone === "down" ? "text-bad" : "text-accent";
  return (
    <button onClick={onClick} aria-pressed={active} className={cx("flex min-h-[64px] flex-col items-start justify-center rounded-2xl border p-2.5 cursor-pointer", active ? ring : "border-line bg-surface")}>
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
          <h1 className="font-display text-lg font-bold tracking-tight">{product.underlyingSymbol} options</h1>
          <p className="truncate text-xs text-muted">Cash-settled in {product.assetSymbol}</p>
        </div>
        <div className="text-right">
          <div className="text-[11px] text-muted">Spot</div>
          <div className="num font-display text-[26px] font-bold leading-none tracking-tight">{m ? `$${fmtWad(m.spotWad, 0)}` : <Skeleton className="h-7 w-20" />}</div>
        </div>
        <Link to="/new" aria-label="List a new market" title="List a new market" className="btn-ghost !px-2.5 !py-2 shrink-0">
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

function leverageOf(s: Series, spotN: number | undefined, premium: bigint | undefined): number | undefined {
  if (spotN === undefined || premium === undefined) return undefined;
  const prem = Number(premium) / 1e18;
  if (!(prem > 0)) return undefined;
  const strike = Number(s.strikeWad) / 1e18;
  const payout = s.optionType === 0 ? Math.max(0, spotN * 1.15 - strike) : Math.max(0, strike - spotN * 0.85);
  return payout / prem;
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
      lev: leverageOf(s, spotN, premium),
      dist: spotN === undefined ? Infinity : Math.abs(strike - spotN),
      tradedAt: trades.get(s.id.toLowerCase())?.at ?? 0,
    };
  }), [base, prefetch, markets, intent, spotN, now, trades]);

  const sorted = useMemo(() => {
    const arr = [...enriched].sort((a, b) => {
      switch (sort) {
        case "leverage": return (b.lev ?? -1) - (a.lev ?? -1);
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
  const grouped = sort === "closest" || sort === "leverage" || sort === "cheapest" || sort === "strikeAsc" || sort === "strikeDesc";
  const needsQuotes = sort === "leverage" || sort === "cheapest";

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
          <option value="leverage" disabled={!prefetch}>Highest leverage{!prefetch ? " (narrow search first)" : ""}</option>
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
        {intent === "call" && <>Targets above spot. More climb past target, more payout.</>}
        {intent === "put" && <>Targets below spot. Falls through it, you profit.</>}
        {intent === "earn" && <>Back a contract. Keep premium today.</>}
        {" "}<button onClick={onGuide} className="font-semibold text-primary cursor-pointer">Learn</button>
      </p>

      <div className="card overflow-hidden p-1.5">
        {sorted.length === 0 ? (
          <EmptyState
            title={all.length === 0 ? "No markets here yet" : "No matches"}
            body={all.length === 0 ? "List the first contract." : "Try another name, strike, or status."}
            action={<Link to="/new" className="btn-ghost mt-2 text-xs">New market</Link>}
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
                    onOpen={() => navigate(`/series/${s.id}?tab=${expired ? "redeem" : intent === "earn" ? "write" : "trade"}`)}
                  />
                </Fragment>
              ))}
            </ul>
            {sorted.length > shown.length && (
              <div ref={sentinelRef}>
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
                  <p className="py-2.5 text-center text-[11px] font-semibold text-faint">
                    Scroll for more · {sorted.length - shown.length} left
                  </p>
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
  const strike = Number(s.strikeWad) / 1e18;
  const away = spotN !== undefined ? ((strike - spotN) / spotN) * 100 : undefined;
  const price = intent === "earn" ? (mk?.quote?.bid ?? mk?.mark) : (mk?.quote?.ask ?? mk?.mark);
  const priceN = price !== undefined ? Number(price) / 1e18 : undefined;
  const breakeven = priceN !== undefined ? (s.optionType === 0 ? strike + priceN : strike - priceN) : undefined;
  const upside = priceN && spotN ? (s.optionType === 0 ? Math.max(0, spotN * 1.15 - strike) / priceN : Math.max(0, strike - spotN * 0.85) / priceN) : undefined;
  const itm = spot !== undefined && (s.optionType === 0 ? spot > s.strikeWad : spot < s.strikeWad);

  return (
    <li>
      <button onClick={onOpen} className="flex min-h-[68px] w-full items-center gap-2.5 rounded-2xl px-2.5 py-2.5 text-left transition active:scale-[0.99] hover:bg-primary-soft/50 cursor-pointer">
        <span className="min-w-0 flex-1">
          <span className="flex items-center gap-1.5">
            <span className={cx("num font-display text-[17px] font-bold tracking-tight", expired && "text-muted")}>${fmtWad(s.strikeWad, 0)}</span>
            {expired && <span className="pill border border-line bg-surface-2 text-muted !text-[11px]">Expired</span>}
            {held && !expired && <span className="pill bg-primary-soft text-primary !text-[11px]">Yours</span>}
            {away !== undefined && (
              <span className={cx("num text-xs font-semibold", away > 0 ? "text-good" : away < 0 ? "text-bad" : "text-muted")}>
                {away > 0 ? `+${away.toFixed(1)}%` : `${away.toFixed(1)}%`}
              </span>
            )}
          </span>
          <span className="mt-0.5 block truncate text-xs text-muted">
            {seriesName(s)}
            {breakeven !== undefined ? ` · BE $${Math.round(breakeven).toLocaleString()}` : ""}
            {itm && !expired ? " · ITM" : ""}
          </span>
        </span>
        <Sparkline optionType={s.optionType} strike={strike} spot={spotN} />
        <span className="shrink-0 text-right">
          <span className="num font-display block text-[15px] font-semibold">{price !== undefined ? fmtPrice(price) : "—"}</span>
          <span className="block text-[11px] text-muted">{expired ? "settled" : intent === "earn" ? "you collect" : upside !== undefined ? `up to ${upside.toFixed(1)}×` : ""}</span>
        </span>
        <ChevronRight className="h-4 w-4 shrink-0 text-faint" />
      </button>
    </li>
  );
}

function Sparkline({ optionType, strike, spot }: { optionType: number; strike: number; spot?: number }) {
  const c = spot ?? strike;
  const lo = c * 0.7;
  const hi = c * 1.3;
  const pts: string[] = [];
  for (let i = 0; i <= 24; i++) {
    const px = lo + ((hi - lo) * i) / 24;
    const v = optionType === 0 ? Math.max(0, px - strike) : Math.max(0, strike - px);
    pts.push(`${(i / 24) * 64},${22 - Math.min(1, v / (c * 0.3)) * 20}`);
  }
  const up = optionType === 0;
  const color = up ? "var(--good)" : "var(--bad)";
  return (
    <svg width="64" height="24" viewBox="0 0 64 24" className="shrink-0 opacity-80" aria-hidden>
      <polyline points={pts.join(" ")} fill="none" stroke={color} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
