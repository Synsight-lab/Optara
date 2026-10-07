/** `/`: products, expiries, Simple Mode cards and Pro Mode option chain (FRONTEND.md §2 "Markets"). */
import { Fragment, useMemo, useState } from "react";
import { Link, useNavigate } from "react-router";
import type { Hex } from "viem";
import {
  ArrowDownRight,
  ArrowRight,
  ArrowUpRight,
  BookOpen,
  Calendar,
  CheckCircle,
  Coins,
  Compass,
  Filter,
  HelpCircle,
  Info,
  Layers,
  Percent,
  Shield,
  ShieldCheck,
  Sparkles,
  TrendingDown,
  TrendingUp,
  Zap,
} from "lucide-react";
import { Card, EmptyState, Pill, Segmented, Skeleton, Term, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { fmtDuration, fmtExpiry, fmtExpiryShort, fmtIv, fmtPrice, fmtWad, WAD } from "../lib/optara/format.ts";
import { useChainTime, useProductMarket, useSeriesList, useSeriesMarket } from "../lib/optara/hooks.ts";
import type { Series } from "../lib/optara/types.ts";
import { useQuickGuide, useTradingMode } from "../state.tsx";

type ChainMode = "buy" | "write";
type SimpleIntent = "call" | "put" | "yield";

export function MarketsPage() {
  const { data: series, isLoading, error } = useSeriesList();
  const { data: now } = useChainTime();
  const { mode: tradingMode, setMode: setTradingMode } = useTradingMode();
  const { open: openGuide } = useQuickGuide();

  const products = useMemo(() => [...new Map((series ?? []).map((s) => [s.productId, s])).values()], [series]);
  const [productId, setProductId] = useState<Hex | undefined>();
  const product = products.find((p) => p.productId === productId) ?? products[0];

  const live = (series ?? []).filter(
    (s) => s.productId === product?.productId && (now === undefined || s.expiry > now)
  );
  const expiries = [...new Set(live.map((s) => s.expiry))].sort((a, b) => (a < b ? -1 : 1));
  const [expiry, setExpiry] = useState<bigint | undefined>();
  const chosenExpiry = expiry !== undefined && expiries.includes(expiry) ? expiry : expiries[0];

  // For Pro View: Buy vs Write
  const [chainMode, setChainMode] = useState<ChainMode>("buy");

  // For Simple View: Bullish (Call), Bearish (Put), Yield (Write)
  const [simpleIntent, setSimpleIntent] = useState<SimpleIntent>("call");

  if (error) {
    return (
      <Card>
        <EmptyState icon="⚠️" title="Network Connection Issue" body={(error as Error).message} />
      </Card>
    );
  }
  if (isLoading) {
    return (
      <div className="space-y-6">
        <Skeleton className="h-48 w-full rounded-3xl" />
        <Skeleton className="h-80 w-full rounded-3xl" />
      </div>
    );
  }
  if (!product) {
    return (
      <Card>
        <EmptyState
          title="No markets listed yet"
          body="Options series will appear here once registered on-chain."
        />
      </Card>
    );
  }

  const filteredLive = live.filter((s) => s.expiry === chosenExpiry);

  return (
    <div className="space-y-6 sm:space-y-8">
      {/* Hero Banner with Live Asset Overview */}
      <HeroBanner product={product} onOpenGuide={openGuide} />

      {/* Asset Switcher (if multiple assets are listed) */}
      {products.length > 1 && (
        <div className="flex items-center gap-2 overflow-x-auto pb-1">
          <span className="text-xs font-semibold text-muted uppercase tracking-wider">Asset:</span>
          {products.map((p) => (
            <button
              key={p.productId}
              onClick={() => {
                setProductId(p.productId);
                setExpiry(undefined);
              }}
              className={cx(
                "flex items-center gap-2 rounded-2xl border px-4 py-2 text-sm font-semibold transition",
                p.productId === product.productId
                  ? "border-primary bg-primary-soft text-primary shadow-sm"
                  : "border-line bg-surface-2 text-muted hover:text-ink hover:border-primary/40"
              )}
            >
              <TokenIcon symbol={p.underlyingSymbol} className="h-4 w-4" />
              <span>
                {p.underlyingSymbol}/{p.assetSymbol}
              </span>
            </button>
          ))}
        </div>
      )}

      {/* Expiry Selector Bar */}
      <div className="rounded-3xl border border-line bg-surface/80 p-4 sm:p-5 backdrop-blur-xl">
        <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
          <div className="flex items-center gap-2">
            <Calendar className="h-4 w-4 text-primary" />
            <h2 className="text-sm font-bold tracking-tight">Select Expiry Date</h2>
            <span className="text-xs text-muted">All options cash-settle at 08:00 UTC</span>
          </div>

          {/* Mode Switcher pill */}
          <div className="flex items-center gap-1.5 rounded-xl border border-line bg-surface-2 p-1 text-xs">
            <button
              onClick={() => setTradingMode("simple")}
              className={cx(
                "flex items-center gap-1 rounded-lg px-2.5 py-1 font-semibold transition",
                tradingMode === "simple" ? "bg-primary text-white shadow-sm" : "text-muted hover:text-ink"
              )}
            >
              <Sparkles className="h-3 w-3" /> Simple
            </button>
            <button
              onClick={() => setTradingMode("pro")}
              className={cx(
                "flex items-center gap-1 rounded-lg px-2.5 py-1 font-semibold transition",
                tradingMode === "pro" ? "bg-primary text-white shadow-sm" : "text-muted hover:text-ink"
              )}
            >
              <Layers className="h-3 w-3" /> Pro Chain
            </button>
          </div>
        </div>

        {expiries.length === 0 ? (
          <EmptyState
            title="No active expiries"
            body="All listed expiries have reached expiration. Visit Settlement for payouts."
            action={
              <Link to="/settlement" className="btn-ghost mt-2">
                Go to Settlement
              </Link>
            }
          />
        ) : (
          <div className="flex gap-2.5 overflow-x-auto pb-1 scrollbar-none">
            {expiries.map((e) => {
              const isSelected = e === chosenExpiry;
              const durationLeft = now !== undefined ? e - now : undefined;
              return (
                <button
                  key={e.toString()}
                  onClick={() => setExpiry(e)}
                  className={cx(
                    "flex flex-col items-start min-w-[130px] rounded-2xl border p-3 text-left transition-all active:scale-[0.98]",
                    isSelected
                      ? "border-primary bg-primary-soft text-primary shadow-md ring-1 ring-primary/40"
                      : "border-line bg-surface-2 hover:border-primary/40 hover:bg-surface-2/80 text-ink"
                  )}
                >
                  <span className="text-sm font-bold">{fmtExpiryShort(e)}</span>
                  <span className="text-[11px] text-muted font-medium">
                    {durationLeft !== undefined ? `in ${fmtDuration(durationLeft)}` : "Expiring soon"}
                  </span>
                </button>
              );
            })}
          </div>
        )}
      </div>

      {/* Main Options Content: Simple Mode vs Pro Mode */}
      {tradingMode === "simple" ? (
        <SimpleOptionsView
          product={product}
          series={filteredLive}
          intent={simpleIntent}
          onIntentChange={setSimpleIntent}
          onLearnClick={openGuide}
        />
      ) : (
        <ProOptionsChain
          product={product}
          series={filteredLive}
          mode={chainMode}
          onModeChange={setChainMode}
        />
      )}
    </div>
  );
}

// ------------------------------------------------------------------ Hero Banner
function HeroBanner({ product, onOpenGuide }: { product: Series; onOpenGuide: () => void }) {
  const { data: m } = useProductMarket(product.productId);

  return (
    <section className="relative overflow-hidden rounded-3xl border border-line bg-surface/90 p-5 sm:p-8 backdrop-blur-2xl shadow-xl">
      {/* Decorative neon ambient glows */}
      <div className="pointer-events-none absolute -right-20 -top-20 h-64 w-64 rounded-full bg-primary/20 blur-3xl" />
      <div className="pointer-events-none absolute -bottom-20 right-40 h-64 w-64 rounded-full bg-accent/15 blur-3xl" />

      <div className="relative flex flex-col md:flex-row md:items-end md:justify-between gap-6">
        <div className="max-w-2xl">
          <div className="flex flex-wrap items-center gap-2">
            <span className="pill bg-surface-2 text-ink font-semibold flex items-center gap-1.5">
              <TokenIcon symbol={product.underlyingSymbol} className="h-3.5 w-3.5" />
              {product.underlyingSymbol} · Settled in {product.assetSymbol}
            </span>
            {m && (
              <Pill tone={m.spotFresh ? "good" : "warn"} dot>
                {m.spotFresh ? "Pyth Live Oracle" : "Price Delayed"}
              </Pill>
            )}
            {m?.closeOnly && <Pill tone="warn">Closing Only</Pill>}
          </div>

          <h1 className="mt-3 text-2xl sm:text-4xl font-extrabold tracking-tight">
            Trade {product.underlyingSymbol} Options
          </h1>
          <p className="mt-2 text-sm text-muted leading-relaxed max-w-xl">
            Simpler, capital-efficient European options on Monad. Pay small upfront premiums for unlimited upside, or write options to collect yield.
          </p>

          <div className="mt-4 flex flex-wrap items-center gap-3">
            <Link
              to="/trade"
              className="flex items-center gap-1.5 rounded-xl bg-primary px-4 py-2 text-xs font-bold text-white shadow-lg hover:brightness-110 active:scale-95 transition"
            >
              <Zap className="h-4 w-4" /> Quick 1-Click Trade
            </Link>
            <button
              onClick={onOpenGuide}
              className="flex items-center gap-1.5 rounded-xl border border-line bg-surface-2 px-3.5 py-2 text-xs font-semibold text-ink hover:border-primary/40 transition"
            >
              <BookOpen className="h-3.5 w-3.5 text-primary" /> How Options Work
            </button>
            <span className="text-xs text-muted">
              🔒 <b>100% Capped Risk</b> for buyers · No liquidation on longs
            </span>
          </div>
        </div>

        {/* Spot Price Card */}
        <div className="flex flex-col items-start md:items-end justify-center rounded-2xl border border-line/60 bg-surface-2/60 p-4 min-w-[200px]">
          <span className="text-[11px] font-semibold text-muted uppercase tracking-wider">
            {product.underlyingSymbol} Current Spot
          </span>
          <div className="num mt-1 text-3xl sm:text-4xl font-black text-ink">
            {m ? `$${fmtWad(m.spotWad, 2)}` : <Skeleton className="h-9 w-32" />}
          </div>
          <div className="mt-2 flex items-center gap-1.5 text-xs text-muted">
            <span className={cx("h-2 w-2 rounded-full", m?.spotFresh ? "live-dot bg-good" : "bg-warn")} />
            <span>Updated in real time</span>
          </div>
        </div>
      </div>
    </section>
  );
}

// ------------------------------------------------------------------ Simple View (NectarFi-like Simplicity)
function SimpleOptionsView({
  product,
  series,
  intent,
  onIntentChange,
  onLearnClick,
}: {
  product: Series;
  series: Series[];
  intent: SimpleIntent;
  onIntentChange: (i: SimpleIntent) => void;
  onLearnClick: () => void;
}) {
  const { data: m } = useProductMarket(product.productId);
  const spot = m?.spotWad;

  // Filter series based on user intent:
  // - "call" -> optionType 0
  // - "put"  -> optionType 1
  // - "yield" -> writers can do either (show all sorted by strike)
  const optionTypeFilter = intent === "call" ? 0 : intent === "put" ? 1 : undefined;
  const filtered = series
    .filter((s) => optionTypeFilter === undefined || s.optionType === optionTypeFilter)
    .sort((a, b) => (a.strikeWad < b.strikeWad ? -1 : 1));

  return (
    <div className="space-y-6">
      {/* 3-Way Intent Selector: Bullish vs Bearish vs Yield */}
      <div className="grid gap-3 sm:grid-cols-3">
        <button
          onClick={() => onIntentChange("call")}
          className={cx(
            "flex items-center gap-3.5 rounded-2xl border p-4 text-left transition-all active:scale-[0.98]",
            intent === "call"
              ? "border-good bg-good/10 shadow-lg ring-1 ring-good/40"
              : "border-line bg-surface-2 hover:border-good/40 hover:bg-surface-2/80"
          )}
        >
          <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-good/20 text-good">
            <TrendingUp className="h-6 w-6" />
          </div>
          <div>
            <div className="flex items-center gap-1.5 font-bold text-ink text-sm sm:text-base">
              Price Goes Up
              <span className="text-[10px] font-bold px-1.5 py-0.5 rounded-md bg-good/20 text-good">CALL</span>
            </div>
            <div className="text-xs text-muted mt-0.5">Profit when {product.underlyingSymbol} climbs</div>
          </div>
        </button>

        <button
          onClick={() => onIntentChange("put")}
          className={cx(
            "flex items-center gap-3.5 rounded-2xl border p-4 text-left transition-all active:scale-[0.98]",
            intent === "put"
              ? "border-bad bg-bad/10 shadow-lg ring-1 ring-bad/40"
              : "border-line bg-surface-2 hover:border-bad/40 hover:bg-surface-2/80"
          )}
        >
          <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-bad/20 text-bad">
            <TrendingDown className="h-6 w-6" />
          </div>
          <div>
            <div className="flex items-center gap-1.5 font-bold text-ink text-sm sm:text-base">
              Price Goes Down
              <span className="text-[10px] font-bold px-1.5 py-0.5 rounded-md bg-bad/20 text-bad">PUT</span>
            </div>
            <div className="text-xs text-muted mt-0.5">Profit or hedge when price drops</div>
          </div>
        </button>

        <button
          onClick={() => onIntentChange("yield")}
          className={cx(
            "flex items-center gap-3.5 rounded-2xl border p-4 text-left transition-all active:scale-[0.98]",
            intent === "yield"
              ? "border-accent bg-accent/10 shadow-lg ring-1 ring-accent/40"
              : "border-line bg-surface-2 hover:border-accent/40 hover:bg-surface-2/80"
          )}
        >
          <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-accent/20 text-accent">
            <Coins className="h-6 w-6" />
          </div>
          <div>
            <div className="flex items-center gap-1.5 font-bold text-ink text-sm sm:text-base">
              Earn Yield
              <span className="text-[10px] font-bold px-1.5 py-0.5 rounded-md bg-accent/20 text-accent">WRITE</span>
            </div>
            <div className="text-xs text-muted mt-0.5">Deposit collateral & earn upfront premiums</div>
          </div>
        </button>
      </div>

      {/* Guidance Notice */}
      <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-line bg-surface/50 px-4 py-3 text-xs text-muted">
        <div className="flex items-center gap-2">
          <Info className="h-4 w-4 text-primary shrink-0" />
          <span>
            {intent === "call" && "Select a target price above current spot. The higher the price goes, the more you win."}
            {intent === "put" && "Select a target price below current spot. You profit if price drops below that strike."}
            {intent === "yield" && "Select an option to write. You collect the premium immediately into your wallet."}
          </span>
        </div>
        <button onClick={onLearnClick} className="font-semibold text-primary hover:underline flex items-center gap-1">
          How it works <ArrowRight className="h-3 w-3" />
        </button>
      </div>

      {/* Cards Grid */}
      {filtered.length === 0 ? (
        <Card>
          <EmptyState title="No options available for this selection" body="Try picking a different expiry date above." />
        </Card>
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {filtered.map((s) => (
            <SimpleOptionCard key={s.id} series={s} spotWad={spot} intent={intent} />
          ))}
        </div>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ Simple Option Card
function SimpleOptionCard({ series, spotWad, intent }: { series: Series; spotWad?: bigint; intent: SimpleIntent }) {
  const navigate = useNavigate();
  const { data: m, isLoading } = useSeriesMarket(series);

  const strikeNum = Number(series.strikeWad) / 1e18;
  const spotNum = spotWad !== undefined ? Number(spotWad) / 1e18 : undefined;
  const diffPct = spotNum ? (((strikeNum - spotNum) / spotNum) * 100).toFixed(1) : undefined;

  const quote = intent === "yield" ? m?.quote?.bid : m?.quote?.ask;
  const price = quote ?? m?.mark;
  const priceNum = price !== undefined ? Number(price) / 1e18 : undefined;

  const isCall = series.optionType === 0;
  const isItm = spotWad !== undefined && (isCall ? spotWad > series.strikeWad : spotWad < series.strikeWad);

  // Breakeven price
  const breakeven = priceNum !== undefined ? (isCall ? strikeNum + priceNum : strikeNum - priceNum) : undefined;

  return (
    <div
      onClick={() => navigate(`/series/${series.id}?tab=${intent === "yield" ? "write" : "buy"}`)}
      className={cx(
        "group relative flex flex-col justify-between overflow-hidden rounded-3xl border p-5 transition-all cursor-pointer hover:shadow-xl active:scale-[0.99]",
        isItm
          ? "border-primary/40 bg-surface/90 hover:border-primary"
          : "border-line bg-surface/75 hover:border-primary/40 hover:bg-surface-2/70"
      )}
    >
      {/* Top Header: Strike & Badge */}
      <div>
        <div className="flex items-center justify-between gap-2">
          <div className="flex items-center gap-2">
            <span
              className={cx(
                "rounded-xl px-2.5 py-1 text-xs font-bold",
                isCall ? "bg-good/15 text-good" : "bg-bad/15 text-bad"
              )}
            >
              {isCall ? "CALL (UP)" : "PUT (DOWN)"}
            </span>
            {isItm && (
              <span className="pill bg-primary/20 text-primary font-bold text-[10px]">
                In The Money
              </span>
            )}
          </div>
          <span className="text-xs text-muted font-medium">{series.underlyingSymbol}</span>
        </div>

        {/* Target Price */}
        <div className="mt-3.5">
          <div className="text-xs text-muted font-medium">Target Strike Price</div>
          <div className="flex items-baseline gap-2 mt-0.5">
            <span className="num text-2xl font-black text-ink">${fmtWad(series.strikeWad, 0)}</span>
            {diffPct !== undefined && (
              <span
                className={cx(
                  "num text-xs font-semibold",
                  Number(diffPct) > 0 ? "text-good" : "text-bad"
                )}
              >
                {Number(diffPct) > 0 ? `+${diffPct}%` : `${diffPct}%`}
              </span>
            )}
          </div>
        </div>

        {/* Price & Breakeven Metrics */}
        <div className="mt-4 rounded-2xl bg-surface-2/70 p-3 text-xs space-y-2">
          <div className="flex justify-between items-center">
            <span className="text-muted">{intent === "yield" ? "You Earn Upfront:" : "Cost per Option:"}</span>
            <span className="num font-bold text-ink">
              {isLoading ? (
                <Skeleton className="h-4 w-12" />
              ) : price !== undefined ? (
                `${fmtPrice(price)} ${series.assetSymbol}`
              ) : (
                "No quotes"
              )}
            </span>
          </div>
          {breakeven !== undefined && intent !== "yield" && (
            <div className="flex justify-between items-center border-t border-line/60 pt-1.5">
              <span className="text-muted">Breakeven at:</span>
              <span className="num font-semibold text-warn">${breakeven.toLocaleString(undefined, { maximumFractionDigits: 0 })}</span>
            </div>
          )}
        </div>
      </div>

      {/* Action Button */}
      <div className="mt-5">
        <button
          className={cx(
            "w-full rounded-2xl py-2.5 text-xs font-bold flex items-center justify-center gap-1.5 transition group-hover:brightness-110",
            intent === "yield"
              ? "bg-accent text-white"
              : isCall
              ? "bg-good text-white"
              : "bg-bad text-white"
          )}
        >
          {intent === "yield" ? "Write & Collect Yield" : "Trade This Option"}
          <ArrowRight className="h-3.5 w-3.5 transition-transform group-hover:translate-x-0.5" />
        </button>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ Pro Options Chain View
function ProOptionsChain({
  product,
  series,
  mode,
  onModeChange,
}: {
  product: Series;
  series: Series[];
  mode: ChainMode;
  onModeChange: (m: ChainMode) => void;
}) {
  const { data: m } = useProductMarket(product.productId);
  const strikes = [...new Set(series.map((s) => s.strikeWad))].sort((a, b) => (a < b ? -1 : 1));
  const spot = m?.spotWad;
  const spotIndex = spot === undefined ? -1 : strikes.findIndex((k) => k > spot);

  return (
    <Card
      title={
        <span className="flex items-center gap-2">
          <span>Institutional Options Matrix</span>
          <span className="text-xs font-medium text-muted">
            {product.underlyingSymbol}/{product.assetSymbol}
          </span>
        </span>
      }
      action={
        <Segmented
          size="sm"
          value={mode}
          onChange={onModeChange}
          options={[
            { value: "buy", label: "Buying (Ask)" },
            { value: "write", label: "Writing (Bid)" },
          ]}
        />
      }
    >
      <div className="overflow-x-auto">
        <table className="mx-auto w-full max-w-4xl table-fixed text-sm min-w-[580px]">
          <thead>
            <tr className="text-xs text-muted border-b border-line">
              <th className="pb-3 text-right font-semibold">CALLS (Upward)</th>
              <th className="w-36 pb-3 text-center font-bold text-ink">STRIKE</th>
              <th className="pb-3 text-left font-semibold">PUTS (Downward)</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-line/30">
            {strikes.map((k, i) => (
              <Fragment key={k.toString()}>
                {i === spotIndex && spot !== undefined && <SpotCrosshairRow spot={spot} />}
                <tr className="group hover:bg-surface-2/40 transition">
                  <td className="py-1.5 pr-2">
                    <ProCell
                      s={series.find((s) => s.strikeWad === k && s.optionType === 0)}
                      mode={mode}
                      itm={spot !== undefined && spot > k}
                      align="right"
                    />
                  </td>
                  <td className="py-1.5 text-center">
                    <span className="num inline-block rounded-xl bg-surface-2 px-3 py-1 font-bold text-ink shadow-inner">
                      ${fmtWad(k, 0)}
                    </span>
                  </td>
                  <td className="py-1.5 pl-2">
                    <ProCell
                      s={series.find((s) => s.strikeWad === k && s.optionType === 1)}
                      mode={mode}
                      itm={spot !== undefined && spot < k}
                      align="left"
                    />
                  </td>
                </tr>
              </Fragment>
            ))}
            {spotIndex === -1 && spot !== undefined && strikes.length > 0 && strikes[strikes.length - 1]! <= spot && (
              <SpotCrosshairRow spot={spot} />
            )}
          </tbody>
        </table>
      </div>

      <div className="mt-4 flex flex-wrap items-center justify-between gap-2 text-xs text-muted border-t border-line pt-3">
        <span>
          {mode === "buy" ? "Prices shown are Ask (purchase price on Kuru)." : "Prices shown are Bid (payout you receive for writing)."}
        </span>
        <span className="flex items-center gap-1.5">
          <span className="h-2 w-2 rounded-full bg-primary/40" /> Shaded cells indicate In-The-Money (ITM)
        </span>
      </div>
    </Card>
  );
}

function SpotCrosshairRow({ spot }: { spot: bigint }) {
  return (
    <tr aria-hidden>
      <td colSpan={3} className="py-2">
        <div className="flex items-center gap-2 text-xs font-bold text-accent">
          <div className="h-px flex-1 bg-accent/40" />
          <span className="pill bg-accent/15 text-accent shadow-sm">
            Current Price: ${fmtWad(spot, 0)}
          </span>
          <div className="h-px flex-1 bg-accent/40" />
        </div>
      </td>
    </tr>
  );
}

function ProCell({
  s,
  mode,
  itm,
  align,
}: {
  s?: Series;
  mode: ChainMode;
  itm: boolean;
  align: "left" | "right";
}) {
  const navigate = useNavigate();
  const { data: m, isLoading } = useSeriesMarket(s);
  if (!s) return <div className="h-12" />;

  const quote = mode === "buy" ? m?.quote?.ask : m?.quote?.bid;
  const price = quote ?? m?.mark;

  return (
    <button
      onClick={() => navigate(`/series/${s.id}?tab=${mode}`)}
      className={cx(
        "flex h-12 w-full items-center gap-3 rounded-2xl border border-transparent px-3 transition hover:border-primary hover:bg-primary-soft",
        align === "right" ? "flex-row-reverse text-right" : "text-left",
        itm && "bg-primary/10"
      )}
      aria-label={`${s.optionType === 0 ? "Call" : "Put"} ${fmtWad(s.strikeWad, 0)}: ${price !== undefined ? fmtPrice(price) : "no price"}`}
    >
      <div>
        <div className="num font-bold text-ink">
          {isLoading ? <Skeleton className="h-4 w-12" /> : price !== undefined ? fmtPrice(price) : "—"}
        </div>
        <div className="text-[10px] text-muted font-medium">
          {quote !== undefined ? (mode === "buy" ? "ask" : "bid") : m?.mark !== undefined ? "mark" : "no quote"}
        </div>
      </div>
      <div className="text-[11px] text-muted font-medium">
        {m?.iv !== undefined ? `IV ${fmtIv(m.iv, 0)}` : ""}
      </div>
    </button>
  );
}
