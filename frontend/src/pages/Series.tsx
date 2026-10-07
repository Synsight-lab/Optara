/** `/series/:id` (and `/trade/:id`): terms, payoff, market and every action on one series (FRONTEND.md §2, §4, §7). */
import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import type { Hex } from "viem";
import { settlementWindowAbi } from "@optara/sdk";
import { AmountInput, Card, CopyButton, EmptyState, Pill, Row, Segmented, Skeleton, Stat, Term, cx, useTicker } from "../components/ui.tsx";
import { PayoffChart } from "../components/PayoffChart.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { availability, type ActionContext, type ActionKey } from "../lib/optara/availability.ts";
import {
  buySteps,
  closeShortSteps,
  mintSteps,
  redeemSteps,
  claimSteps,
  sellSteps,
  setupAccountSteps,
  unwrapSteps,
  wrapSteps,
} from "../lib/optara/actions.ts";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { disclosuresFor } from "../lib/optara/disclosures.ts";
import { fmtDuration, fmtExpiry, fmtIv, fmtNative, fmtPrice, fmtQty, fmtWad, optionTypeName, parseFixed, parseQty, shortAddr, WAD } from "../lib/optara/format.ts";
import { useAccountView, useChainTime, useProductMarket, useSeries, useSeriesMarket, useTokenBalance, useWalletWrappers } from "../lib/optara/hooks.ts";
import { kuruSellFee, kuruTakerFee, previewBuyerFee, previewMint, previewRedeem } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { useAccountState } from "../state.tsx";
import { HealthBar } from "../components/HealthBar.tsx";

type Tab = "buy" | "write" | "sell" | "manage" | "redeem";
const SLIPPAGE_BPS = 100n; // FRONTEND.md §7: 1% default
const withSlip = (x: bigint) => (x * (10_000n + SLIPPAGE_BPS)) / 10_000n + 1n;
const lessSlip = (x: bigint) => (x * (10_000n - SLIPPAGE_BPS)) / 10_000n;
/** WAD amount in the settlement asset → native units. */
const toNative = (wad: bigint, decimals: number) => wad / 10n ** BigInt(18 - decimals);
const toWadFromNative = (native: bigint, decimals: number) => native * 10n ** BigInt(18 - decimals);

export function SeriesPage({ initialTab }: { initialTab?: Tab }) {
  const { id } = useParams();
  const [params, setParams] = useSearchParams();
  const series = useSeries(id as Hex | undefined);
  const { data: market } = useSeriesMarket(series);
  const { data: product } = useProductMarket(series?.productId);
  const { address } = useConnection();
  const { selected } = useAccountState();
  const { data: account } = useAccountView(selected);
  const { data: wallet } = useWalletWrappers(address);
  const { data: now } = useChainTime();
  const tick = useTicker(now);

  const fromUrl = params.get("tab") as Tab | null;
  const [tab, setTab] = useState<Tab>(fromUrl ?? initialTab ?? "buy");
  useEffect(() => {
    if (fromUrl) setTab(fromUrl);
  }, [fromUrl]);
  const [qtyForChart, setQtyForChart] = useState(1);

  if (!series) {
    return <Card>{id ? <Skeleton className="h-40 w-full" /> : <EmptyState title="Unknown option" action={<Link to="/" className="btn-ghost">Back to markets</Link>} />}</Card>;
  }

  const walletQty = wallet?.find((w) => w.series.id === series.id)?.balance ?? 0n;
  const position = account?.positions.find((p) => p.seriesId === series.id)?.balance ?? 0n;
  const state = market?.state ?? "ACTIVE";
  const ctx: ActionContext = {
    connected: !!address,
    groupState: state,
    productCloseOnly: product?.closeOnly ?? false,
    dataFresh: !!product?.spotFresh && product?.surface === "FRESH",
    marketTradable: !!market?.quote,
    hasAccount: selected !== undefined,
    health: account?.health.state,
    accountBalance: position,
    walletWrappers: walletQty,
    credit: false,
  };
  const tabs: { value: Tab; label: string; actions: ActionKey[] }[] = [
    { value: "buy", label: "Buy", actions: ["buy"] },
    { value: "write", label: "Write", actions: ["write"] },
    { value: "sell", label: "Sell", actions: ["sell"] },
    { value: "manage", label: "Manage", actions: ["unwrap", "close", "wrap"] },
    { value: "redeem", label: "Redeem", actions: ["redeem", "claim"] },
  ];
  const spotNum = product ? Number(product.spotWad) / 1e18 : undefined;
  const markNum = market?.mark !== undefined ? Number(market.mark) / 1e18 : undefined;
  const side = tab === "write" || tab === "sell" ? "short" : "long";
  const premiumForChart = (side === "long" ? market?.quote?.ask : market?.quote?.bid) ?? market?.mark;

  const select = (t: Tab) => {
    setTab(t);
    setParams((p) => (p.set("tab", t), p), { replace: true });
  };

  return (
    <div className="space-y-6">
      <Link to="/" className="text-sm text-muted hover:text-primary">← All markets</Link>
      <section className="card p-6">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <div className="flex flex-wrap items-center gap-2">
              <Pill tone={series.optionType === 0 ? "primary" : "accent"}>{optionTypeName(series.optionType)}</Pill>
              <StatePill state={state} />
            </div>
            <h1 className="mt-2 text-3xl font-bold tracking-tight">
              {series.underlyingSymbol} {fmtWad(series.strikeWad, 0)} {optionTypeName(series.optionType)}
            </h1>
            <p className="mt-1 text-muted">
              Expires {fmtExpiry(series.expiry)}
              {tick !== undefined && series.expiry > tick && <span className="num"> · in {fmtDuration(series.expiry - tick)}</span>}
            </p>
          </div>
          <div className="grid grid-cols-2 gap-x-8 gap-y-4 sm:grid-cols-4">
            <Stat label={`${series.underlyingSymbol} now`} value={product ? fmtWad(product.spotWad) : "…"} />
            <Stat label={<Term tip="The protocol's fair value per option, from the volatility surface. Margin uses it.">Mark</Term>} value={market?.mark !== undefined ? fmtPrice(market.mark) : "—"} sub={series.assetSymbol} />
            <Stat label={<Term tip="Implied volatility: how much the market expects the price to move. Higher IV, pricier options.">IV</Term>} value={market?.iv !== undefined ? fmtIv(market.iv) : "—"} />
            <Stat
              label="Kuru bid / ask"
              value={
                market?.quote ? (
                  <span>
                    <span className="text-good">{market.quote.bid !== undefined ? fmtPrice(market.quote.bid) : "—"}</span>
                    <span className="text-muted"> / </span>
                    <span className="text-bad">{market.quote.ask !== undefined ? fmtPrice(market.quote.ask) : "—"}</span>
                  </span>
                ) : (
                  "no market"
                )
              }
            />
          </div>
        </div>
        {(walletQty > 0n || position !== 0n) && (
          <div className="mt-5 flex flex-wrap gap-2 border-t border-line pt-4 text-sm">
            <span className="text-muted">You hold:</span>
            {walletQty > 0n && <Pill tone="primary">{fmtQty(walletQty)} tokens in your wallet</Pill>}
            {position > 0n && <Pill tone="good">{fmtQty(position)} long in account #{selected?.toString()}</Pill>}
            {position < 0n && <Pill tone="accent">{fmtQty(-position)} written (short) in account #{selected?.toString()}</Pill>}
          </div>
        )}
      </section>

      <div className="grid gap-6 lg:grid-cols-[1fr_420px]">
        <div className="space-y-6">
          <Card
            title={side === "long" ? "Your result at expiry if you buy" : "Your result at expiry if you write"}
            action={<span className="text-xs text-muted">for {Number(qtyForChart.toFixed(4))} option{qtyForChart === 1 ? "" : "s"}</span>}
          >
            {spotNum !== undefined || markNum !== undefined ? (
              <PayoffChart
                optionType={series.optionType}
                strike={Number(series.strikeWad) / 1e18}
                spot={spotNum}
                premium={premiumForChart !== undefined ? Number(premiumForChart) / 1e18 : 0}
                qty={qtyForChart}
                side={side}
                assetSymbol={series.assetSymbol}
                underlyingSymbol={series.underlyingSymbol}
              />
            ) : (
              <Skeleton className="h-60 w-full" />
            )}
            <p className="mt-3 text-xs text-muted">
              {side === "long"
                ? `Buying: you pay the premium once. At expiry you receive ${series.optionType === 0 ? "the amount the price ends above" : "the amount the price ends below"} ${fmtWad(series.strikeWad, 0)} per option.`
                : "Writing: you receive the premium now and owe the payout at expiry. Your loss is not capped, so your account must keep enough margin."}
            </p>
          </Card>
          <Terms s={series} market={market?.quote?.market} />
        </div>

        <Card className="h-fit lg:sticky lg:top-24">
          <div className="mb-5 overflow-x-auto">
            <Segmented
              value={tab}
              onChange={select}
              options={tabs.map((t) => {
                const a = t.actions.map((k) => availability(k, ctx));
                return { value: t.value, label: t.label, title: a.every((x) => !x.enabled) ? a[0]?.reason : undefined };
              })}
            />
          </div>
          {tab === "buy" && <BuyPanel s={series} ctx={ctx} ask={market?.quote?.ask} market={market?.quote?.market} onQty={setQtyForChart} />}
          {tab === "write" && <WritePanel s={series} ctx={ctx} bid={market?.quote?.bid} market={market?.quote?.market} onQty={setQtyForChart} />}
          {tab === "sell" && <SellPanel s={series} ctx={ctx} bid={market?.quote?.bid} market={market?.quote?.market} walletQty={walletQty} onQty={setQtyForChart} />}
          {tab === "manage" && <ManagePanel s={series} ctx={ctx} walletQty={walletQty} position={position} />}
          {tab === "redeem" && <RedeemPanel s={series} ctx={ctx} walletQty={walletQty} />}
          {account && (
            <div className="mt-6 border-t border-line pt-5">
              <div className="label mb-3">Account #{selected?.toString()}</div>
              <HealthBar health={account.health} hasPositions={account.positions.length > 0} assetSymbol={series.assetSymbol} compact />
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}

export function StatePill({ state }: { state: string }) {
  const map: Record<string, [string, "good" | "warn" | "bad" | "neutral" | "primary"]> = {
    ACTIVE: ["Trading", "good"],
    EXPIRED: ["Expired · awaiting price", "warn"],
    ORACLE_STALLED: ["Price feed late", "bad"],
    FINALIZED: ["Settling accounts", "primary"],
    ALL_SETTLED: ["Opening payouts", "primary"],
    REDEEMABLE: ["Payouts open", "good"],
  };
  const [label, tone] = map[state] ?? [state, "neutral"];
  return (
    <Pill tone={tone} dot={state === "ACTIVE"}>
      {label}
    </Pill>
  );
}

function Terms({ s, market }: { s: Series; market?: Hex }) {
  return (
    <Card title="Contract terms">
      <div className="grid gap-x-8 sm:grid-cols-2">
        <Row label="Type" value={`European ${optionTypeName(s.optionType).toLowerCase()}, cash-settled`} />
        <Row label="Strike" value={`${fmtWad(s.strikeWad, 2)} ${s.assetSymbol}`} />
        <Row label="Contract size" value={`${fmtWad(s.contractSizeWad, 3)} ${s.underlyingSymbol}`} />
        <Row label="Settles in" value={s.assetSymbol} />
        <Row label="Expiry" value={fmtExpiry(s.expiry)} />
        <Row label="Settlement price" value="Chainlink round in force at expiry" />
        <Row
          label="Option token"
          value={
            <span>
              {shortAddr(s.wrapper)} <CopyButton text={s.wrapper} label="token address" />
            </span>
          }
        />
        <Row label="Kuru market" value={market ? <span>{shortAddr(market)} <CopyButton text={market} label="market address" /></span> : "not listed"} />
      </div>
    </Card>
  );
}

function Blocked({ reason }: { reason?: string }) {
  return reason ? <div className="rounded-xl border border-line bg-surface-2 p-4 text-sm text-muted">{reason}</div> : null;
}

// ------------------------------------------------------------------ Buy (F9)

function BuyPanel({ s, ctx, ask, market, onQty }: { s: Series; ctx: ActionContext; ask?: bigint; market?: Hex; onQty: (q: number) => void }) {
  const { address } = useConnection();
  const [amount, setAmount] = useState("100");
  const premiumIn = parseFixed(amount, s.assetDecimals);
  const { data: balance } = useTokenBalance(s.settlementAsset, address);
  const a = availability("buy", ctx);
  const fees = useQuery({
    queryKey: ["buyFees", s.id, premiumIn?.toString(), market],
    queryFn: async () => ({ optara: await previewBuyerFee(premiumIn!), kuru: await kuruTakerFee(market!, premiumIn!) }),
    enabled: !!premiumIn && !!market,
  });
  // Kuru takes its fee in options: estimated quantity = (premium − Kuru fee) / ask.
  const estQty = premiumIn && ask && fees.data ? (toWadFromNative(premiumIn - fees.data.kuru, s.assetDecimals) * WAD) / ask : undefined;
  useEffect(() => onQty(estQty ? Math.max(Number(estQty) / 1e18, 0.01) : 1), [estQty, onQty]);
  const total = premiumIn !== undefined && fees.data ? premiumIn + fees.data.optara : undefined;
  const tooMuch = total !== undefined && balance !== undefined && total > balance;
  const steps =
    address && premiumIn && fees.data && estQty ? buySteps(s, premiumIn, lessSlip(estQty), withSlip(fees.data.optara), withSlip(fees.data.kuru), address) : undefined;

  if (!a.enabled && ctx.connected) return <Blocked reason={a.reason} />;
  return (
    <div className="space-y-4">
      <AmountInput
        label="You spend"
        value={amount}
        onChange={setAmount}
        unit={s.assetSymbol}
        presets={["50", "100", "250", "500"]}
        max={balance !== undefined ? fmtNative(balance, s.assetDecimals, 2).replace(/,/g, "") : undefined}
        maxLabel="Wallet"
        invalid={tooMuch ? `Your wallet has ${fmtNative(balance!, s.assetDecimals)} ${s.assetSymbol}.` : undefined}
      />
      <div className="rounded-xl bg-surface-2 p-4">
        <div className="flex items-baseline justify-between">
          <span className="text-sm text-muted">You receive about</span>
          <span className="num text-2xl font-bold">{estQty !== undefined ? fmtQty(estQty) : "—"}</span>
        </div>
        <div className="text-right text-xs text-muted">options at {ask !== undefined ? fmtWad(ask) : "—"} {s.assetSymbol} each</div>
        <div className="mt-3 border-t border-line pt-2">
          <Row label="Premium" value={premiumIn !== undefined ? `${fmtNative(premiumIn, s.assetDecimals)} ${s.assetSymbol}` : "—"} />
          <Row label={<Term tip="Charged by Kuru, the order book. Taken from the options you receive.">Kuru fee</Term>} value={fees.data ? `≈ ${fmtNative(fees.data.kuru, s.assetDecimals)} ${s.assetSymbol}` : "—"} />
          <Row label={<Term tip="Optara's buyer fee, on the premium actually spent. Funds insurance, treasury and keepers.">Optara fee</Term>} value={fees.data ? `${fmtNative(fees.data.optara, s.assetDecimals)} ${s.assetSymbol}` : "—"} />
          <Row strong label="Total from your wallet" value={total !== undefined ? `${fmtNative(total, s.assetDecimals)} ${s.assetSymbol}` : "—"} />
        </div>
        <p className="mt-2 text-xs text-muted">Limits include 1% slippage. Unspent {s.assetSymbol} is refunded exactly.</p>
      </div>
      <TxButton label={estQty ? `Buy ${fmtQty(estQty)} options` : "Buy"} steps={steps} disabled={!a.enabled || !steps || tooMuch} disabledReason={a.reason} disclosures={disclosuresFor("buy", s.underlyingSymbol)} successMessage="Options bought — they're in your wallet" />
    </div>
  );
}

// ------------------------------------------------------------------ Write (F1, F2)

function WritePanel({ s, ctx, bid, market, onQty }: { s: Series; ctx: ActionContext; bid?: bigint; market?: Hex; onQty: (q: number) => void }) {
  const { address } = useConnection();
  const { selected } = useAccountState();
  const [amount, setAmount] = useState("1");
  const [sellNow, setSellNow] = useState(true);
  const qty = parseQty(amount);
  useEffect(() => onQty(qty ? Number(qty) / 1e18 : 1), [qty, onQty]);
  const a = availability("write", ctx);
  const preview = useQuery({
    queryKey: ["previewMint", selected?.toString(), s.id, qty?.toString()],
    queryFn: () => previewMint(selected!, s.id, qty!),
    enabled: selected !== undefined && !!qty,
    refetchInterval: 6_000,
  });
  const sellable = sellNow && !!market && bid !== undefined;
  const grossProceeds = qty && bid ? toNative((qty * bid) / WAD, s.assetDecimals) : undefined;
  const sellFee = useQuery({ queryKey: ["sellFee", market, grossProceeds?.toString()], queryFn: () => kuruSellFee(market!, grossProceeds!), enabled: sellable && !!grossProceeds });
  const net = grossProceeds !== undefined && sellFee.data !== undefined ? grossProceeds - sellFee.data : undefined;
  const [fee, equityAfter, imAfter, ok] = preview.data ?? [];

  if (!ctx.hasAccount && ctx.connected) return <AccountSetup s={s} />;
  if (!a.enabled && ctx.connected) return <Blocked reason={a.reason} />;

  const steps =
    address && selected !== undefined && qty && fee !== undefined
      ? [...mintSteps(selected, s, qty, withSlip(fee), address), ...(sellable && net !== undefined ? sellSteps(s, qty, lessSlip(net), withSlip(sellFee.data!), address) : [])]
      : undefined;
  return (
    <div className="space-y-4">
      <AmountInput label="Options to write" value={amount} onChange={setAmount} unit="options" presets={["0.1", "0.5", "1", "2"]} hint="Minimum 0.01. Your account must stay above its initial margin." />
      <label className={cx("flex cursor-pointer items-start gap-3 rounded-xl border p-3.5 transition", sellable ? "border-primary bg-primary-soft" : "border-line")}>
        <input type="checkbox" className="mt-0.5 h-4 w-4 accent-[var(--primary)]" checked={sellNow} onChange={(e) => setSellNow(e.target.checked)} disabled={!market || bid === undefined} />
        <span className="text-sm">
          <span className="block font-medium">Sell them on Kuru right away</span>
          <span className="block text-muted">{market && bid !== undefined ? `Best bid ${fmtWad(bid)} ${s.assetSymbol}. The premium lands in your wallet.` : "No bids on Kuru right now: you'll receive the option tokens instead."}</span>
        </span>
      </label>
      <div className="rounded-xl bg-surface-2 p-4">
        {sellable && net !== undefined && (
          <div className="mb-3 flex items-baseline justify-between">
            <span className="text-sm text-muted">Premium to your wallet</span>
            <span className="num text-2xl font-bold text-good">+{fmtNative(net, s.assetDecimals)}</span>
          </div>
        )}
        <Row label={<Term tip="Optara's fee for opening a written position, taken from your account's cash.">Optara fee</Term>} value={fee !== undefined ? `${fmtNative(fee, s.assetDecimals)} ${s.assetSymbol}` : "—"} />
        {sellable && <Row label="Kuru fee" value={sellFee.data !== undefined ? `${fmtNative(sellFee.data, s.assetDecimals)} ${s.assetSymbol}` : "—"} />}
        {sellable && <Row label="Premium (gross)" value={grossProceeds !== undefined ? `${fmtNative(grossProceeds, s.assetDecimals)} ${s.assetSymbol}` : "—"} />}
        <Row strong label={<Term tip="Your account's value and initial margin after writing. Equity must stay at or above IM.">Equity after / IM after</Term>} value={equityAfter !== undefined ? `${fmtWad(equityAfter)} / ${fmtWad(imAfter!)}` : "—"} tone={ok === false ? "bad" : ok ? "good" : undefined} />
        {ok === false && <p className="mt-2 text-sm text-bad">Not enough margin for this size. Deposit more or write fewer.</p>}
      </div>
      <TxButton
        label={sellable ? `Write & sell ${amount || "0"}` : `Write ${amount || "0"}`}
        tone="accent"
        steps={ok ? steps : undefined}
        disabled={!a.enabled || !steps || ok === false}
        disabledReason={a.reason}
        disclosures={disclosuresFor("write", s.underlyingSymbol)}
        successMessage={sellable ? "Written and sold — premium is in your wallet" : "Written — option tokens are in your wallet"}
      />
      <p className="text-center text-xs text-muted">Tip: deposit the premium back into Optara to strengthen your margin (Portfolio → Deposit).</p>
    </div>
  );
}

/** First-time writers: create an account and deposit in one go (F1). */
function AccountSetup({ s }: { s: Series }) {
  const { refresh, select } = useAccountState();
  const { address } = useConnection();
  const { data: balance } = useTokenBalance(s.settlementAsset, address);
  const [amount, setAmount] = useState("5000");
  const deposit = parseFixed(amount, s.assetDecimals);
  const created = useRef<bigint | undefined>(undefined);
  const steps = useMemo(
    () => (deposit ? setupAccountSteps(s.settlementAsset, deposit, s.assetSymbol, (id) => (created.current = id)) : undefined),
    [deposit, s],
  );
  return (
    <div className="space-y-4">
      <div className="rounded-xl border border-primary/40 bg-primary-soft p-4 text-sm">
        <div className="font-semibold">Set up your trading account</div>
        <p className="mt-1 text-muted">Writing options needs collateral held in an Optara account. One click creates the account and deposits.</p>
      </div>
      <AmountInput label="Deposit" value={amount} onChange={setAmount} unit={s.assetSymbol} presets={["1000", "5000", "10000"]} max={balance !== undefined ? fmtNative(balance, s.assetDecimals).replace(/,/g, "") : undefined} maxLabel="Wallet" />
      <TxButton
        label="Create account & deposit"
        steps={steps}
        disabled={!deposit}
        successMessage="Account ready"
        onDone={async () => {
          await refresh();
          if (created.current !== undefined) select(created.current);
        }}
      />
    </div>
  );
}

// ------------------------------------------------------------------ Sell wallet tokens (F2 step 4, F7)

function SellPanel({ s, ctx, bid, market, walletQty, onQty }: { s: Series; ctx: ActionContext; bid?: bigint; market?: Hex; walletQty: bigint; onQty: (q: number) => void }) {
  const { address } = useConnection();
  const [amount, setAmount] = useState("");
  const qty = parseQty(amount);
  useEffect(() => onQty(qty ? Number(qty) / 1e18 : 1), [qty, onQty]);
  const a = availability("sell", ctx);
  const gross = qty && bid ? toNative((qty * bid) / WAD, s.assetDecimals) : undefined;
  const fee = useQuery({ queryKey: ["sellFee", market, gross?.toString()], queryFn: () => kuruSellFee(market!, gross!), enabled: !!market && !!gross });
  const net = gross !== undefined && fee.data !== undefined ? gross - fee.data : undefined;
  if (!a.enabled && ctx.connected) return <Blocked reason={a.reason} />;
  const tooMuch = qty !== undefined && qty > walletQty;
  const steps = address && qty && net !== undefined && fee.data !== undefined ? sellSteps(s, qty, lessSlip(net), withSlip(fee.data), address) : undefined;
  return (
    <div className="space-y-4">
      <AmountInput label="Options to sell" value={amount} onChange={setAmount} unit="options" max={fmtQty(walletQty)} maxLabel="In wallet" invalid={tooMuch ? "More than you hold." : undefined} />
      <div className="rounded-xl bg-surface-2 p-4">
        <Row label="Best bid" value={bid !== undefined ? `${fmtWad(bid)} ${s.assetSymbol}` : "no bids"} />
        <Row label="Premium (gross)" value={gross !== undefined ? `${fmtNative(gross, s.assetDecimals)} ${s.assetSymbol}` : "—"} />
        <Row label="Kuru fee" value={fee.data !== undefined ? `${fmtNative(fee.data, s.assetDecimals)} ${s.assetSymbol}` : "—"} />
        <Row label="Optara fee" value="none on sales" />
        <Row strong label="You receive" value={net !== undefined ? `${fmtNative(net, s.assetDecimals)} ${s.assetSymbol}` : "—"} tone="good" />
      </div>
      <TxButton label="Sell" steps={steps} disabled={!steps || tooMuch} disabledReason={a.reason} successMessage="Sold — proceeds are in your wallet" />
    </div>
  );
}

// ------------------------------------------------------------------ Manage: unwrap, close, wrap (F4, F5, F7, F11)

function ManagePanel({ s, ctx, walletQty, position }: { s: Series; ctx: ActionContext; walletQty: bigint; position: bigint }) {
  const { selected } = useAccountState();
  const { address } = useConnection();
  const [unwrapAmt, setUnwrapAmt] = useState("");
  const [closeAmt, setCloseAmt] = useState("");
  const [wrapAmt, setWrapAmt] = useState("");
  const u = availability("unwrap", ctx);
  const c = availability("close", ctx);
  const w = availability("wrap", ctx);
  const uq = parseQty(unwrapAmt);
  const cq = parseQty(closeAmt);
  const wq = parseQty(wrapAmt);
  const maxClose = position < 0n ? (-position < walletQty ? -position : walletQty) : 0n;
  return (
    <div className="space-y-5">
      <Section title="Close your short" text="Burn option tokens from your wallet against the options you wrote. Margin is released immediately." blocked={!c.enabled ? c.reason : undefined}>
        <AmountInput label="Options" value={closeAmt} onChange={setCloseAmt} unit="options" max={fmtQty(maxClose)} />
        <TxButton label="Close" steps={selected !== undefined && cq ? closeShortSteps(selected, s, cq) : undefined} disabled={!c.enabled || !cq || cq > maxClose} disabledReason={c.reason} successMessage="Short closed" />
      </Section>
      <Section title="Move tokens into your account" text="Wallet tokens become a long in your account and count toward margin (e.g. to hedge a written option)." blocked={!u.enabled ? u.reason : undefined}>
        <AmountInput label="Options" value={unwrapAmt} onChange={setUnwrapAmt} unit="options" max={fmtQty(walletQty)} />
        <TxButton label="Move into account" steps={selected !== undefined && uq ? unwrapSteps(selected, s, uq) : undefined} disabled={!u.enabled || !uq || uq > walletQty} disabledReason={u.reason} successMessage="Moved into your account" />
      </Section>
      <Section title="Move a long to your wallet" text="Turns a long in your account into tokens you can sell or transfer. Your account must stay healthy without it." blocked={!w.enabled ? w.reason : undefined}>
        <AmountInput label="Options" value={wrapAmt} onChange={setWrapAmt} unit="options" max={position > 0n ? fmtQty(position) : "0"} />
        <TxButton label="Move to wallet" steps={selected !== undefined && wq && address ? wrapSteps(selected, s, wq, address) : undefined} disabled={!w.enabled || !wq} disabledReason={w.reason} successMessage="Moved to your wallet" />
      </Section>
    </div>
  );
}

function Section({ title, text, children, blocked }: { title: string; text: string; children: React.ReactNode; blocked?: string }) {
  const [open, setOpen] = useState(!blocked);
  return (
    <div className="rounded-xl border border-line">
      <button className="flex w-full items-center justify-between gap-3 p-4 text-left" onClick={() => setOpen((o) => !o)} aria-expanded={open}>
        <span>
          <span className="block text-sm font-semibold">{title}</span>
          <span className="block text-xs text-muted">{blocked ?? text}</span>
        </span>
        <span className="text-muted">{open ? "−" : "+"}</span>
      </button>
      {open && <div className="space-y-3 border-t border-line p-4">{children}</div>}
    </div>
  );
}

// ------------------------------------------------------------------ Redeem and claim (F10)

function RedeemPanel({ s, ctx, walletQty }: { s: Series; ctx: ActionContext; walletQty: bigint }) {
  const { address } = useConnection();
  const { selected } = useAccountState();
  const credit = useQuery({
    queryKey: ["credit", selected?.toString(), s.groupId],
    queryFn: () => publicClient.readContract({ address: ADDR.settlement, abi: settlementWindowAbi, functionName: "creditOf", args: [selected!, s.groupId] }),
    enabled: selected !== undefined,
  });
  const payout = useQuery({ queryKey: ["previewRedeem", s.id, walletQty.toString()], queryFn: () => previewRedeem(s.id, walletQty), enabled: walletQty > 0n });
  const r = availability("redeem", ctx);
  const c = availability("claim", { ...ctx, credit: (credit.data ?? 0n) > 0n });
  const steps = useMemo(() => (address && walletQty > 0n ? redeemSteps(s, walletQty, address) : undefined), [address, walletQty, s]);
  return (
    <div className="space-y-4">
      <SettlementTimeline state={ctx.groupState} />
      <div className="rounded-xl bg-surface-2 p-4">
        <Row label="Option tokens in your wallet" value={fmtQty(walletQty)} />
        <Row strong label="Payout" value={payout.data ? `${fmtNative(payout.data[0], s.assetDecimals)} ${s.assetSymbol}${payout.data[1] ? "" : " (estimate)"}` : "—"} tone="good" />
      </div>
      <TxButton label="Redeem tokens" steps={steps} disabled={!r.enabled} disabledReason={r.reason} successMessage="Payout sent to your wallet" />
      {selected !== undefined && (credit.data ?? 0n) > 0n && (
        <TxButton label={`Claim account #${selected} credit`} steps={claimSteps(selected, s.groupId)} disabled={!c.enabled} disabledReason={c.reason} successMessage="Claimed into your account" />
      )}
    </div>
  );
}

export function SettlementTimeline({ state }: { state: string }) {
  const steps = [
    { key: "EXPIRED", label: "Expired" },
    { key: "FINALIZED", label: "Price fixed" },
    { key: "ALL_SETTLED", label: "Accounts settled" },
    { key: "REDEEMABLE", label: "Payouts open" },
  ];
  const order = ["ACTIVE", "EXPIRED", "ORACLE_STALLED", "FINALIZED", "ALL_SETTLED", "REDEEMABLE"];
  const at = order.indexOf(state === "ORACLE_STALLED" ? "EXPIRED" : state);
  return (
    <ol className="flex items-center gap-1">
      {steps.map((st, i) => {
        const done = at >= order.indexOf(st.key);
        return (
          <li key={st.key} className="flex flex-1 flex-col items-center gap-1.5 text-center">
            <div className={cx("h-1.5 w-full rounded-full", done ? "bg-good" : "bg-line")} />
            <span className={cx("text-[11px] leading-tight", done ? "text-ink" : "text-muted")}>{st.label}</span>
            {i === 0 && state === "ORACLE_STALLED" && <span className="text-[10px] text-bad">price feed late</span>}
          </li>
        );
      })}
    </ol>
  );
}
