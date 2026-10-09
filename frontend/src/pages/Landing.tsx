import { Link } from "react-router";
import { ArrowRight, Coins, Compass, LineChart, Route, ShieldCheck, TrendingDown, TrendingUp } from "lucide-react";
import { TokenIcon } from "../components/Icons.tsx";
import { Pill, cx } from "../components/ui.tsx";
import { fmtDuration, fmtLevel } from "../lib/optara/format.ts";
import { useChainTime, useProductMarket, useSeriesList } from "../lib/optara/hooks.ts";
import { IS_LOCAL } from "../config/network.ts";
import type { Series } from "../lib/optara/types.ts";

export function LandingPage() {
  const { data: series } = useSeriesList();
  const { data: now } = useChainTime();
  const products = [...new Map((series ?? []).map((s) => [s.productId, s])).values()];
  const live = (series ?? []).filter((s) => now === undefined || s.expiry > now);
  const next = live.reduce<bigint | undefined>((m, s) => (m === undefined || s.expiry < m ? s.expiry : m), undefined);

  return (
    <main className="home-page min-h-screen overflow-hidden bg-bg text-ink">
      <HomeHeader />

      <section className="home-column grid min-h-[calc(100vh-76px)] gap-10 pb-12 pt-8 lg:grid-cols-[minmax(0,1fr)_460px] lg:items-center lg:pb-16">
        <div>
          <div className="inline-flex items-center gap-2 rounded-full border border-primary/25 bg-primary-soft px-3 py-1 text-xs font-bold text-primary">
            <LineChart className="h-3.5 w-3.5" /> Cash-settled options on Monad
          </div>
          <h1 className="font-display mt-5 max-w-4xl text-5xl font-bold leading-[0.96] tracking-tight sm:text-7xl lg:text-8xl">
            Trade a price move without buying the whole coin.
          </h1>
          <p className="mt-6 max-w-2xl text-base leading-7 text-muted sm:text-lg">
            Optara makes options feel like a guided trade: choose an asset, pick up or down, set the premium you are willing to risk, and settle in stablecoin at expiry.
          </p>

          <div className="mt-7 flex flex-wrap gap-2.5">
            <Link to="/app/markets" className="btn-primary">
              Open the app <ArrowRight className="h-4 w-4" />
            </Link>
            <a href="#story" className="btn-ghost">
              See how it works
            </a>
          </div>

          <div className="mt-8 grid max-w-2xl gap-2 sm:grid-cols-3">
            <MiniMetric label="Listed assets" value={products.length || "—"} />
            <MiniMetric label="Open options" value={live.length || "—"} />
            <MiniMetric label="Next expiry" value={next !== undefined && now !== undefined ? fmtDuration(next - now) : "—"} />
          </div>
        </div>

        <OptionFrame products={products} />
      </section>

      <section id="story" className="home-column py-10">
        <div className="home-journey">
          <div>
            <div className="flex items-center gap-2 text-sm font-bold text-primary">
              <Route className="h-4 w-4" /> Simple by default
            </div>
            <h2 className="font-display mt-3 max-w-xl text-4xl font-bold tracking-tight">One guided flow from market view to cash settlement.</h2>
            <p className="mt-4 max-w-xl text-sm leading-6 text-muted">
              Optara keeps the buyer experience short while still exposing the deeper writer, keeper and risk tools inside the app when they are needed.
            </p>
            <div className="home-role-strip">
              <RolePill icon={TrendingUp} label="Buy calls" />
              <RolePill icon={TrendingDown} label="Buy puts" />
              <RolePill icon={Coins} label="Write premium" />
              <RolePill icon={ShieldCheck} label="Monitor risk" />
            </div>
          </div>
          <div className="home-journey-rail">
            <JourneyStep k="01" title="Choose an asset" text="Start from MON, ETH, BTC or any listed market." />
            <JourneyStep k="02" title="Review the trade" text="See premium, fees, route and max buyer loss before signing." />
            <JourneyStep k="03" title="Route liquidity" text="Use Optara direct, Kuru, or future venues without changing the option token." />
            <JourneyStep k="04" title="Settle in cash" text="At expiry, the protocol fixes the price and holders redeem payouts." />
          </div>
        </div>
      </section>

      <section className="home-column py-8 pb-14">
        <div className="rounded-3xl border border-line bg-surface p-5 shadow-ticket sm:p-6">
          <div className="mb-4 flex flex-wrap items-end justify-between gap-3">
            <div>
              <h2 className="font-display text-2xl font-bold">Live products</h2>
              <p className="mt-1 text-sm text-muted">Choose the asset first. The app shows strikes, expiries and routes after that.</p>
            </div>
            <Link to="/app/markets" className="btn-ghost text-sm">Browse markets</Link>
          </div>
          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
            {products.length === 0 ? (
              <div className="rounded-2xl border border-line bg-surface-2 p-4 text-sm text-muted">No products are listed yet.</div>
            ) : (
              products.map((p) => <ProductTile key={p.productId} product={p} />)
            )}
          </div>
        </div>
      </section>
    </main>
  );
}

function HomeHeader() {
  return (
    <header className="home-column flex h-[76px] items-center justify-between gap-3">
      <Link to="/" aria-label="Optara home" className="flex items-center gap-3">
        <img src="/brand/logo/optara-lockup-light.svg" alt="Optara" className="theme-logo-light h-10 w-auto" />
        <img src="/brand/logo/optara-lockup-dark.svg" alt="Optara" className="theme-logo-dark h-10 w-auto" />
        {IS_LOCAL && <Pill tone="primary">Local</Pill>}
      </Link>
      <nav className="flex items-center gap-2">
        <Link to="/app" className="btn-primary !px-4 !py-2 text-sm">
          Optara app <ArrowRight className="h-4 w-4" />
        </Link>
      </nav>
    </header>
  );
}

function OptionFrame({ products }: { products: Series[] }) {
  const first = products[0];
  const second = products[1] ?? first;
  return (
    <div className="home-3d-scene mx-auto w-full max-w-[460px]" aria-hidden>
      <div className="home-3d-stack">
        <div className="home-float home-float-one">Live price</div>
        <div className="home-float home-float-two">Fixed premium</div>
        <div className="home-float home-float-three">Cash settled</div>
        <FrameCard className="home-frame-a" title={first ? `${first.underlyingSymbol} Call` : "ETH Call"} headline="Trade upside" label="Buy exposure above the strike with a known premium." tone="good" product={first} />
        <FrameCard className="home-frame-b" title={second ? `${second.underlyingSymbol} Put` : "MON Put"} headline="Hedge downside" label="Use puts to protect or trade a move lower." tone="bad" product={second} />
        <div className="home-frame-base">
          <div className="flex items-center justify-between">
            <span className="text-xs font-bold uppercase text-faint">Route and settle</span>
            <span className="rounded-full bg-good/10 px-2 py-1 text-xs font-bold text-good">Ready</span>
          </div>
          <div className="mt-5 h-2 rounded-full bg-surface-2">
            <div className="h-2 w-3/4 rounded-full bg-primary" />
          </div>
          <div className="mt-3 grid grid-cols-3 gap-2 text-center text-xs">
            <span className="rounded-xl bg-surface-2 p-2">Price</span>
            <span className="rounded-xl bg-surface-2 p-2">Venue</span>
            <span className="rounded-xl bg-surface-2 p-2">Redeem</span>
          </div>
        </div>
      </div>
    </div>
  );
}

function FrameCard({ title, headline, label, tone, product, className }: { title: string; headline: string; label: string; tone: "good" | "bad"; product?: Series; className: string }) {
  return (
    <div className={cx("home-frame-card", className)}>
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <TokenIcon symbol={product?.underlyingSymbol ?? "ETH"} className="h-8 w-8" />
          <span className="font-display text-lg font-bold">{title}</span>
        </div>
        <span className={cx("rounded-full px-2 py-1 text-xs font-bold", tone === "good" ? "bg-good/10 text-good" : "bg-bad/10 text-bad")}>
          {tone === "good" ? "Up" : "Down"}
        </span>
      </div>
      <div className={cx("font-display mt-6 text-3xl font-bold", tone === "good" ? "text-good" : "text-bad")}>{headline}</div>
      <div className="mt-1 text-sm text-muted">{label}</div>
      <svg viewBox="0 0 260 80" className="mt-5 h-20 w-full">
        <path d={tone === "good" ? "M0 62 L115 62 L238 14" : "M0 15 L110 15 L238 64"} fill="none" stroke={tone === "good" ? "var(--good)" : "var(--bad)"} strokeWidth="7" strokeLinecap="round" />
        <circle cx="115" cy={tone === "good" ? "62" : "15"} r="6" fill="var(--warn)" />
      </svg>
    </div>
  );
}

function RolePill({ icon: Icon, label }: { icon: typeof Compass; label: string }) {
  return (
    <span className="inline-flex items-center gap-2 rounded-full border border-line bg-surface px-3 py-2 text-sm font-bold text-ink">
      <Icon className="h-4 w-4 text-primary" /> {label}
    </span>
  );
}

function MiniMetric({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded-2xl border border-line bg-surface/80 p-3">
      <div className="text-[11px] font-bold uppercase text-faint">{label}</div>
      <div className="font-display mt-1 text-2xl font-bold">{value}</div>
    </div>
  );
}

function JourneyStep({ k, title, text }: { k: string; title: string; text: string }) {
  return (
    <div className="home-journey-step">
      <div className="home-journey-index">{k}</div>
      <div>
        <div className="font-display text-lg font-bold">{title}</div>
        <p className="mt-1 text-sm leading-6 text-muted">{text}</p>
      </div>
    </div>
  );
}

function ProductTile({ product }: { product: Series }) {
  const { data } = useProductMarket(product.productId);
  return (
    <Link to="/app/markets" className="rounded-2xl border border-line bg-surface-2/70 p-4 transition hover:border-primary/45 hover:bg-primary-soft/50">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <TokenIcon symbol={product.underlyingSymbol} className="h-8 w-8" />
          <div>
            <div className="font-bold">{product.underlyingSymbol}</div>
            <div className="text-xs text-muted">settles in {product.assetSymbol}</div>
          </div>
        </div>
        <ArrowRight className="h-4 w-4 text-faint" />
      </div>
      <div className="num mt-3 font-display text-xl font-bold">{data ? `$${fmtLevel(data.spotWad)}` : "—"}</div>
      <div className="mt-1 text-xs text-muted">{data?.spotFresh ? "Live price" : "Waiting for price"}</div>
    </Link>
  );
}
