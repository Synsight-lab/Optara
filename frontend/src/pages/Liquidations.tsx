/** `/liquidations`: accounts below MM, auctions, bonus and slice preview (FRONTEND.md §2, F12). */
import { useState } from "react";
import { Link } from "react-router";
import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { subAccountsAbi } from "@optara/sdk";
import {
  AlertTriangle,
  ArrowRight,
  Flame,
  HelpCircle,
  Percent,
  ShieldAlert,
  ShieldCheck,
  Sparkles,
  Zap,
} from "lucide-react";
import { Card, EmptyState, Pill, Row, Skeleton, Term, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { sliceSteps, startAuctionSteps } from "../lib/optara/actions.ts";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { fmtBps, fmtDuration, fmtNative, fmtWad } from "../lib/optara/format.ts";
import { useChainTime } from "../lib/optara/hooks.ts";
import { getAccountsWithPositions, getAuction, getHealth, getLiquidationParams, previewSlice } from "../lib/optara/reads.ts";
import { useAccountState, useQuickGuide } from "../state.tsx";

export function LiquidationsPage() {
  const { data, isLoading } = useQuery({
    queryKey: ["liquidatable"],
    queryFn: async () => {
      const ids = await getAccountsWithPositions();
      const hs = await Promise.all(ids.map(async (id) => ({ id, h: await getHealth(id) })));
      return hs
        .filter((x) => x.h.equity < x.h.maintenanceMargin)
        .sort((a, b) => (b.h.maintenanceMargin - b.h.equity > a.h.maintenanceMargin - a.h.equity ? 1 : -1));
    },
    refetchInterval: 10_000,
  });

  const { data: params } = useQuery({ queryKey: ["liqParams"], queryFn: getLiquidationParams });
  const { open: openGuide } = useQuickGuide();

  return (
    <div className="space-y-4 sm:space-y-5">
      <div className="flex flex-col justify-between gap-2 px-1 sm:flex-row sm:items-end">
        <div>
          <h1 className="font-display text-2xl font-bold tracking-tight sm:text-[28px]">Auctions</h1>
          <p className="mt-0.5 text-[13px] text-muted">
            Under-collateralized accounts sell slices at a growing discount. Anyone can take them.
          </p>
        </div>
        <button
          onClick={openGuide}
          className="flex items-center gap-1.5 text-xs text-primary font-semibold hover:underline"
        >
          <HelpCircle className="h-4 w-4" /> How auctions work
        </button>
      </div>

      {/* Liquidation Parameters Banner */}
      {params && (
        <div className="grid gap-2">
          <div className="rounded-2xl border border-line bg-surface-2/60 p-3.5">
            <span className="text-[13px] font-semibold text-muted">Discount bonus</span>
            <div className="num mt-1 text-base font-black text-good">
              {fmtBps(params.startBonusBps, 1)} → {fmtBps(params.maxBonusBps, 1)}
            </div>
            <span className="text-[11px] text-muted">Escalates over {fmtDuration(params.auctionDuration)}</span>
          </div>

          <div className="rounded-2xl border border-line bg-surface-2/60 p-3.5">
            <span className="text-[13px] font-semibold text-muted">Slice size</span>
            <div className="num mt-1 text-base font-black text-ink">
              {fmtBps(params.minSliceBps, 0)} to {fmtBps(params.maxSliceBps, 0)}
            </div>
            <span className="text-[11px] text-muted">Whole-bucket enabled after duration</span>
          </div>

          <div className="rounded-2xl border border-line bg-surface-2/60 p-3.5">
            <span className="text-[13px] font-semibold text-muted">Safety penalty</span>
            <div className="num mt-1 text-base font-black text-accent">
              {fmtBps(params.liquidationPenaltyBps, 1)}
            </div>
            <span className="text-[11px] text-muted">Directly funds the safety reserve</span>
          </div>
        </div>
      )}

      {/* Account Cards */}
      {isLoading ? (
        <Card><Skeleton className="h-32 w-full" /></Card>
      ) : !data?.length ? (
        <Card>
          <EmptyState
            icon="🛡️"
            title="All accounts are healthy"
            body="No account is below its liquidation threshold right now."
          />
        </Card>
      ) : (
        data.map((x) => (
          <AccountCard key={x.id.toString()} id={x.id} equity={x.h.equity} mm={x.h.maintenanceMargin} params={params} />
        ))
      )}
    </div>
  );
}

function AccountCard({
  id,
  equity,
  mm,
  params,
}: {
  id: bigint;
  equity: bigint;
  mm: bigint;
  params?: Awaited<ReturnType<typeof getLiquidationParams>>;
}) {
  const { selected } = useAccountState();
  const { data: now } = useChainTime();
  const { data: buckets } = useQuery({
    queryKey: ["buckets", id.toString()],
    queryFn: () => publicClient.readContract({ address: ADDR.ledger, abi: subAccountsAbi, functionName: "bucketsOf", args: [id] }),
  });

  return (
    <Card
      title={
        <div className="flex items-center gap-2">
          <span className="font-bold text-ink">Account #{id.toString()}</span>
          <Pill tone="bad" dot>Liquidatable</Pill>
        </div>
      }
    >
      <div className="flex flex-col gap-3">
        {/* Margin Deficit Info */}
        <div className="rounded-2xl border border-bad/30 bg-bad/5 p-4 space-y-1.5">
          <Row label="Equity" value={`$${fmtWad(equity)}`} tone="bad" />
          <Row label={<Term tip="Below this, the account can be liquidated.">Liquidation at</Term>} value={`$${fmtWad(mm)}`} />
          <Row strong label="Shortfall" value={`-$${fmtWad(mm - equity)}`} tone="bad" />

          <p className="text-[11px] text-muted mt-3 pt-2 border-t border-bad/20">
            Anyone can take a slice of this account to bring it back to health.
          </p>
        </div>

        {/* Buckets */}
        <div className="space-y-4">
          {(buckets ?? []).map((u) => (
            <Bucket key={u} id={id} underlying={u} liquidator={selected} params={params} now={now} />
          ))}
        </div>
      </div>
    </Card>
  );
}

function Bucket({
  id,
  underlying,
  liquidator,
  params,
  now,
}: {
  id: bigint;
  underlying: Address;
  liquidator?: bigint;
  params?: Awaited<ReturnType<typeof getLiquidationParams>>;
  now?: bigint;
}) {
  const { data: auction } = useQuery({
    queryKey: ["auction", id.toString(), underlying],
    queryFn: () => getAuction(id, underlying),
    refetchInterval: 5_000,
  });

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

  if (!auction) return <Skeleton className="h-24 w-full" />;

  if (auction.start === 0n) {
    return (
      <div className="rounded-2xl border border-line bg-surface-2/60 p-4">
        <p className="mb-3 text-xs text-muted">
          No auction running here yet. Starting one is open to anyone and starts the discount clock.
        </p>
        <TxButton label="Start auction" steps={startAuctionSteps(id, underlying)} successMessage="Auction started." />
      </div>
    );
  }

  const [sliceMark, sliceMM, discount, penalty, cash] = preview ?? [];

  return (
    <div className="rounded-2xl border border-primary/40 bg-surface-2/60 p-4 space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Pill tone="warn" dot>
            Live {now !== undefined ? `(${fmtDuration(now - auction.start)})` : ""}
          </Pill>
          <Pill tone="good">
            Discount +{fmtBps(auction.bonusBps, 2)}
          </Pill>
        </div>
        {auction.wholeBucket && <Pill tone="accent">Whole position</Pill>}
      </div>

      <div>
        <div className="flex items-center justify-between text-xs font-semibold">
          <label htmlFor={`slice-${id}`}>Slice to take:</label>
          <span className="num text-primary font-bold">{fmtBps(sliceBps, 0)}</span>
        </div>
        <input
          id={`slice-${id}`}
          type="range"
          className="mt-2 w-full accent-[var(--primary)] cursor-pointer"
          min={Number(minS)}
          max={Number(maxS)}
          step={100}
          value={sliceBps}
          onChange={(e) => setSlice(Number(e.target.value))}
        />
      </div>

      {/* Financial Preview */}
      <div className="rounded-xl border border-line bg-surface p-3 space-y-1 text-xs">
        <Row label={<Term tip="Value of the positions you receive.">Position Value</Term>} value={sliceMark !== undefined ? `$${fmtWad(sliceMark)}` : "—"} />
        <Row label="Margin freed" value={sliceMM !== undefined ? `$${fmtWad(sliceMM)}` : "—"} />
        <Row label="Your discount" value={discount !== undefined ? `+$${fmtWad(discount)}` : "—"} tone="good" />
        <Row label="Safety penalty" value={penalty !== undefined ? `$${fmtNative(penalty, 6)}` : "—"} />
        <Row
          strong
          label="You receive"
          value={cash !== undefined ? (cash >= 0n ? `+$${fmtNative(cash, 6)}` : `-$${fmtNative(-cash, 6)}`) : "—"}
          tone={cash !== undefined && cash >= 0n ? "good" : "bad"}
        />
      </div>

      <TxButton
        label="Take slice"
        steps={
          liquidator !== undefined && cash !== undefined
            ? sliceSteps(
                id,
                underlying,
                liquidator,
                sliceBps,
                cash > 0n ? (cash * 99n) / 100n : 0n,
                cash < 0n ? (-cash * 101n) / 100n : 0n
              )
            : undefined
        }
        disabled={liquidator === undefined || liquidator === id}
        disabledReason={
          liquidator === undefined
            ? "Create or select your own funded account in Portfolio first."
            : liquidator === id
            ? "You cannot liquidate your own account."
            : undefined
        }
        successMessage="Slice taken."
      />
    </div>
  );
}
