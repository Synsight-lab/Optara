import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router";
import { useOptara } from "../components/hooks.ts";
import { Card, StatusBadge } from "../components/common.tsx";
import { listSeries } from "../lib/optara/reads.ts";
import { formatExpiry, formatUnitsTrim, formatWad } from "../lib/optara/format.ts";
import { lifecycleOf } from "../lib/optara/lifecycle.ts";
import type { SeriesView } from "../lib/optara/types.ts";

/** Max contractual payout of one whole option in native units, rounded down for display (C * CS). */
export function maxPayoutPerOption(s: SeriesView): string {
  const n = (s.capWad * s.contractSizeWad) / 10n ** 18n; // WAD value of C * CS
  return `${formatWad(n)} ${s.assetSymbol}`;
}

export function MarketsPage() {
  const { client, manifest } = useOptara();
  const q = useQuery({ queryKey: ["series"], queryFn: () => listSeries(client, manifest) });
  if (q.isLoading) return <p className="text-slate-400">Loading series from chain…</p>;
  if (q.error) return <p className="text-red-400">Could not read series: {(q.error as Error).message}</p>;
  const series = q.data ?? [];
  const pairs = new Map<string, SeriesView[]>();
  for (const s of series) {
    const key = `${s.underlyingSymbol}/${s.assetSymbol} · ${formatExpiry(s.expiry)}`;
    pairs.set(key, [...(pairs.get(key) ?? []), s]);
  }
  return (
    <div className="space-y-6">
      <p className="text-sm text-slate-400">
        Capped European options. Each pair's stablecoin is its strike, cap, margin and settlement asset; the maximum
        payout is fixed when the series is created.
      </p>
      {series.length === 0 && <p className="text-slate-400">No series yet.</p>}
      {[...pairs.entries()].map(([key, list]) => (
        <Card key={key} title={key}>
          <table className="w-full text-sm">
            <thead className="text-left text-slate-500">
              <tr><th>Type</th><th>Strike</th><th>Cap</th><th>Contract</th><th>Max payout / option</th><th>Status</th><th /></tr>
            </thead>
            <tbody>
              {list.map((s) => (
                <tr key={s.seriesId} className="border-t border-slate-800">
                  <td>{s.optionType === 0 ? "Call" : "Put"}</td>
                  <td className="font-mono">{formatWad(s.strikeWad)}</td>
                  <td className="font-mono">{formatWad(s.capWad)}</td>
                  <td className="font-mono">{formatWad(s.contractSizeWad)} {s.underlyingSymbol}</td>
                  <td className="font-mono">{maxPayoutPerOption(s)}</td>
                  <td><StatusBadge lifecycle={lifecycleOf(s.status, s.oracleStalled, s.payoffPerUnderlyingWad)} /></td>
                  <td><Link className="text-indigo-400 hover:underline" to={`/series/${s.seriesId}`}>Open</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="mt-2 text-xs text-slate-500">Quantity increment: {formatUnitsTrim(list[0]!.quantityIncrement, 18)} option</p>
        </Card>
      ))}
    </div>
  );
}
