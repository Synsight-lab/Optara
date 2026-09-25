import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount } from "wagmi";
import { Link } from "react-router";
import type { Address } from "viem";
import { useOptara } from "../components/hooks.ts";
import { AmountInput, Card, Row } from "../components/common.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { getAccountRiskState, getPositions, listSeries, allowance, tokenBalance } from "../lib/optara/reads.ts";
import { buildApprove, buildDeposit, buildSyncAccount, buildWithdraw } from "../lib/optara/actions.ts";
import { formatUnitsTrim, formatWad } from "../lib/optara/format.ts";
import type { RiskStateView } from "../lib/optara/types.ts";

const STATUS = ["Normal", "Restricted — outflows paused", "Wind-down — outflows pay the recovery ratio"];

/** floor(rho * amount), what an outflow actually transfers after verified-shortfall resolution (MATH.md 119). */
export const scaleByRho = (amount: bigint, rhoWad: bigint): bigint => (amount * rhoWad) / 10n ** 18n;

/** Cure-deposit rule while restricted (PROTOCOL_SPEC.md section 10): only up to the account's deficit. */
export function depositLimit(r: RiskStateView): { allowed: boolean; max?: bigint; reason?: string } {
  if (r.assetStatus === 2) return { allowed: false, reason: "Deposits are permanently disabled for this asset on this core." };
  if (r.assetStatus === 1) {
    if (r.deficit === 0n) return { allowed: false, reason: "Asset restricted: only a cure deposit into an account below its requirement is accepted." };
    return { allowed: true, max: r.deficit, reason: "Asset restricted: cure deposit up to your deficit only." };
  }
  return { allowed: true };
}

function AssetCard({ r }: { r: RiskStateView }) {
  const { client, manifest } = useOptara();
  const { address } = useAccount();
  const [dep, setDep] = useState<bigint>();
  const [wd, setWd] = useState<bigint>();
  const allow = useQuery({
    queryKey: ["allowance", r.asset, address],
    enabled: !!address,
    queryFn: () => allowance(client, r.asset, address!, manifest.contracts.OptaraCore),
  });
  const wallet = useQuery({ queryKey: ["wallet", r.asset, address], enabled: !!address, queryFn: () => tokenBalance(client, r.asset, address!) });
  const fmt = (v: bigint) => `${formatUnitsTrim(v, r.assetDecimals)} ${r.assetSymbol}`;
  const limit = depositLimit(r);
  const depOk = !!dep && limit.allowed && (limit.max === undefined || dep <= limit.max);
  const needsApprove = !!dep && (allow.data ?? 0n) < dep;
  return (
    <Card title={r.assetSymbol}>
      <Row k="Status" v={STATUS[r.assetStatus]} />
      <Row k="Cash (ledger)" v={fmt(r.cash)} />
      <Row k="Effective cash (incl. matured, unsynced groups)" v={fmt(r.effectiveCash)} />
      <Row k="Required margin" v={fmt(r.requiredMargin)} />
      <Row k="Free collateral" v={fmt(r.freeCollateral)} />
      {r.deficit > 0n && <Row k="Deficit" v={<span className="text-red-400">{fmt(r.deficit)}</span>} />}
      {r.assetStatus === 2 && <Row k="Recovery ratio" v={formatWad(r.rhoWad)} />}
      <Row k="Wallet balance" v={wallet.data !== undefined ? fmt(wallet.data) : "…"} />
      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        <div className="space-y-2">
          <AmountInput label={`Deposit ${r.assetSymbol}`} decimals={r.assetDecimals} onChange={setDep} />
          {limit.reason && <p className="text-xs text-amber-300">{limit.reason}</p>}
          <TxButton
            disabled={!depOk}
            steps={dep && depOk ? [
              ...(needsApprove ? [{ label: "Approve exact", request: buildApprove(r.asset, manifest.contracts.OptaraCore, dep) }] : []),
              { label: "Deposit", request: buildDeposit(manifest, r.asset, dep) },
            ] : []}
          />
        </div>
        <div className="space-y-2">
          <AmountInput label={`Withdraw ${r.assetSymbol}`} decimals={r.assetDecimals} onChange={setWd} />
          {r.assetStatus === 2 && wd !== undefined && (
            <p className="text-xs text-amber-300">
              Wind-down: debits {fmt(wd)} and transfers {fmt(scaleByRho(wd, r.rhoWad))} (recovery ratio, rounded down).
            </p>
          )}
          <TxButton
            disabled={!wd || r.assetStatus === 1 || wd > r.freeCollateral}
            steps={wd && address ? [{ label: "Withdraw", request: buildWithdraw(manifest, r.asset, wd, address) }] : []}
          />
          {r.hasUnsyncedMaturedGroups && (
            <TxButton steps={address ? [{ label: "Sync matured groups", request: buildSyncAccount(manifest, address, r.asset) }] : []} />
          )}
        </div>
      </div>
    </Card>
  );
}

export function PortfolioPage() {
  const { client, manifest } = useOptara();
  const { address } = useAccount();
  const risk = useQuery({
    queryKey: ["risk", address],
    enabled: !!address,
    queryFn: () => Promise.all(manifest.assets.map((a: Address) => getAccountRiskState(client, manifest, address!, a))),
  });
  const positions = useQuery({ queryKey: ["positions", address], enabled: !!address, queryFn: () => getPositions(client, manifest, address!) });
  const series = useQuery({ queryKey: ["series"], queryFn: () => listSeries(client, manifest) });
  const longs = useQuery({
    queryKey: ["longs", address, series.data?.length],
    enabled: !!address && !!series.data,
    queryFn: async () => {
      const out = await Promise.all(series.data!.map(async (s) => ({ s, bal: await tokenBalance(client, s.optionToken, address!) })));
      return out.filter((x) => x.bal > 0n);
    },
  });
  if (!address) return <p className="text-slate-400">Connect a wallet to see your Optara account.</p>;
  const byId = new Map(series.data?.map((s) => [s.seriesId.toLowerCase(), s]));
  return (
    <div className="space-y-4">
      <div className="grid gap-4 md:grid-cols-2">{risk.data?.map((r) => <AssetCard key={r.asset} r={r} />)}</div>
      <Card title="Positions (shorts and locked hedges)">
        {positions.data?.length ? (
          <table className="w-full text-sm">
            <thead className="text-left text-slate-500"><tr><th>Series</th><th>Short</th><th>Locked</th></tr></thead>
            <tbody>
              {positions.data.map((p) => (
                <tr key={p.seriesId} className="border-t border-slate-800">
                  <td><Link className="text-indigo-400" to={`/series/${p.seriesId}`}>{byId.get(p.seriesId.toLowerCase())?.tokenSymbol ?? p.seriesId}</Link></td>
                  <td className="font-mono">{formatUnitsTrim(p.shortQty, 18)}</td>
                  <td className="font-mono">{formatUnitsTrim(p.lockedQty, 18)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <p className="text-sm text-slate-400">No open positions.</p>}
      </Card>
      <Card title="Long tokens in your wallet">
        {longs.data?.length ? longs.data.map(({ s, bal }) => (
          <Row key={s.seriesId} k={s.tokenSymbol} v={<Link className="text-indigo-400" to={`/series/${s.seriesId}`}>{formatUnitsTrim(bal, 18)}</Link>} />
        )) : <p className="text-sm text-slate-400">None.</p>}
      </Card>
    </div>
  );
}
