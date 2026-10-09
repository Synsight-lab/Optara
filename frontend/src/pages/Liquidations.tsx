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
import { sliceSteps, startAuctionSteps, wrapperLiquidationSteps } from "../lib/optara/actions.ts";
import { lessSlip, useSlippage, withSlip } from "../lib/optara/limits.ts";
import { AuctionNotice } from "../components/AuctionNotice.tsx";
import { AmountInput } from "../components/ui.tsx";
import { LimitsPanel } from "../components/LimitsPanel.tsx";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { fmtBps, fmtDuration, fmtNative, fmtQty, fmtWad, parseQty, seriesName } from "../lib/optara/format.ts";
import { useAccountView, useChainTime, useSeriesList, useWalletWrappers } from "../lib/optara/hooks.ts";
import { getAccountsWithPositions, getAuction, getHealth, getLiquidationParams, getRunningAuctions, getSeriesMarket, previewSlice } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { useConnection } from "wagmi";
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
            <span className="text-[11px] text-muted">Of the slice's margin. Grows over {fmtDuration(params.auctionDuration)} after an auction starts.</span>
          </div>

          <div className="rounded-2xl border border-line bg-surface-2/60 p-3.5">
            <span className="text-[13px] font-semibold text-muted">Slice size</span>
            <div className="num mt-1 text-base font-black text-ink">
              {fmtBps(params.minSliceBps, 0)} to {fmtBps(params.maxSliceBps, 0)}
            </div>
            <span className="text-[11px] text-muted">Share of the account per liquidation. After {fmtDuration(params.auctionDuration)}, all of it can be taken.</span>
          </div>

          <div className="rounded-2xl border border-line bg-surface-2/60 p-3.5">
            <span className="text-[13px] font-semibold text-muted">Penalty to insurance</span>
            <div className="num mt-1 text-base font-black text-accent">
              {fmtBps(params.liquidationPenaltyBps, 1)}
            </div>
            <span className="text-[11px] text-muted">Of the slice's margin, paid by the liquidated account into the insurance fund.</span>
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

      <RecoveredAuctions liquidatable={new Set((data ?? []).map((x) => x.id.toString()))} />
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
          <Row label={<Term tip="Cash plus the value of the account's positions.">Account value</Term>} value={`$${fmtWad(equity)}`} tone="bad" />
          <Row label={<Term tip="Below this account value, anyone can liquidate.">Liquidation line</Term>} value={`$${fmtWad(mm)}`} />
          <Row strong label="Below the line by" value={`$${fmtWad(mm - equity)}`} tone="bad" />

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

function Bucket(props: {
  id: bigint;
  underlying: Address;
  liquidator?: bigint;
  params?: Awaited<ReturnType<typeof getLiquidationParams>>;
  now?: bigint;
}) {
  return (
    <div className="space-y-3">
      <SliceBucket {...props} />
      <WrapperLiquidation id={props.id} underlying={props.underlying} liquidator={props.liquidator} />
    </div>
  );
}

function SliceBucket({
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
  const [slip] = useSlippage();
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
        <Row label={<Term tip="Fair value of the positions your account takes over (negative when they are mostly written options).">Positions you take over</Term>} value={sliceMark !== undefined ? `$${fmtWad(sliceMark)}` : "—"} />
        <Row label={<Term tip="How much of the liquidated account's requirement this slice removes.">Margin removed from the account</Term>} value={sliceMM !== undefined ? `$${fmtWad(sliceMM)}` : "—"} />
        <Row label="Your bonus" value={discount !== undefined ? `+$${fmtWad(discount)}` : "—"} tone="good" />
        <Row label="Penalty to insurance (paid by the account)" value={penalty !== undefined ? `$${fmtNative(penalty, 6)}` : "—"} />
        <Row
          strong
          label={cash !== undefined && cash < 0n ? "Cash you pay" : "Cash you receive"}
          value={cash !== undefined ? `$${fmtNative(cash >= 0n ? cash : -cash, 6)}` : "—"}
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
                cash > 0n ? lessSlip(cash, slip) : 0n,
                cash < 0n ? withSlip(-cash, slip) : 0n
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

/**
 * Liquidate by handing in option tokens (LiquidationModule.liquidateWithWrapper): tokens of an option this account
 * wrote cancel that much of its liability, and the account pays you at least their fair value plus the auction bonus.
 */
function WrapperLiquidation({ id, underlying, liquidator }: { id: bigint; underlying: Address; liquidator?: bigint }) {
  const { address } = useConnection();
  const { data: series } = useSeriesList();
  const { data: account } = useAccountView(id);
  const { data: wallet } = useWalletWrappers(address);
  const shorts = (account?.positions ?? []).filter((p) => p.balance < 0n && p.series.underlying.toLowerCase() === underlying.toLowerCase());
  if (!shorts.length || !series) return null;
  const held = shorts
    .map((p) => ({ s: p.series, short: -p.balance, have: wallet?.find((w) => w.series.id === p.seriesId)?.balance ?? 0n }))
    .sort((a, b) => (a.have > b.have ? -1 : 1));

  return (
    <div className="rounded-2xl border border-line bg-surface-2/60 p-4 text-[13px]">
      <div className="font-semibold">Or hand in option tokens</div>
      <p className="mt-0.5 text-xs leading-relaxed text-muted">
        Tokens of an option this account wrote cancel that much of what it owes. The account pays you their fair value plus
        the auction bonus. Nothing moves into your own account.
      </p>
      <ul className="mt-2.5 space-y-2.5">
        {held.map((h) => (
          <WrapperRow key={h.s.id} id={id} s={h.s} short={h.short} have={h.have} liquidator={liquidator} />
        ))}
      </ul>
    </div>
  );
}

function WrapperRow({ id, s, short, have, liquidator }: { id: bigint; s: Series; short: bigint; have: bigint; liquidator?: bigint }) {
  const [slip] = useSlippage();
  const max = have < short ? have : short;
  const [amount, setAmount] = useState("");
  const qty = parseQty(amount);
  const { data: m } = useQuery({ queryKey: ["seriesMarket", s.id], queryFn: () => getSeriesMarket(s), refetchInterval: 10_000 });
  // The least the account pays: the burned options' fair value (the bonus comes on top).
  const fair = qty && m?.mark !== undefined ? (qty * m.mark) / 10n ** 18n / 10n ** BigInt(18 - s.assetDecimals) : undefined;
  const minCash = fair !== undefined ? lessSlip(fair, slip) : undefined;
  const tooMuch = qty !== undefined && qty > max;

  return (
    <li className="rounded-xl border border-line bg-surface p-3">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <span className="font-semibold">{seriesName(s)}</span>
        <span className="text-xs text-muted">
          account wrote {fmtQty(short)} · you hold {fmtQty(have)}
        </span>
      </div>
      {have === 0n ? (
        <p className="mt-1 text-xs text-muted">
          You hold none.{" "}
          <Link to={`/series/${s.id}?tab=trade`} className="font-semibold text-primary">
            Buy some
          </Link>{" "}
          to use this route.
        </p>
      ) : (
        <div className="mt-2 space-y-2">
          <AmountInput label="Options to hand in" value={amount} onChange={setAmount} unit="options" max={fmtQty(max)} maxLabel="Max" invalid={tooMuch ? `At most ${fmtQty(max)}.` : undefined} />
          <Row label="You receive at least" value={fair !== undefined ? `${fmtNative(fair, s.assetDecimals)} ${s.assetSymbol} + bonus` : "—"} tone="good" />
          <LimitsPanel limits={minCash !== undefined ? [{ label: "Least cash accepted", value: `${fmtNative(minCash, s.assetDecimals)} ${s.assetSymbol}`, tip: "If the account would pay you less than this, nothing happens." }] : []} />
          <TxButton
            label="Hand in and get paid"
            steps={liquidator !== undefined && qty && minCash !== undefined && !tooMuch ? wrapperLiquidationSteps(id, s, qty, liquidator, minCash) : undefined}
            disabled={liquidator === undefined || liquidator === id || !qty || tooMuch}
            disabledReason={liquidator === undefined ? "Create or select your own account in Portfolio first: the payment goes there." : liquidator === id ? "You cannot liquidate your own account." : undefined}
            successMessage="Liquidated: the account paid you for the options you handed in."
          />
        </div>
      )}
    </li>
  );
}

/** Auctions still running on accounts that have recovered: anyone can end them. */
function RecoveredAuctions({ liquidatable }: { liquidatable: Set<string> }) {
  const { data: series } = useSeriesList();
  const { data } = useQuery({ queryKey: ["runningAuctions"], queryFn: getRunningAuctions, refetchInterval: 15_000 });
  const rows = (data ?? []).filter((a) => !liquidatable.has(a.accountId.toString()));
  if (!rows.length) return null;
  const sym = (u: string) => series?.find((s) => s.underlying.toLowerCase() === u.toLowerCase())?.underlyingSymbol ?? "?";
  return (
    <section className="space-y-2">
      <h2 className="label px-1">Auctions on recovered accounts · {rows.length}</h2>
      {rows.map((a) => (
        <AuctionNotice key={`${a.accountId}:${a.underlying}`} accountId={a.accountId} underlying={a.underlying} symbol={sym(a.underlying)} mine={false} />
      ))}
    </section>
  );
}
