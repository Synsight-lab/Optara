/** `/`: products, expiries and the option chain (FRONTEND.md §2 "Markets"). */
import { Fragment, useMemo, useState } from "react";
import { Link, useNavigate } from "react-router";
import type { Hex } from "viem";
import { Card, EmptyState, Pill, Segmented, Skeleton, Term, cx } from "../components/ui.tsx";
import { fmtDuration, fmtExpiry, fmtExpiryShort, fmtIv, fmtPrice, fmtWad } from "../lib/optara/format.ts";
import { useChainTime, useProductMarket, useSeriesList, useSeriesMarket } from "../lib/optara/hooks.ts";
import type { Series } from "../lib/optara/types.ts";

type Mode = "buy" | "write";

export function MarketsPage() {
  const { data: series, isLoading, error } = useSeriesList();
  const { data: now } = useChainTime();
  const products = useMemo(() => [...new Map((series ?? []).map((s) => [s.productId, s])).values()], [series]);
  const [productId, setProductId] = useState<Hex | undefined>();
  const product = products.find((p) => p.productId === productId) ?? products[0];
  const live = (series ?? []).filter((s) => s.productId === product?.productId && (now === undefined || s.expiry > now));
  const expiries = [...new Set(live.map((s) => s.expiry))];
  const [expiry, setExpiry] = useState<bigint | undefined>();
  const chosen = expiry !== undefined && expiries.includes(expiry) ? expiry : expiries[0];
  const [mode, setMode] = useState<Mode>("buy");

  if (error) return <Card><EmptyState icon="!" title="Can't reach the network" body={(error as Error).message} /></Card>;
  if (isLoading) return <Card><Skeleton className="h-64 w-full" /></Card>;
  if (!product) return <Card><EmptyState title="No markets listed yet" body="Series appear here as soon as they are listed." /></Card>;

  return (
    <div className="space-y-6">
      <Hero s={product} />
      <HowItWorks />
      {products.length > 1 && (
        <Segmented value={product.productId} onChange={setProductId} options={products.map((p) => ({ value: p.productId, label: `${p.underlyingSymbol}/${p.assetSymbol}` }))} />
      )}
      <Card
        title={
          <span className="flex items-center gap-2">
            Option chain <span className="text-sm font-normal text-muted">{product.underlyingSymbol}/{product.assetSymbol}</span>
          </span>
        }
        action={<Segmented size="sm" value={mode} onChange={setMode} options={[{ value: "buy", label: "I want to buy" }, { value: "write", label: "I want to write" }]} />}
      >
        {expiries.length === 0 ? (
          <EmptyState title="No open expiries" body="Every listed expiry has passed. See Settlement for payouts." action={<Link to="/settlement" className="btn-ghost">Go to settlement</Link>} />
        ) : (
          <>
            <div className="mb-4 flex flex-wrap items-center gap-2">
              {expiries.map((e) => (
                <button key={e.toString()} onClick={() => setExpiry(e)} className={cx("rounded-xl border px-3.5 py-2 text-left transition", e === chosen ? "border-primary bg-primary-soft" : "border-line hover:border-primary/50")}>
                  <div className="text-sm font-semibold">{fmtExpiryShort(e)}</div>
                  <div className="text-xs text-muted">{now !== undefined ? `in ${fmtDuration(e - now)}` : ""}</div>
                </button>
              ))}
              {chosen !== undefined && <span className="ml-auto text-xs text-muted">Expires {fmtExpiry(chosen)} · cash-settled</span>}
            </div>
            <Chain series={live.filter((s) => s.expiry === chosen)} mode={mode} productId={product.productId} />
            <p className="mt-4 text-xs text-muted">
              {mode === "buy" ? "Prices are what you'd pay per option on Kuru (ask)." : "Prices are what buyers bid per option on Kuru."} Tap any price to continue. Shaded
              cells are <Term tip="In the money: the option would pay something if it expired at today's price.">in the money</Term>.
            </p>
          </>
        )}
      </Card>
    </div>
  );
}

function Hero({ s }: { s: Series }) {
  const { data: m } = useProductMarket(s.productId);
  return (
    <section className="card relative overflow-hidden p-6 md:p-8">
      <div className="absolute -right-24 -top-24 h-72 w-72 rounded-full bg-monad-purple/25 blur-3xl" aria-hidden />
      <div className="absolute -bottom-24 right-40 h-56 w-56 rounded-full bg-monad-berry/20 blur-3xl" aria-hidden />
      <div className="relative flex flex-wrap items-end justify-between gap-6">
        <div>
          <div className="label">{s.underlyingSymbol} options · settled in {s.assetSymbol}</div>
          <h1 className="mt-2 text-3xl font-bold tracking-tight md:text-4xl">Options on {s.underlyingSymbol}, on Monad.</h1>
          <p className="mt-2 max-w-xl text-muted">Buy calls and puts with a known maximum cost, or write them and earn the premium. Settled automatically at expiry.</p>
        </div>
        <div className="text-right">
          <div className="label">{s.underlyingSymbol} price</div>
          <div className="num mt-1 text-4xl font-bold">{m ? fmtWad(m.spotWad, 2) : <Skeleton className="ml-auto h-10 w-40" />}</div>
          <div className="mt-2 flex flex-wrap justify-end gap-1.5">
            {m && (
              <>
                <Pill tone={m.spotFresh ? "good" : "warn"} dot>
                  {m.spotFresh ? "Live price" : "Price delayed"}
                </Pill>
                <Pill tone={m.surface === "FRESH" ? "good" : m.surface === "STALE" ? "warn" : "bad"}>
                  <Term tip="Volatility data from independent publishers. New positions need it fresh.">Volatility {m.surface === "FRESH" ? "fresh" : m.surface.toLowerCase().replace("_", " ")}</Term>
                </Pill>
                {m.closeOnly && <Pill tone="warn">Closing only</Pill>}
              </>
            )}
          </div>
        </div>
      </div>
    </section>
  );
}

function HowItWorks() {
  const items = [
    { n: "1", title: "Buy", body: "Pay a premium for the right to a payout at expiry. The most you can lose is what you paid." },
    { n: "2", title: "Write", body: "Deposit collateral, write options and earn the premium. Losses are uncapped, so margin is checked." },
    { n: "3", title: "Settle", body: "At expiry a fixed price is proven on-chain; holders redeem their payout, writers' accounts settle." },
  ];
  return (
    <div className="grid gap-3 md:grid-cols-3">
      {items.map((i) => (
        <div key={i.n} className="card flex gap-3 p-4">
          <span className="grid h-8 w-8 shrink-0 place-items-center rounded-xl bg-primary-soft font-bold text-primary">{i.n}</span>
          <div>
            <div className="font-semibold">{i.title}</div>
            <div className="text-sm text-muted">{i.body}</div>
          </div>
        </div>
      ))}
    </div>
  );
}

function Chain({ series, mode, productId }: { series: Series[]; mode: Mode; productId: Hex }) {
  const { data: m } = useProductMarket(productId);
  const strikes = [...new Set(series.map((s) => s.strikeWad))].sort((a, b) => (a < b ? -1 : 1));
  const spot = m?.spotWad;
  const spotIndex = spot === undefined ? -1 : strikes.findIndex((k) => k > spot);
  return (
    <>
      <MobileChain series={series} mode={mode} spot={spot} strikes={strikes} />
    <div className="hidden md:block">
      <table className="mx-auto w-full max-w-4xl table-fixed text-sm">
        <thead>
          <tr className="text-xs text-muted">
            <th className="pb-2 text-right font-medium">Calls</th>
            <th className="w-36 pb-2 text-center font-medium">Strike</th>
            <th className="pb-2 text-left font-medium">Puts</th>
          </tr>
        </thead>
        <tbody>
          {strikes.map((k, i) => (
            <Fragment key={k.toString()}>
              {i === spotIndex && spot !== undefined && <SpotRow spot={spot} />}
              <tr className="group">
                <td className="py-1 pr-2">
                  <Cell s={series.find((s) => s.strikeWad === k && s.optionType === 0)} mode={mode} itm={spot !== undefined && spot > k} align="right" />
                </td>
                <td className="py-1 text-center">
                  <span className="num rounded-lg bg-surface-2 px-3 py-1.5 font-semibold">{fmtWad(k, 0)}</span>
                </td>
                <td className="py-1 pl-2">
                  <Cell s={series.find((s) => s.strikeWad === k && s.optionType === 1)} mode={mode} itm={spot !== undefined && spot < k} align="left" />
                </td>
              </tr>
            </Fragment>
          ))}
          {spotIndex === -1 && spot !== undefined && strikes.length > 0 && strikes[strikes.length - 1]! <= spot && <SpotRow spot={spot} />}
        </tbody>
      </table>
    </div>
    </>
  );
}

/** Phones: one side at a time, strike and price in a compact list. */
function MobileChain({ series, mode, spot, strikes }: { series: Series[]; mode: Mode; spot?: bigint; strikes: bigint[] }) {
  const [type, setType] = useState<"0" | "1">("0");
  const t = Number(type);
  return (
    <div className="md:hidden">
      <div className="mb-3">
        <Segmented size="sm" value={type} onChange={setType} options={[{ value: "0", label: "Calls" }, { value: "1", label: "Puts" }]} />
      </div>
      <div className="space-y-1.5">
        {strikes.map((k) => {
          const s = series.find((x) => x.strikeWad === k && x.optionType === t);
          const itm = spot !== undefined && (t === 0 ? spot > k : spot < k);
          return (
            <div key={k.toString()} className="flex items-center gap-2">
              <span className="num w-20 shrink-0 rounded-lg bg-surface-2 px-2 py-1.5 text-center text-sm font-semibold">{fmtWad(k, 0)}</span>
              <div className="min-w-0 flex-1">
                <Cell s={s} mode={mode} itm={itm} align="left" />
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function SpotRow({ spot }: { spot: bigint }) {
  return (
    <tr aria-hidden>
      <td colSpan={3} className="py-1">
        <div className="flex items-center gap-2 text-xs font-semibold text-accent">
          <div className="h-px flex-1 bg-accent/50" />
          price now {fmtWad(spot, 0)}
          <div className="h-px flex-1 bg-accent/50" />
        </div>
      </td>
    </tr>
  );
}

function Cell({ s, mode, itm, align }: { s?: Series; mode: Mode; itm: boolean; align: "left" | "right" }) {
  const navigate = useNavigate();
  const { data: m, isLoading } = useSeriesMarket(s);
  if (!s) return <div className="h-12" />;
  const quote = mode === "buy" ? m?.quote?.ask : m?.quote?.bid;
  const price = quote ?? m?.mark;
  return (
    <button
      onClick={() => navigate(`/series/${s.id}?tab=${mode}`)}
      className={cx(
        "flex h-12 w-full items-center gap-3 rounded-xl border border-transparent px-3 transition hover:border-primary hover:bg-primary-soft",
        align === "right" ? "flex-row-reverse text-right" : "text-left",
        itm && "bg-primary/5",
      )}
      aria-label={`${s.optionType === 0 ? "Call" : "Put"} ${fmtWad(s.strikeWad, 0)}: ${price !== undefined ? fmtPrice(price) : "no price"}`}
    >
      <div>
        <div className="num font-semibold">{isLoading ? <Skeleton className="h-4 w-14" /> : price !== undefined ? fmtPrice(price) : "—"}</div>
        <div className="text-[11px] text-muted">{quote !== undefined ? (mode === "buy" ? "ask" : "bid") : m?.mark !== undefined ? "model" : "no quote"}</div>
      </div>
      <div className="text-xs text-muted">{m?.iv !== undefined ? `IV ${fmtIv(m.iv, 0)}` : ""}</div>
    </button>
  );
}
