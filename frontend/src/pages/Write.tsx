/**
 * `/write` and `/write/:id`: earn premium by writing options (OptionClearing.mintExternalLong, USER_FLOWS.md F2).
 * Three steps: choose what to write → your margin account → amount, premium and risk. The order form itself is the
 * option page's Earn panel (WritePanel), so both places behave identically.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { useConnection } from "wagmi";
import type { Hex } from "viem";
import { ArrowRight, CheckCircle2, Coins, Search, ShieldCheck, TrendingDown, TrendingUp, Wallet } from "lucide-react";
import { Card, EmptyState, Pill, Skeleton, cx } from "../components/ui.tsx";
import { HealthBar } from "../components/HealthBar.tsx";
import { PayoffChart } from "../components/PayoffChart.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import type { ActionContext } from "../lib/optara/availability.ts";
import { fmtDuration, fmtExpiryShort, fmtLevel, fmtNative, fmtPrice } from "../lib/optara/format.ts";
import { useAccountView, useChainTime, useProductMarket, useSeries, useSeriesList, useSeriesMarket, useWalletWrappers } from "../lib/optara/hooks.ts";
import { legOf, moveNeeded, moveText } from "../lib/optara/payoff.ts";
import type { Series } from "../lib/optara/types.ts";
import { useAccountState, useQuickGuide } from "../state.tsx";
import { WritePanel } from "./Series.tsx";

const WRITE_EXPIRING_WINDOW = 7n * 86_400n;
type WriteStatus = "all" | "expiring" | "later";
type WriteSort = "expirySoon" | "strikeAsc" | "strikeDesc";

export function WritePage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { data: all, isLoading } = useSeriesList();
  const { data: now } = useChainTime();
  const { open: openGuide } = useQuickGuide();
  const fromUrl = useSeries(id as Hex | undefined);

  const active = useMemo(() => (all ?? []).filter((s) => now === undefined || s.expiry > now), [all, now]);
  const products = useMemo(() => [...new Map(active.map((s) => [s.productId, s])).values()], [active]);
  const [productId, setProductId] = useState<Hex | undefined>();
  const [type, setType] = useState<0 | 1>(0);
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<WriteStatus>("all");
  const [sort, setSort] = useState<WriteSort>("expirySoon");

  // Opening /write/:id preselects that option.
  useEffect(() => {
    if (!fromUrl) return;
    setProductId(fromUrl.productId);
    setType(fromUrl.optionType === 0 ? 0 : 1);
  }, [fromUrl]);

  const product = products.find((p) => p.productId === productId) ?? products[0];
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    const digits = q.replace(/[^0-9.]/g, "");
    return active
      .filter((s) => {
        if (s.productId !== product?.productId || s.optionType !== type) return false;
        if (status === "expiring" && (now === undefined || s.expiry - now > WRITE_EXPIRING_WINDOW)) return false;
        if (status === "later" && now !== undefined && s.expiry - now <= WRITE_EXPIRING_WINDOW) return false;
        if (!q) return true;
        if (`${s.underlyingSymbol} ${s.assetSymbol} ${s.optionType === 0 ? "call" : "put"} ${fmtExpiryShort(s.expiry)}`.toLowerCase().includes(q)) return true;
        if (digits && fmtLevel(s.strikeWad).replace(/,/g, "").includes(digits)) return true;
        return false;
      })
      .sort((a, b) => {
        switch (sort) {
          case "strikeAsc": return a.strikeWad < b.strikeWad ? -1 : 1;
          case "strikeDesc": return a.strikeWad > b.strikeWad ? -1 : 1;
          default: return a.expiry < b.expiry ? -1 : 1;
        }
      });
  }, [active, product, type, status, query, sort, now]);
  const selected = filtered.find((s) => s.id === fromUrl?.id) ?? undefined;
  const choose = (s: Series) => navigate(`/app/write/${s.id}`, { replace: true });

  if (isLoading || now === undefined) return <Skeleton className="h-96 w-full rounded-3xl" />;
  if (!product) return <Card><EmptyState title="Nothing to write right now" body="Options appear here once they are listed and before they expire." /></Card>;

  return (
    <div className="space-y-4">
      <section className="overflow-hidden rounded-3xl border border-line bg-surface shadow-ticket">
        <div className="grid gap-5 p-4 sm:p-5 lg:grid-cols-[minmax(0,1fr)_360px] lg:items-center">
          <div>
            <div className="mb-3 inline-flex items-center gap-2 rounded-full border border-accent/30 bg-accent/10 px-3 py-1 text-xs font-bold text-accent">
              <Coins className="h-3.5 w-3.5" /> Earn premium
            </div>
            <h1 className="font-display text-3xl font-bold leading-tight tracking-tight sm:text-4xl">Write options with a guided margin check.</h1>
            <p className="mt-3 max-w-2xl text-sm leading-6 text-muted">
              Pick the option you are willing to back, choose a size, and Optara previews the premium, fee and margin result before you sign.
              <button onClick={openGuide} className="ml-1 font-semibold text-primary cursor-pointer">Learn the risk</button>
            </p>
          </div>
          <div className="grid gap-2">
            <EarnStep icon={Coins} title="Collect premium" text="If there is a bid, sell instantly to the book." />
            <EarnStep icon={ShieldCheck} title="Stay margined" text="Your account must pass the opening check." />
            <EarnStep icon={CheckCircle2} title="Settle later" text="You owe only if the option finishes in the money." />
          </div>
        </div>
      </section>

      <section className="grid gap-4 lg:grid-cols-[320px_minmax(0,1fr)] lg:items-start">
        <aside className="space-y-3 lg:sticky lg:top-[84px]">
          <section className="card space-y-3 p-4">
            <div>
              <h2 className="label">1 · Choose what to write</h2>
              <p className="mt-1 text-xs leading-5 text-muted">Filter the writeable markets, then pick the position you want to back.</p>
            </div>

            {products.length > 1 && (
          <div className="grid grid-cols-2 gap-1.5 lg:grid-cols-1">
            {products.map((p) => (
              <button
                key={p.productId}
                onClick={() => (setProductId(p.productId), navigate("/app/write", { replace: true }))}
                className={cx("flex min-h-[40px] items-center gap-1.5 rounded-xl border px-3 text-[13px] font-semibold cursor-pointer", p.productId === product.productId ? "border-primary/50 bg-primary-soft text-primary" : "border-line bg-surface text-muted")}
              >
                <TokenIcon symbol={p.underlyingSymbol} className="h-4 w-4" />
                {p.underlyingSymbol}/{p.assetSymbol}
              </button>
            ))}
          </div>
            )}

            <div className="grid grid-cols-2 gap-2 lg:grid-cols-1">
          <TypeButton
            active={type === 0}
            onClick={() => (setType(0), navigate("/app/write", { replace: true }))}
            icon={<TrendingUp className="h-4 w-4" />}
            title="Write calls"
            sub={`You owe if ${product.underlyingSymbol} rises above the strike`}
            tone="good"
          />
          <TypeButton
            active={type === 1}
            onClick={() => (setType(1), navigate("/app/write", { replace: true }))}
            icon={<TrendingDown className="h-4 w-4" />}
            title="Write puts"
            sub={`You owe if ${product.underlyingSymbol} falls below the strike`}
            tone="bad"
          />
            </div>

            <div className="relative">
              <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-faint" />
              <input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Search strike or expiry..."
                className="input !pl-9 text-[13px]"
              />
            </div>

            <div className="grid grid-cols-3 gap-1.5">
          {([
            ["all", "All"],
            ["expiring", "Soon"],
            ["later", "Later"],
          ] as [WriteStatus, string][]).map(([v, label]) => (
            <button
              key={v}
              onClick={() => setStatus(v)}
              className={cx("min-h-[38px] rounded-xl border px-2 text-[12px] font-semibold cursor-pointer", status === v ? "border-primary/60 bg-primary-soft text-primary" : "border-line bg-surface-2 text-muted")}
            >
              {label}
            </button>
          ))}
            </div>

            <select value={sort} onChange={(e) => setSort(e.target.value as WriteSort)} className="input min-h-[42px] cursor-pointer !py-2 text-[13px] font-semibold">
              <option value="expirySoon">Expiring soonest</option>
              <option value="strikeAsc">Strike low to high</option>
              <option value="strikeDesc">Strike high to low</option>
            </select>
          </section>
        </aside>

        <section className="space-y-4">
          <div className="card p-3">
            <div className="mb-2 flex items-center justify-between gap-2 px-1">
              <h2 className="label">Available strikes</h2>
              <Pill tone="primary">{filtered.length} listed</Pill>
            </div>
            <ul className="grid gap-2 sm:grid-cols-2">
          {filtered.map((s) => (
            <StrikeCard key={s.id} s={s} now={now} selected={s.id === selected?.id} onClick={() => choose(s)} />
          ))}
            </ul>
            {filtered.length === 0 && <p className="px-1 py-4 text-[13px] text-muted">No {type === 0 ? "calls" : "puts"} match these filters.</p>}
          </div>

          {selected ? (
            <WriteTicket s={selected} />
          ) : (
            <Card><EmptyState title="Pick a strike to continue" body="The order ticket and payoff preview appear here once you choose a strike." /></Card>
          )}
        </section>
      </section>
    </div>
  );
}

function EarnStep({ icon: Icon, title, text }: { icon: typeof Coins; title: string; text: string }) {
  return (
    <div className="flex items-start gap-3 rounded-2xl border border-line bg-surface-2/70 p-3">
      <span className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-accent/10 text-accent">
        <Icon className="h-4 w-4" />
      </span>
      <span>
        <span className="block text-sm font-bold">{title}</span>
        <span className="block text-xs leading-5 text-muted">{text}</span>
      </span>
    </div>
  );
}

function TypeButton({ active, onClick, icon, title, sub, tone }: { active: boolean; onClick(): void; icon: React.ReactNode; title: string; sub: string; tone: "good" | "bad" }) {
  return (
    <button
      onClick={onClick}
      aria-pressed={active}
      className={cx("rounded-2xl border p-3 text-left cursor-pointer", active ? (tone === "good" ? "border-good/60 bg-good/8" : "border-bad/60 bg-bad/8") : "border-line bg-surface")}
    >
      <span className={cx("flex items-center gap-1.5 text-sm font-bold", active && (tone === "good" ? "text-good" : "text-bad"))}>
        {icon}
        {title}
      </span>
      <span className="mt-0.5 block text-xs text-muted">{sub}</span>
    </button>
  );
}

/** One strike: the premium a writer collects now (best bid) and how far the price must move before they owe. */
function StrikeCard({ s, now, selected, onClick }: { s: Series; now: bigint; selected: boolean; onClick(): void }) {
  const { data: m } = useSeriesMarket(s);
  const { data: pm } = useProductMarket(s.productId);
  const leg = legOf(s);
  const spot = pm ? Number(pm.spotWad) / 1e18 : undefined;
  const move = spot !== undefined ? moveNeeded(leg, spot, leg.strike) : undefined;
  const bid = m?.quote?.bid;
  return (
    <li>
      <button
        onClick={onClick}
        className={cx("w-full rounded-2xl border p-3 text-left transition cursor-pointer", selected ? "border-primary bg-primary-soft ring-1 ring-primary/40" : "border-line bg-surface-2/60 hover:border-primary/40")}
      >
        <span className="flex items-baseline justify-between gap-2">
          <span className="num font-display text-[17px] font-bold">${fmtLevel(s.strikeWad)}</span>
          <span className="num text-right text-[13px] font-semibold text-good">{bid !== undefined ? `+${fmtPrice(bid)} ${s.assetSymbol}` : "no buyers yet"}</span>
        </span>
        <span className="mt-0.5 flex items-baseline justify-between gap-2 text-xs text-muted">
          <span>{move === undefined ? "" : move <= 0 ? "In the money: you'd owe today" : `You owe only if ${s.underlyingSymbol} ${moveText(leg, move, 1, true)}`}</span>
          <span>{fmtExpiryShort(s.expiry)} · {fmtDuration(s.expiry - now)}</span>
        </span>
      </button>
    </li>
  );
}

/** Steps 2 and 3 for one option: the account, then the order (the option page's Earn panel) and the writer's payoff. */
function WriteTicket({ s }: { s: Series }) {
  const { address } = useConnection();
  const { selected } = useAccountState();
  const { data: account } = useAccountView(selected);
  const { data: market } = useSeriesMarket(s);
  const { data: product } = useProductMarket(s.productId);
  const { data: wallet } = useWalletWrappers(address);
  const [preview, setPreview] = useState<{ qty: number; cost?: number }>({ qty: 1 });
  const onQty = useCallback((qty: number, cost?: number) => setPreview({ qty, cost }), []);

  const ctx: ActionContext = {
    connected: !!address,
    groupState: market?.state ?? "ACTIVE",
    productCloseOnly: product?.closeOnly ?? false,
    dataFresh: !!product?.spotFresh && product?.surface === "FRESH",
    marketTradable: !!market?.quote,
    hasAccount: selected !== undefined,
    health: account?.health.state,
    accountBalance: account?.positions.find((p) => p.seriesId === s.id)?.balance ?? 0n,
    walletWrappers: wallet?.find((w) => w.series.id === s.id)?.balance ?? 0n,
    credit: false,
  };
  const spot = product ? Number(product.spotWad) / 1e18 : undefined;
  const premium = preview.cost ?? (market?.quote?.bid !== undefined ? Number(market.quote.bid) / 1e18 : market?.mark !== undefined ? Number(market.mark) / 1e18 : undefined);

  return (
    <>
      <section className="card space-y-3 p-4 sm:p-5">
        <div className="flex items-center gap-2">
          <Wallet className="h-4 w-4 text-primary" />
          <h2 className="label">2 · Margin account</h2>
        </div>
        {!address ? (
          <p className="text-[13px] text-muted">Connect a wallet to see or open your margin account.</p>
        ) : selected === undefined || !account ? (
          <p className="text-[13px] text-muted">
            You don't have a margin account yet. Step 3 creates one and deposits your first {s.assetSymbol} in a single flow.
          </p>
        ) : (
          <div className="space-y-2.5">
            <div className="flex flex-wrap items-center justify-between gap-2 text-[13px]">
              <span>
                Account #{selected.toString()} · <b className="num">{fmtNative(account.cash, s.assetDecimals)} {s.assetSymbol}</b> cash
              </span>
              <Link to="/app/portfolio" className="font-semibold text-primary">
                Add or withdraw cash <ArrowRight className="inline h-3 w-3" />
              </Link>
            </div>
            <HealthBar health={account.health} hasPositions={account.positions.length > 0} assetSymbol={s.assetSymbol} compact />
          </div>
        )}
      </section>

      <section className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_400px] xl:items-start">
        <Card title="What happens at expiry if you write">
          {premium !== undefined ? (
            <PayoffChart
              optionType={s.optionType}
              strike={legOf(s).strike}
              size={legOf(s).size}
              spot={spot}
              premium={premium}
              qty={preview.qty}
              side="short"
              assetSymbol={s.assetSymbol}
              underlyingSymbol={s.underlyingSymbol}
            />
          ) : (
            <Skeleton className="h-60 w-full" />
          )}
        </Card>

        <section className="ticket space-y-3 p-4 sm:p-5">
          <div className="flex items-center justify-between">
            <h2 className="label">3 · Write and collect</h2>
            <Link to={`/app/series/${s.id}`} className="text-xs font-semibold text-primary">Option details</Link>
          </div>
          <WritePanel
            s={s}
            ctx={ctx}
            bid={market?.quote?.bid}
            mark={market?.mark}
            writeCapacity={market?.writeCapacity}
            openInterest={market?.openInterest}
            openInterestCap={market?.openInterestCap}
            market={market?.quote?.market}
            venueId={market?.quote?.venueId}
            venueName={market?.quote?.venueName}
            onQty={onQty}
          />
        </section>
      </section>
    </>
  );
}
