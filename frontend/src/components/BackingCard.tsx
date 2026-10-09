/**
 * What backs an option, for buyers: who wrote it, the collateral behind those writers, what is owed if it expired
 * now, the insurance fund, and the protection layers in order (MARGIN_AND_RISK.md, LIQUIDATION.md, SETTLEMENT.md).
 */
import { useQuery } from "@tanstack/react-query";
import { ShieldCheck } from "lucide-react";
import { fmtNative, fmtQty, fmtWad } from "../lib/optara/format.ts";
import { classifyHealth } from "../lib/optara/health.ts";
import { legOf, payoutPerOption, usd } from "../lib/optara/payoff.ts";
import { getBacking } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { Card, Pill, Skeleton, Term } from "./ui.tsx";

const SHOWN_WRITERS = 5;

export function BackingCard({ series, spot }: { series: Series; spot?: number }) {
  const { data: b, isLoading } = useQuery({ queryKey: ["backing", series.id], queryFn: () => getBacking(series), refetchInterval: 15_000 });
  const leg = legOf(series);
  const isCall = series.optionType === 0;

  return (
    <Card
      title={
        <span className="flex items-center gap-2">
          <ShieldCheck className="h-4 w-4 text-good" /> What backs this option
        </span>
      }
    >
      <p className="text-[13px] leading-relaxed text-muted">
        Every option is a promise from the account that <b className="text-ink">wrote</b> it to pay the holder at expiry. Writers lock{" "}
        {series.assetSymbol} in Optara margin accounts, and that collateral can't be withdrawn while it is needed for their positions.
        Every option held has a writer behind it; the contracts enforce that.
      </p>

      {isLoading || !b ? (
        <Skeleton className="mt-3 h-40 w-full" />
      ) : b.written === 0n ? (
        <p className="mt-3 rounded-xl border border-line bg-surface-2/60 p-3 text-[13px] text-muted">
          Nobody has written this option yet, so there is nothing to buy or back. Options appear on the order book once a writer creates them.
        </p>
      ) : (
        <BackingDetails b={b} series={series} spot={spot} />
      )}

      <ol className="mt-4 space-y-2 text-[13px]">
        <li className="text-xs font-semibold uppercase tracking-wide text-muted">If a writer can't pay</li>
        {[
          ["Collateral", `Writers must keep enough ${series.assetSymbol} to survive large price and volatility swings, checked on-chain. Below that, they can't write more or withdraw.`],
          ["Liquidation", "If a writer's account falls below its liquidation line, anyone can take over the positions at a discount, before the account runs out."],
          ["Insurance fund", `At settlement, anything a writer still can't pay is covered by the ${series.assetSymbol} insurance fund${b ? ` (${fmtNative(b.insurance, series.assetDecimals)} ${series.assetSymbol} today)` : ""}.`],
          ["Shared shortfall", "Only if losses are bigger than all of the above are holders of that expiry paid the same reduced percentage. This is shown on the Settlement page."],
        ].map(([t, d], i) => (
          <li key={t} className="flex gap-2.5">
            <span className="grid h-5 w-5 shrink-0 place-items-center rounded-full bg-primary-soft text-[11px] font-bold text-primary">{i + 1}</span>
            <span>
              <b>{t}.</b> <span className="text-muted">{d}</span>
            </span>
          </li>
        ))}
      </ol>

      <p className="mt-3 text-xs leading-relaxed text-muted">
        {isCall
          ? `A call's payout has no upper limit, so it can't be backed by a fixed amount of cash per option. Backing is sized by stress tests and kept up by liquidation.`
          : `A put pays at most ${usd(leg.strike * leg.size)} per option (if ${series.underlyingSymbol} went to zero). Writers' collateral is sized by stress tests rather than locked at that full amount, and kept up by liquidation.`}
      </p>
    </Card>
  );
}

function BackingDetails({ b, series, spot }: { b: NonNullable<Awaited<ReturnType<typeof getBacking>>>; series: Series; spot?: number }) {
  const leg = legOf(series);
  const writtenNum = Number(b.written) / 1e18;
  const owedNow = spot !== undefined ? payoutPerOption(leg, spot) * writtenNum : undefined;
  const healthy = b.writers.filter((w) => w.health.state === "HEALTHY" || w.health.state === "CLOSE_ONLY").length;
  const totalValue = b.writers.reduce((t, w) => t + w.health.equity, 0n);
  const totalLine = b.writers.reduce((t, w) => t + w.health.maintenanceMargin, 0n);

  return (
    <div className="mt-3 space-y-3">
      <dl className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Fact
          label={<Term tip="Options created by writers and not yet closed. The same number is held by buyers, in wallets or margin accounts.">Options written</Term>}
          value={fmtQty(b.written)}
          sub={`by ${b.writers.length} account${b.writers.length === 1 ? "" : "s"}`}
        />
        <Fact
          label={<Term tip="What writers would owe in total if the option expired at today's price.">Owed if it expired now</Term>}
          value={owedNow !== undefined ? usd(owedNow) : "—"}
          sub={series.assetSymbol}
        />
        <Fact
          label={<Term tip="The writers' combined account value: cash plus positions. It backs all of their positions, not only this option.">Writers' account value</Term>}
          value={`$${fmtWad(totalValue, 0)}`}
          sub={`liquidation line $${fmtWad(totalLine, 0)}`}
        />
        <Fact
          label={<Term tip="Writers whose collateral is above their liquidation line.">Writers in good standing</Term>}
          value={`${healthy} of ${b.writers.length}`}
          sub={healthy === b.writers.length ? "all above the line" : "some can be liquidated"}
          tone={healthy === b.writers.length ? "text-good" : "text-warn"}
        />
      </dl>

      <div className="rounded-xl border border-line bg-surface-2/60 p-2">
        <div className="grid grid-cols-[1fr_auto_auto] gap-x-3 px-1.5 pb-1 text-[11px] font-semibold text-muted">
          <span>Writer</span>
          <span className="text-right">Wrote</span>
          <span className="text-right">Collateral cover</span>
        </div>
        <ul className="divide-y divide-line/60">
          {b.writers.slice(0, SHOWN_WRITERS).map((w) => {
            const v = classifyHealth(w.health, true);
            const cover = w.health.maintenanceMargin > 0n ? Number((w.health.equity * 100n) / w.health.maintenanceMargin) / 100 : undefined;
            return (
              <li key={w.accountId.toString()} className="grid grid-cols-[1fr_auto_auto] items-center gap-x-3 px-1.5 py-2 text-[13px]">
                <span className="flex items-center gap-1.5">
                  Account #{w.accountId.toString()} <Pill tone={v.tone}>{v.label}</Pill>
                </span>
                <span className="num text-right">{fmtQty(w.written)}</span>
                <span className="num text-right font-semibold" title="Account value divided by the liquidation line. Above 1× the account is safe from liquidation.">
                  {cover !== undefined ? `${cover.toFixed(cover >= 10 ? 0 : 1)}×` : "—"}
                </span>
              </li>
            );
          })}
        </ul>
        {b.writers.length > SHOWN_WRITERS && <p className="px-1.5 pt-1 text-xs text-muted">and {b.writers.length - SHOWN_WRITERS} more</p>}
        <p className="px-1.5 pt-1.5 text-xs text-muted">
          Collateral cover is the account's value divided by its liquidation line: 2× means it holds twice what it must keep.
        </p>
      </div>
    </div>
  );
}

function Fact({ label, value, sub, tone }: { label: React.ReactNode; value: React.ReactNode; sub?: string; tone?: string }) {
  return (
    <div className="rounded-xl border border-line bg-surface-2/60 px-3 py-2">
      <dt className="text-[11px] text-muted">{label}</dt>
      <dd className={`num mt-0.5 text-[15px] font-bold ${tone ?? ""}`}>{value}</dd>
      {sub && <dd className="text-[11px] text-muted">{sub}</dd>}
    </div>
  );
}
