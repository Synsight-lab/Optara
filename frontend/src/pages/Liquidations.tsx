/** `/liquidations`: accounts below MM, auctions, bonus and slice preview (FRONTEND.md §2, F12). */
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { subAccountsAbi } from "@optara/sdk";
import { Card, EmptyState, Pill, Row, Skeleton, Term } from "../components/ui.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { sliceSteps, startAuctionSteps } from "../lib/optara/actions.ts";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { fmtBps, fmtDuration, fmtNative, fmtWad } from "../lib/optara/format.ts";
import { useChainTime } from "../lib/optara/hooks.ts";
import { getAccountsWithPositions, getAuction, getHealth, getLiquidationParams, previewSlice } from "../lib/optara/reads.ts";
import { useAccountState } from "../state.tsx";

export function LiquidationsPage() {
  const { data, isLoading } = useQuery({
    queryKey: ["liquidatable"],
    queryFn: async () => {
      const ids = await getAccountsWithPositions();
      const hs = await Promise.all(ids.map(async (id) => ({ id, h: await getHealth(id) })));
      return hs.filter((x) => x.h.equity < x.h.maintenanceMargin).sort((a, b) => (b.h.maintenanceMargin - b.h.equity > a.h.maintenanceMargin - a.h.equity ? 1 : -1));
    },
    refetchInterval: 10_000,
  });
  const { data: params } = useQuery({ queryKey: ["liqParams"], queryFn: getLiquidationParams });
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Liquidations</h1>
        <p className="text-sm text-muted">
          Accounts below maintenance margin are auctioned in slices. The liquidator takes a share of the positions plus a bonus that grows over the auction. Use your own funded account.
        </p>
      </div>
      {params && (
        <div className="flex flex-wrap gap-2 text-xs">
          <Pill tone="primary">Bonus {fmtBps(params.startBonusBps, 1)} → {fmtBps(params.maxBonusBps, 1)} over {fmtDuration(params.auctionDuration)}</Pill>
          <Pill tone="primary">Slices {fmtBps(params.minSliceBps, 0)}–{fmtBps(params.maxSliceBps, 0)}</Pill>
          <Pill tone="primary">Penalty to insurance {fmtBps(params.liquidationPenaltyBps, 1)}</Pill>
        </div>
      )}
      {isLoading ? (
        <Card><Skeleton className="h-32 w-full" /></Card>
      ) : !data?.length ? (
        <Card><EmptyState icon="✓" title="No accounts below maintenance margin" body="Every account with positions currently has enough margin." /></Card>
      ) : (
        data.map((x) => <AccountCard key={x.id.toString()} id={x.id} equity={x.h.equity} mm={x.h.maintenanceMargin} params={params} />)
      )}
    </div>
  );
}

function AccountCard({ id, equity, mm, params }: { id: bigint; equity: bigint; mm: bigint; params?: Awaited<ReturnType<typeof getLiquidationParams>> }) {
  const { selected } = useAccountState();
  const { data: now } = useChainTime();
  const { data: buckets } = useQuery({ queryKey: ["buckets", id.toString()], queryFn: () => publicClient.readContract({ address: ADDR.ledger, abi: subAccountsAbi, functionName: "bucketsOf", args: [id] }) });
  return (
    <Card title={<span className="flex items-center gap-2">Account #{id.toString()} <Pill tone="bad" dot>Liquidatable</Pill></span>}>
      <div className="grid gap-6 md:grid-cols-[260px_1fr]">
        <div>
          <Row label="Equity" value={fmtWad(equity)} tone="bad" />
          <Row label={<Term tip="Maintenance margin. Below it the account can be liquidated.">MM</Term>} value={fmtWad(mm)} />
          <Row strong label="Shortfall" value={fmtWad(mm - equity)} tone="bad" />
        </div>
        <div className="space-y-4">
          {(buckets ?? []).map((u) => (
            <Bucket key={u} id={id} underlying={u} liquidator={selected} params={params} now={now} />
          ))}
        </div>
      </div>
    </Card>
  );
}

function Bucket({ id, underlying, liquidator, params, now }: { id: bigint; underlying: Address; liquidator?: bigint; params?: Awaited<ReturnType<typeof getLiquidationParams>>; now?: bigint }) {
  const { data: auction } = useQuery({ queryKey: ["auction", id.toString(), underlying], queryFn: () => getAuction(id, underlying), refetchInterval: 5_000 });
  const minS = params?.minSliceBps ?? 500;
  const maxS = auction?.wholeBucket ? 10_000 : params?.maxSliceBps ?? 2500;
  const [slice, setSlice] = useState(Number(maxS));
  const sliceBps = Math.min(Math.max(slice, Number(minS)), Number(maxS));
  const { data: preview } = useQuery({
    queryKey: ["previewSlice", id.toString(), underlying, sliceBps],
    queryFn: () => previewSlice(id, underlying, sliceBps),
    enabled: !!auction && auction.start !== 0n,
    refetchInterval: 5_000,
  });
  if (!auction) return <Skeleton className="h-20 w-full" />;
  if (auction.start === 0n) {
    return (
      <div className="rounded-xl border border-line p-4">
        <p className="mb-3 text-sm text-muted">No auction yet. Starting one is permissionless and begins the bonus clock.</p>
        <TxButton label="Start auction" steps={startAuctionSteps(id, underlying)} successMessage="Auction started" />
      </div>
    );
  }
  const [sliceMark, sliceMM, discount, penalty, cash] = preview ?? [];
  return (
    <div className="rounded-xl border border-primary/40 p-4">
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <Pill tone="warn" dot>Auction running {now !== undefined ? fmtDuration(now - auction.start) : ""}</Pill>
        <Pill tone="primary">Bonus now {fmtBps(auction.bonusBps, 2)}</Pill>
        {auction.wholeBucket && <Pill tone="accent">Whole bucket allowed</Pill>}
      </div>
      <label className="label" htmlFor={`slice-${id}`}>Slice: {fmtBps(sliceBps, 0)} of the positions</label>
      <input id={`slice-${id}`} type="range" className="mt-2 w-full accent-[var(--primary)]" min={Number(minS)} max={Number(maxS)} step={100} value={sliceBps} onChange={(e) => setSlice(Number(e.target.value))} />
      <div className="mt-3 rounded-xl bg-surface-2 p-3">
        <Row label={<Term tip="Value of the positions you take over (negative: liabilities you take on).">Positions' value</Term>} value={sliceMark !== undefined ? fmtWad(sliceMark) : "—"} />
        <Row label="Margin they release" value={sliceMM !== undefined ? fmtWad(sliceMM) : "—"} />
        <Row label="Your bonus" value={discount !== undefined ? fmtWad(discount) : "—"} tone="good" />
        <Row label="Penalty to insurance" value={penalty !== undefined ? fmtNative(penalty, 6) : "—"} />
        <Row strong label="Cash to you" value={cash !== undefined ? fmtNative(cash, 6) : "—"} tone={cash !== undefined && cash >= 0n ? "good" : "bad"} />
      </div>
      <div className="mt-3">
        <TxButton
          label="Take this slice"
          steps={liquidator !== undefined && cash !== undefined ? sliceSteps(id, underlying, liquidator, sliceBps, cash > 0n ? (cash * 99n) / 100n : 0n, cash < 0n ? (-cash * 101n) / 100n : 0n) : undefined}
          disabled={liquidator === undefined || liquidator === id}
          disabledReason={liquidator === undefined ? "Select or create your own funded account in Portfolio first." : liquidator === id ? "You can't liquidate your own account." : undefined}
          successMessage="Slice taken"
        />
      </div>
    </div>
  );
}
