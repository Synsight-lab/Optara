/**
 * `/write` and `/write/:id`: earn premium by writing options (OptionClearing.mintExternalLong, USER_FLOWS.md F2).
 * Three steps: choose what to write → your margin account → amount, premium and risk. The order form itself is the
 * option page's Earn panel (WritePanel), so both places behave identically.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { useConnection } from "wagmi";
import type { Hex } from "viem";
import { ArrowRight, Coins, TrendingDown, TrendingUp } from "lucide-react";
import { Card, EmptyState, Skeleton, cx } from "../components/ui.tsx";
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
  const [expiry, setExpiry] = useState<bigint | undefined>();

  // Opening /write/:id preselects that option.
  useEffect(() => {
    if (!fromUrl) return;
    setProductId(fromUrl.productId);
    setType(fromUrl.optionType === 0 ? 0 : 1);
    setExpiry(fromUrl.expiry);
  }, [fromUrl]);

  const product = products.find((p) => p.productId === productId) ?? products[0];
  const expiries = useMemo(
    () => [...new Set(active.filter((s) => s.productId === product?.productId).map((s) => s.expiry))].sort((a, b) => (a < b ? -1 : 1)),
    [active, product],
  );
  const chosenExpiry = expiry !== undefined && expiries.includes(expiry) ? expiry : expiries[0];
  const strikes = active
    .filter((s) => s.productId === product?.productId && s.expiry === chosenExpiry && s.optionType === type)
    .sort((a, b) => (a.strikeWad < b.strikeWad ? -1 : 1));
  const selected = strikes.find((s) => s.id === fromUrl?.id) ?? undefined;
  const choose = (s: Series) => navigate(`/write/${s.id}`, { replace: true });

  if (isLoading || now === undefined) return <Skeleton className="h-96 w-full rounded-3xl" />;
  if (!product) return <Card><EmptyState title="Nothing to write right now" body="Options appear here once they are listed and before they expire." /></Card>;

  return (
    <div className="space-y-4">
      <section className="card p-4 sm:p-5">
        <div className="flex items-start gap-3">
          <span className="grid h-10 w-10 shrink-0 place-items-center rounded-2xl bg-accent/15 text-accent">
            <Coins className="h-5 w-5" />
          </span>
          <div>
            <h1 className="font-display text-2xl font-bold tracking-tight">Earn by writing options</h1>
            <p className="mt-1 text-[13px] leading-relaxed text-muted">
              You create options and sell them to buyers, and <b className="text-ink">collect the premium now</b>. In return, if an
              option ends in the money, you pay the holder the difference from your margin account at expiry. You keep the whole
              premium if it doesn't.{" "}
              <button onClick={openGuide} className="font-semibold text-primary cursor-pointer">How options work</button>
            </p>
          </div>
        </div>
      </section>

      {/* Step 1 */}
      <section className="card space-y-3 p-4 sm:p-5">
        <h2 className="label">1 · What to write</h2>

        {products.length > 1 && (
          <div className="flex flex-wrap gap-1.5">
            {products.map((p) => (
              <button
                key={p.productId}
                onClick={() => (setProductId(p.productId), setExpiry(undefined), navigate("/write", { replace: true }))}
                className={cx("flex min-h-[40px] items-center gap-1.5 rounded-xl border px-3 text-[13px] font-semibold cursor-pointer", p.productId === product.productId ? "border-primary/50 bg-primary-soft text-primary" : "border-line bg-surface text-muted")}
              >
                <TokenIcon symbol={p.underlyingSymbol} className="h-4 w-4" />
                {p.underlyingSymbol}/{p.assetSymbol}
              </button>
            ))}
          </div>
        )}

        <div className="grid grid-cols-2 gap-2">
          <TypeButton
            active={type === 0}
            onClick={() => (setType(0), navigate("/write", { replace: true }))}
            icon={<TrendingUp className="h-4 w-4" />}
            title="Write calls"
            sub={`You owe if ${product.underlyingSymbol} rises above the strike`}
            tone="good"
          />
          <TypeButton
            active={type === 1}
            onClick={() => (setType(1), navigate("/write", { replace: true }))}
            icon={<TrendingDown className="h-4 w-4" />}
            title="Write puts"
            sub={`You owe if ${product.underlyingSymbol} falls below the strike`}
            tone="bad"
          />
        </div>

        <div className="flex gap-1.5 overflow-x-auto pb-1 scrollbar-none">
          {expiries.map((e) => (
            <button
              key={e.toString()}
              onClick={() => (setExpiry(e), navigate("/write", { replace: true }))}
              className={cx("whitespace-nowrap rounded-xl border px-2.5 py-1.5 text-[13px] font-semibold cursor-pointer", e === chosenExpiry ? "border-primary/60 bg-primary-soft text-primary" : "border-line bg-surface-2 text-muted")}
            >
              {fmtExpiryShort(e)} · {fmtDuration(e - now)}
            </button>
          ))}
        </div>

        <ul className="grid gap-2 sm:grid-cols-2">
          {strikes.map((s) => (
            <StrikeCard key={s.id} s={s} selected={s.id === selected?.id} onClick={() => choose(s)} />
          ))}
        </ul>
        {strikes.length === 0 && <p className="text-[13px] text-muted">No {type === 0 ? "calls" : "puts"} listed for this expiry.</p>}
      </section>

      {selected ? (
        <WriteTicket s={selected} />
      ) : (
        <p className="px-1 text-[13px] text-muted">Pick a strike above to continue.</p>
      )}
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
function StrikeCard({ s, selected, onClick }: { s: Series; selected: boolean; onClick(): void }) {
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
          <span>premium per option</span>
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
        <h2 className="label">2 · Your margin account</h2>
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
              <Link to="/portfolio" className="font-semibold text-primary">
                Add or withdraw cash <ArrowRight className="inline h-3 w-3" />
              </Link>
            </div>
            <HealthBar health={account.health} hasPositions={account.positions.length > 0} assetSymbol={s.assetSymbol} compact />
          </div>
        )}
      </section>

      <section className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_400px] lg:items-start">
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
            <Link to={`/series/${s.id}`} className="text-xs font-semibold text-primary">Option details</Link>
          </div>
          <WritePanel s={s} ctx={ctx} bid={market?.quote?.bid} mark={market?.mark} market={market?.quote?.market} onQty={onQty} />
        </section>
      </section>
    </>
  );
}
