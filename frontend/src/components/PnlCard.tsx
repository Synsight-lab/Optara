/** Profit and loss: overall, then per option traded (lib/optara/pnl.ts). */
import { useMemo, useState } from "react";
import { Link } from "react-router";
import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { ChevronDown, ChevronUp, TrendingDown, TrendingUp } from "lucide-react";
import { fmtExpiry, seriesName } from "../lib/optara/format.ts";
import { usd } from "../lib/optara/payoff.ts";
import { pnlOf, totals, unrealizedOf, type HistoryEntry, type SeriesPnl } from "../lib/optara/pnl.ts";
import { legOf, payoutPerOption, priceLevel } from "../lib/optara/payoff.ts";
import { getTradePnl } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { Card, EmptyState, Pill, Skeleton, Term, cx } from "./ui.tsx";

type Filter = "all" | "open" | "expired" | "closed";

const qtyText = (x: number) => x.toLocaleString("en-US", { maximumFractionDigits: 4 });
const pctText = (p: number | undefined) => (p === undefined ? "" : `${p >= 0 ? "+" : "−"}${Math.abs(p * 100).toFixed(1)}%`);

export function PnlCard({ owner, accounts, series }: { owner: Address; accounts: bigint[]; series: Series[] }) {
  const { data, isLoading, error } = useQuery({
    queryKey: ["pnl", owner, accounts.map(String).join(), series.length],
    queryFn: () => getTradePnl(owner, accounts, series),
    enabled: series.length > 0,
    refetchInterval: 20_000,
  });
  const [filter, setFilter] = useState<Filter>("all");

  const rows = useMemo(() => {
    const all = (data ?? []).filter((r) => r.paid > 0 || r.received > 0 || r.value !== 0);
    const order = { open: 0, expired: 1, closed: 2 } as const;
    return all.sort((a, b) => order[a.status] - order[b.status] || Math.abs(pnlOf(b)) - Math.abs(pnlOf(a)));
  }, [data]);
  const counts = useMemo(() => ({
    all: rows.length,
    open: rows.filter((r) => r.status === "open").length,
    expired: rows.filter((r) => r.status === "expired").length,
    closed: rows.filter((r) => r.status === "closed").length,
  }), [rows]);
  const shown = rows.filter((r) => filter === "all" || r.status === filter);
  const sums = totals(rows);

  return (
    <Card title="Profit & loss" action={rows.length > 0 ? <PnlFilters value={filter} onChange={setFilter} counts={counts} /> : undefined}>
      {isLoading ? (
        <Skeleton className="h-40 w-full" />
      ) : error ? (
        <p className="text-[13px] text-bad">Couldn't load your trade history: {(error as Error).message.split("\n")[0]}</p>
      ) : rows.length === 0 ? (
        <EmptyState title="No trades yet" body="Once you buy, sell or write an option, its profit or loss shows here." action={<Link to="/app/markets" className="btn-ghost mt-2 text-xs">Browse markets</Link>} />
      ) : (
        <div className="space-y-3">
          {[...sums.entries()].map(([asset, t]) => (
            <div key={asset} className={cx("overflow-hidden rounded-2xl border p-3.5", t.pnl >= 0 ? "border-good/30 bg-good/8" : "border-bad/30 bg-bad/8")}>
              <div className="grid gap-3 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)]">
                <div>
                  <div className="text-[13px] text-muted">Overall {sums.size > 1 ? `(${asset})` : ""}</div>
                  <div className={cx("num font-display flex items-center gap-1.5 text-2xl font-bold tracking-tight", t.pnl >= 0 ? "text-good" : "text-bad")}>
                    {t.pnl >= 0 ? <TrendingUp className="h-6 w-6" /> : <TrendingDown className="h-6 w-6" />}
                    {usd(t.pnl, { sign: true })}
                    <span className="text-base font-semibold">{pctText(t.pct)}</span>
                  </div>
                  <div className="mt-0.5 text-[13px] font-semibold">{t.pnl >= 0 ? "Net profit" : "Net loss"} across these rows</div>
                </div>
                <CashFlowChart paid={t.paid} received={t.received} value={t.value} realized={t.realized} unrealized={t.unrealized} />
              </div>
              <p className="mt-2 text-xs text-muted">
                Formula: cash received + value still held − cash paid. Premium from written options is only profit after
                the matching short is closed or settled. {t.winners} winner{t.winners === 1 ? "" : "s"} · {t.losers} loser{t.losers === 1 ? "" : "s"}
                {t.pct !== undefined ? ` · % of ${usd(t.paid)} paid in all` : ""}.
              </p>
            </div>
          ))}

          <ul className="divide-y divide-line/60">
            {shown.map((r) => (
              <PnlRow key={r.series.id} r={r} />
            ))}
            {shown.length === 0 && <li className="py-5 text-center text-[13px] text-muted">No {filter === "all" ? "positions" : filter} rows here.</li>}
          </ul>

          <p className="text-xs leading-relaxed text-muted">
            Built from your on-chain history: buys and sells (fees included), writing fees, redemptions and settlement. Each sale
            is measured against the average cost of the options it closed. Written options stay open as negative value
            until you burn matching tokens or settlement prices the payout. What you still hold is valued at Optara's fair
            value before expiry (selling on the order book may get a little less), and at its payout after expiry.
            Rows marked ≈ include transferred tokens or partial history where the exact cost basis is not fully known.
          </p>
        </div>
      )}
    </Card>
  );
}

function PnlFilters({ value, onChange, counts }: { value: Filter; onChange: (v: Filter) => void; counts: Record<Filter, number> }) {
  const items: { value: Filter; label: string }[] = [
    { value: "all", label: "All" },
    { value: "open", label: "Open" },
    { value: "expired", label: "Expired" },
    { value: "closed", label: "Closed" },
  ];
  return (
    <div className="flex flex-wrap gap-1 rounded-2xl border border-line bg-surface-2 p-1">
      {items.map((x) => {
        const disabled = x.value !== "all" && counts[x.value] === 0;
        return (
          <button
            key={x.value}
            type="button"
            disabled={disabled}
            onClick={() => onChange(x.value)}
            className={cx(
              "rounded-xl px-2.5 py-1.5 text-xs font-bold transition",
              value === x.value ? "bg-primary text-white shadow-sm" : "text-muted hover:bg-surface hover:text-ink",
              disabled && "cursor-not-allowed opacity-40 hover:bg-transparent hover:text-muted",
            )}
          >
            {x.label} <span className="num opacity-80">{counts[x.value]}</span>
          </button>
        );
      })}
    </div>
  );
}

function CashFlowChart({ paid, received, value, realized, unrealized }: { paid: number; received: number; value: number; realized: number; unrealized: number }) {
  const max = Math.max(1, paid, received, Math.abs(value));
  const bars = [
    { label: "Paid", value: paid, color: "bg-bad", text: usd(paid) },
    { label: "Received", value: received, color: "bg-good", text: usd(received) },
    { label: "Still held", value: Math.abs(value), color: value >= 0 ? "bg-primary" : "bg-warn", text: usd(value) },
  ];
  return (
    <div className="rounded-2xl border border-line/70 bg-surface/70 p-3">
      <div className="mb-2 grid grid-cols-2 gap-2 text-xs">
        <div>
          <span className="text-muted">Locked in</span>
          <span className={cx("num ml-1 font-bold", realized >= 0 ? "text-good" : "text-bad")}>{usd(realized, { sign: true })}</span>
        </div>
        <div className="text-right">
          <span className="text-muted">Open</span>
          <span className={cx("num ml-1 font-bold", unrealized >= 0 ? "text-good" : "text-bad")}>{usd(unrealized, { sign: true })}</span>
        </div>
      </div>
      <div className="grid gap-2">
        {bars.map((p) => (
          <div key={p.label} className="grid grid-cols-[68px_1fr_auto] items-center gap-2 text-xs">
            <span className="font-semibold text-muted">{p.label}</span>
            <div className="h-2 overflow-hidden rounded-full bg-surface-2">
              <div className={cx("h-full rounded-full", p.color)} style={{ width: `${Math.max(4, (p.value / max) * 100)}%` }} />
            </div>
            <span className="num font-bold">{p.text}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function PnlRow({ r }: { r: SeriesPnl }) {
  const total = pnlOf(r);
  const unreal = unrealizedOf(r);
  const unrealPct = r.costHeld > 0 ? unreal / r.costHeld : undefined;
  const holding = [
    r.walletQty > 0 ? `${qtyText(r.walletQty)} in wallet` : undefined,
    r.accountQty > 0 ? `${qtyText(r.accountQty)} in account` : undefined,
    r.accountQty < 0 ? `${qtyText(-r.accountQty)} written` : undefined,
  ].filter(Boolean);
  const held = r.walletQty !== 0 || r.accountQty !== 0;
  const [open, setOpen] = useState(false);
  return (
    <li>
      <button type="button" onClick={() => setOpen((o) => !o)} aria-expanded={open} className="grid w-full cursor-pointer text-left grid-cols-[1fr_auto] items-center gap-x-3 gap-y-1 rounded-xl px-1.5 py-2.5 transition hover:bg-primary-soft/40 sm:grid-cols-[1fr_auto_auto_auto_auto_auto]">
        <span className="min-w-0">
          <span className="flex flex-wrap items-center gap-1.5">
            <span className="truncate text-sm font-bold">{seriesName(r.series)}</span>
            <Pill tone={r.status === "open" ? "primary" : r.status === "expired" ? "warn" : "neutral"}>{r.status === "open" ? "Open" : r.status === "expired" ? "Expired" : "Closed"}</Pill>
            {r.approximate && <span title="Part of this history (a liquidation, or options received by transfer) has no exact price on record.">≈</span>}
          </span>
          <span className="block truncate text-xs text-muted">
            {holding.length ? holding.join(" · ") : r.status === "closed" ? "Finished · nothing left to hold" : "Nothing held"}
            {r.settlementPrice !== undefined && ` · settled at ${priceLevel(r.settlementPrice)}`}
          </span>
          {/* On phones the breakdown goes under the name */}
          <span className="block text-xs text-muted sm:hidden">
            {held && <>Unrealized <b className={unreal >= 0 ? "text-good" : "text-bad"}>{usd(unreal, { sign: true })}</b> · </>}
            Realized <b className={r.realized >= 0 ? "text-good" : "text-bad"}>{usd(r.realized, { sign: true })}</b>
          </span>
        </span>
        <Cell label="Cost held" value={held ? usd(r.costHeld) : "—"} />
        <Cell label="Value now" value={held ? usd(r.value) : "—"} />
        <Cell label="Unrealized" value={held ? `${usd(unreal, { sign: true })}${unrealPct !== undefined ? ` (${pctText(unrealPct)})` : ""}` : "—"} tone={held ? (unreal >= 0 ? "text-good" : "text-bad") : undefined} />
        <Cell label="Realized" value={usd(r.realized, { sign: true })} tone={Math.abs(r.realized) < 0.005 ? undefined : r.realized >= 0 ? "text-good" : "text-bad"} />
        <span className="col-start-2 row-span-2 row-start-1 text-right sm:col-auto sm:row-auto">
          <span className="block text-[11px] text-muted">Total</span>
          <span className={cx("num flex items-center justify-end gap-1 text-[15px] font-bold", total >= 0 ? "text-good" : "text-bad")}>
            {usd(total, { sign: true })}
            {open ? <ChevronUp className="h-4 w-4 text-muted" /> : <ChevronDown className="h-4 w-4 text-muted" />}
          </span>
        </span>
      </button>
      {open && <History r={r} />}
    </li>
  );
}

const KIND: Record<HistoryEntry["kind"], string> = { buy: "Bought", sell: "Sold", write: "Opened short", close: "Closed short", redeem: "Redeemed", settle: "Settled" };

/** What happened to this option for you, oldest first, then how it ended. */
function History({ r }: { r: SeriesPnl }) {
  const unit = r.settlementPrice !== undefined ? payoutPerOption(legOf(r.series), r.settlementPrice) : undefined;
  const isCall = r.series.optionType === 0;
  return (
    <div className="mb-2 ml-1.5 space-y-2 rounded-xl border border-line bg-surface-2/60 p-3 text-[13px]">
      <ol className="space-y-1.5">
        {r.history.map((e, i) => (
          <li key={i} className="grid grid-cols-[auto_1fr_auto] items-baseline gap-x-3">
            <span className="num text-xs text-muted">{e.at ? new Date(e.at * 1000).toISOString().slice(5, 16).replace("T", " ") : ""}</span>
            <span>
              <b>{KIND[e.kind]}</b>{" "}
              {e.kind === "settle"
                ? e.qty < 0
                  ? `${qtyText(-e.qty)} written option${-e.qty === 1 ? "" : "s"} at ${priceLevel(e.price!)}: you paid what they owed`
                  : `${qtyText(e.qty)} option${e.qty === 1 ? "" : "s"} in your account at ${priceLevel(e.price!)}`
                : e.kind === "write"
                ? `${qtyText(e.qty)} written option${e.qty === 1 ? "" : "s"}; fee paid, obligation opened`
                : e.kind === "close"
                ? `${qtyText(e.qty)} option token${e.qty === 1 ? "" : "s"} burned against the written position`
                : `${qtyText(e.qty)} option${e.qty === 1 ? "" : "s"}`}
            </span>
            <span className={cx("num text-right font-semibold", e.cash > 0 ? "text-good" : e.cash < 0 ? "text-bad" : "text-muted")}>
              {usd(e.cash, { sign: true })}
            </span>
          </li>
        ))}
      </ol>
      {r.settlementPrice !== undefined && unit !== undefined && (
        <p className="border-t border-line pt-2 text-xs leading-relaxed text-muted">
          Expiry {fmtExpiry(r.series.expiry)}: {r.series.underlyingSymbol} settled at <b className="text-ink">{priceLevel(r.settlementPrice)}</b>, strike{" "}
          {priceLevel(legOf(r.series).strike)}.{" "}
          {unit > 0
            ? `The ${isCall ? "call" : "put"} finished in the money: each option paid ${usd(unit)}.`
            : `The ${isCall ? "call" : "put"} finished out of the money: each option paid nothing.`}
          {r.walletQty > 0 && unit > 0 && " Your remaining options can be redeemed on the option's Settle tab."}
        </p>
      )}
      <Link to={`/app/series/${r.series.id}?tab=${r.status === "expired" ? "redeem" : "trade"}`} className="inline-block text-xs font-semibold text-primary">
        Open this option →
      </Link>
    </div>
  );
}

function Cell({ label, value, tone }: { label: string; value: string; tone?: string }) {
  return (
    <span className="hidden text-right sm:block">
      <span className="block text-[11px] text-muted">{label}</span>
      <span className={cx("num block text-[13px] font-semibold", tone)}>{value}</span>
    </span>
  );
}
