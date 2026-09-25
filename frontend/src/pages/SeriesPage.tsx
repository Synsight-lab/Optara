import { useState } from "react";
import { useParams } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { useAccount } from "wagmi";
import type { Hex } from "viem";
import { useOptara } from "../components/hooks.ts";
import { AmountInput, Card, LivenessGate, Row, StatusBadge } from "../components/common.tsx";
import { TxButton, type TxStep } from "../components/TxButton.tsx";
import { getSeries, getSettlementSchedule, previewWrite, previewRedeem, tokenBalance, allowance } from "../lib/optara/reads.ts";
import {
  buildApprove, buildCancelUnfinalizedShort, buildCloseShort, buildLockLong, buildRedeem, buildSyncRiskGroup,
  buildUnlockLong, buildWrite, CloseSource,
} from "../lib/optara/actions.ts";
import { closeActionFor, lifecycleOf } from "../lib/optara/lifecycle.ts";
import { formatExpiry, formatUnitsTrim, formatWad } from "../lib/optara/format.ts";
import { optaraCoreAbi } from "../lib/optara/abi.ts";
import { INDEXER_URL } from "../config/networks.ts";
import { fetchVerifiedMarkets } from "../lib/optara/indexer.ts";
import { maxPayoutPerOption } from "./Markets.tsx";

export function SeriesPage() {
  const { seriesId } = useParams() as { seriesId: Hex };
  const { client, manifest } = useOptara();
  const { address } = useAccount();
  const s = useQuery({ queryKey: ["series", seriesId], queryFn: () => getSeries(client, manifest, seriesId) });
  const holdings = useQuery({
    queryKey: ["holdings", seriesId, address],
    enabled: !!address && !!s.data,
    queryFn: async () => {
      const [wallet, pos, custodyAllowance] = await Promise.all([
        tokenBalance(client, s.data!.optionToken, address!),
        client.readContract({ address: manifest.contracts.OptaraCore, abi: optaraCoreAbi, functionName: "positionOf", args: [address!, seriesId] }),
        allowance(client, s.data!.optionToken, address!, manifest.contracts.OptaraCore),
      ]);
      return { wallet, shortQty: pos.shortQty, lockedQty: pos.lockedQty, custodyAllowance };
    },
  });
  const markets = useQuery({ queryKey: ["markets"], enabled: !!INDEXER_URL, queryFn: () => fetchVerifiedMarkets(INDEXER_URL!) });
  const schedule = useQuery({
    queryKey: ["schedule", seriesId],
    enabled: !!s.data,
    queryFn: () => getSettlementSchedule(client, manifest, s.data!),
  });

  if (s.isLoading) return <p className="text-slate-400">Loading…</p>;
  if (s.error || !s.data) return <p className="text-red-400">Unknown series.</p>;
  const series = s.data;
  const life = lifecycleOf(series.status, series.oracleStalled, series.payoffPerUnderlyingWad);
  const market = markets.data?.find((m) => m.seriesId.toLowerCase() === seriesId.toLowerCase());

  return (
    <div className="grid gap-4 md:grid-cols-2">
      <Card title={series.tokenSymbol}>
        <div className="mb-2"><StatusBadge lifecycle={life} /></div>
        <Row k="Pair" v={`${series.underlyingSymbol} / ${series.assetSymbol}`} />
        <Row k="Type" v={series.optionType === 0 ? "Capped call" : "Capped put"} />
        <Row k="Strike" v={`${formatWad(series.strikeWad)} ${series.assetSymbol}`} />
        <Row k="Payout cap per underlying" v={`${formatWad(series.capWad)} ${series.assetSymbol}`} />
        <Row k="Contract size" v={`${formatWad(series.contractSizeWad)} ${series.underlyingSymbol}`} />
        <Row k="Max payout per option" v={maxPayoutPerOption(series)} />
        <Row k="Expiry" v={formatExpiry(series.expiry)} />
        <Row k="Settlement asset" v={series.assetSymbol} />
        {schedule.data && life.kind !== "SETTLED" && (
          <>
            <Row k="Price observation window" v={`${formatExpiry(schedule.data.observationStart)} → ${formatExpiry(schedule.data.observationEnd)}`} />
            <Row k="Earliest finalization" v={formatExpiry(schedule.data.earliestFinalization)} />
            <Row k="Escalation deadline (ORACLE_STALLED after)" v={formatExpiry(schedule.data.escalationDeadline)} />
          </>
        )}
        {life.kind === "SETTLED" && (
          <>
            <Row k="Settlement price" v={`${formatWad(series.settlementPriceWad ?? 0n)} ${series.assetSymbol}`} />
            <Row k="Payoff per underlying" v={`${formatWad(life.payoffPerUnderlyingWad)} ${series.assetSymbol}`} />
          </>
        )}
        {life.kind === "ORACLE_STALLED" && (
          <p className="mt-2 text-xs text-red-300">
            No valid observation by the escalation deadline. Claims stay backed; a late authentic observation can still
            finalize. You can cancel a short against an identical long or unlock a hedge if your account stays safe.
          </p>
        )}
      </Card>

      {address && holdings.data && (
        <Card title="Your position">
          <Row k="Long tokens in wallet" v={formatUnitsTrim(holdings.data.wallet, 18)} />
          <Row k="Short (written)" v={formatUnitsTrim(holdings.data.shortQty, 18)} />
          <Row k="Locked hedge" v={formatUnitsTrim(holdings.data.lockedQty, 18)} />
          <PositionActions seriesId={seriesId} life={life} holdings={holdings.data} groupId={series.groupId} optionToken={series.optionToken} assetDecimals={series.assetDecimals} assetSymbol={series.assetSymbol} />
        </Card>
      )}

      {life.kind === "ACTIVE" && <WriteCard seriesId={seriesId} />}

      <Card title="Buy or sell the long">
        <LivenessGate>
          {market ? (
            <p className="text-sm">Verified market: <span className="font-mono">{market.market}</span> (base = this option token, quote = {series.assetSymbol}).</p>
          ) : (
            <p className="text-sm text-slate-400">No verified secondary market is listed for this series. The long is a standard ERC-20 ({series.optionToken}).</p>
          )}
        </LivenessGate>
      </Card>
    </div>
  );
}

function WriteCard({ seriesId }: { seriesId: Hex }) {
  const { client, manifest } = useOptara();
  const { address } = useAccount();
  const [qty, setQty] = useState<bigint>();
  const s = useQuery({ queryKey: ["series", seriesId], queryFn: () => getSeries(client, manifest, seriesId) });
  const preview = useQuery({
    queryKey: ["previewWrite", seriesId, address, qty?.toString()],
    enabled: !!address && !!qty && !!s.data,
    queryFn: () => previewWrite(client, manifest, address!, s.data!, qty!),
  });
  if (!s.data) return null;
  const d = s.data.assetDecimals;
  return (
    <Card title="Write (sell) this option">
      <p className="mb-2 text-xs text-slate-400">
        Writing records a short in your Optara account and mints the same quantity of long tokens to you. Margin is the
        exact worst-case loss of your whole risk group, in {s.data.assetSymbol}; no premium is assumed.
      </p>
      <LivenessGate role="writer">
      <AmountInput label="Quantity (options)" decimals={18} onChange={setQty} />
      {preview.data && (
        <div className="mt-2">
          <Row k="Max liability of this write" v={`${formatUnitsTrim(preview.data.maxPayoutNative, d)} ${s.data.assetSymbol}`} />
          <Row k="Required margin after write" v={`${formatUnitsTrim(preview.data.requiredAfter, d)} ${s.data.assetSymbol}`} />
          <Row k="Additional deposit needed" v={`${formatUnitsTrim(preview.data.additionalCollateral, d)} ${s.data.assetSymbol}`} />
        </div>
      )}
      <div className="mt-3">
        <TxButton
          disabled={!qty || !address || (preview.data?.additionalCollateral ?? 0n) > 0n}
          steps={qty && address ? [{ label: "Write", request: buildWrite(manifest, seriesId, qty, address) }] : []}
        />
        {(preview.data?.additionalCollateral ?? 0n) > 0n && <p className="mt-1 text-xs text-amber-300">Deposit the additional margin on the Portfolio page first.</p>}
      </div>
      </LivenessGate>
    </Card>
  );
}

function PositionActions({ seriesId, life, holdings, groupId, optionToken, assetDecimals, assetSymbol }: {
  seriesId: Hex; groupId: Hex; optionToken: `0x${string}`; assetDecimals: number; assetSymbol: string;
  life: ReturnType<typeof lifecycleOf>;
  holdings: { wallet: bigint; shortQty: bigint; lockedQty: bigint; custodyAllowance: bigint };
}) {
  const { client, manifest } = useOptara();
  const { address } = useAccount();
  const [qty, setQty] = useState<bigint>();
  const action = closeActionFor(life);
  const redeemPreview = useQuery({
    queryKey: ["previewRedeem", seriesId, qty?.toString()],
    enabled: life.kind === "SETTLED" && !!qty,
    queryFn: () => previewRedeem(client, manifest, seriesId, qty!),
  });
  if (!address) return null;
  const steps: { title: string; list: TxStep[] }[] = [];
  if (qty) {
    if (action === "closeShort") {
      steps.push({ title: "Close short with wallet longs", list: [{ label: "Close (wallet)", request: buildCloseShort(manifest, seriesId, qty, CloseSource.EXTERNAL) }] });
      steps.push({ title: "Close short with your locked hedge", list: [{ label: "Close (locked)", request: buildCloseShort(manifest, seriesId, qty, CloseSource.LOCKED) }] });
    }
    if (action === "cancelUnfinalizedShort") {
      steps.push({ title: "Cancel short against wallet longs (no cash payoff)", list: [{ label: "Cancel (wallet)", request: buildCancelUnfinalizedShort(manifest, seriesId, qty, CloseSource.EXTERNAL) }] });
      steps.push({ title: "Cancel short against your locked hedge", list: [{ label: "Cancel (locked)", request: buildCancelUnfinalizedShort(manifest, seriesId, qty, CloseSource.LOCKED) }] });
    }
    if (action === "redeemAndSync") {
      steps.push({ title: "Redeem wallet longs", list: [{ label: "Redeem", request: buildRedeem(manifest, seriesId, qty, address) }] });
    }
    if (life.kind === "ACTIVE") {
      const needsApprove = holdings.custodyAllowance < qty;
      steps.push({
        title: "Lock longs as a hedge",
        list: [
          ...(needsApprove ? [{ label: "Approve exact", request: buildApprove(optionToken, manifest.contracts.OptaraCore, qty) }] : []),
          { label: "Lock", request: buildLockLong(manifest, seriesId, qty) },
        ],
      });
    }
    if (life.kind !== "SETTLED") {
      steps.push({ title: "Unlock hedge (checked against your full margin)", list: [{ label: "Unlock", request: buildUnlockLong(manifest, seriesId, qty, address) }] });
    }
  }
  return (
    <div className="mt-3 space-y-2">
      <AmountInput label="Quantity (options)" decimals={18} onChange={setQty} />
      {redeemPreview.data && <Row k="Redemption pays" v={`${formatUnitsTrim(redeemPreview.data.paid, assetDecimals)} ${assetSymbol}`} />}
      {steps.map((s) => (
        <div key={s.title} className="flex items-center justify-between gap-2 text-sm">
          <span className="text-slate-400">{s.title}</span>
          <TxButton steps={s.list} />
        </div>
      ))}
      {life.kind === "SETTLED" && (holdings.shortQty > 0n || holdings.lockedQty > 0n) && (
        <div className="flex items-center justify-between text-sm">
          <span className="text-slate-400">Settle your whole risk group (one net cash delta)</span>
          <TxButton steps={[{ label: "Sync group", request: buildSyncRiskGroup(manifest, address, groupId) }]} />
        </div>
      )}
      <p className="text-xs text-slate-500">Buying the long elsewhere does not close your short until you close it here.</p>
    </div>
  );
}
