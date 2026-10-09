/** `/trade`: pick direction, target, amount — buy in three taps. */
import { useEffect, useMemo, useState } from "react";
import { Link, useParams } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import type { Hex } from "viem";
import {
  ArrowRight,
  HelpCircle,
  ShieldCheck,
  TrendingDown,
  TrendingUp,
} from "lucide-react";
import { AmountInput, Card, Details, EmptyState, Row, Skeleton, Term, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { BuyOutcome, buyCheck } from "../components/BuyOutcome.tsx";
import { LimitsPanel } from "../components/LimitsPanel.tsx";
import { lessSlip, useSlippage, venueMinQty, withSlip } from "../lib/optara/limits.ts";
import { TxButton } from "../components/TxButton.tsx";
import { buySteps } from "../lib/optara/actions.ts";
import { availability, type ActionContext } from "../lib/optara/availability.ts";
import { recordTrade } from "../lib/optara/activity.ts";
import { disclosuresFor } from "../lib/optara/disclosures.ts";
import { fmtDuration, fmtExpiry, fmtExpiryShort, fmtLevel, fmtNative, fmtPrice, fmtQty, fmtWad, optionTypeName, parseFixed, seriesName, WAD } from "../lib/optara/format.ts";
import {
  useChainTime,
  useProductMarket,
  useSeries,
  useSeriesList,
  useSeriesMarket,
  useTokenBalance,
} from "../lib/optara/hooks.ts";
import { kuruTakerFee, previewBuyerFee } from "../lib/optara/reads.ts";
import { legOf, moveNeeded, moveText, priceLevel } from "../lib/optara/payoff.ts";
import type { Series } from "../lib/optara/types.ts";
import { useQuickGuide } from "../state.tsx";

const toWadFromNative = (native: bigint, decimals: number) => native * 10n ** BigInt(18 - decimals);

export function TradePage() {
  const { id } = useParams();
  const { address } = useConnection();
  const { open: openGuide } = useQuickGuide();

  const { data: allSeries, isLoading: loadingList } = useSeriesList();
  const { data: now } = useChainTime();

  // If specific series passed in URL, load it
  const urlSeries = useSeries(id as Hex | undefined);

  // Filter active series
  const activeSeries = useMemo(
    () => (allSeries ?? []).filter((s) => now === undefined || s.expiry > now),
    [allSeries, now]
  );

  // Products
  const products = useMemo(
    () => [...new Map(activeSeries.map((s) => [s.productId, s])).values()],
    [activeSeries]
  );

  const [selectedProductId, setSelectedProductId] = useState<Hex | undefined>();
  const product =
    products.find((p) => p.productId === selectedProductId) ??
    (urlSeries ? products.find((p) => p.productId === urlSeries.productId) : products[0]);

  const { data: productMarket } = useProductMarket(product?.productId);

  // Direction: "call" (UP) or "put" (DOWN)
  const [direction, setDirection] = useState<"call" | "put">("call");

  // Expiries available for selected product
  const expiries = useMemo(() => {
    if (!product) return [];
    const exps = activeSeries
      .filter((s) => s.productId === product.productId)
      .map((s) => s.expiry);
    return [...new Set(exps)].sort((a, b) => (a < b ? -1 : 1));
  }, [activeSeries, product]);

  const [selectedExpiry, setSelectedExpiry] = useState<bigint | undefined>();
  const chosenExpiry =
    selectedExpiry !== undefined && expiries.includes(selectedExpiry)
      ? selectedExpiry
      : expiries[0];

  // Candidates for selected product, expiry, and direction
  const targetOptionType = direction === "call" ? 0 : 1;
  const candidates = useMemo(() => {
    if (!product || chosenExpiry === undefined) return [];
    return activeSeries
      .filter(
        (s) =>
          s.productId === product.productId &&
          s.expiry === chosenExpiry &&
          s.optionType === targetOptionType
      )
      .sort((a, b) => (a.strikeWad < b.strikeWad ? -1 : 1));
  }, [activeSeries, product, chosenExpiry, targetOptionType]);

  // Selected series
  const [selectedSeriesId, setSelectedSeriesId] = useState<Hex | undefined>();
  const selectedSeries =
    candidates.find((s) => s.id === selectedSeriesId) ??
    (urlSeries && candidates.some((s) => s.id === urlSeries.id) ? urlSeries : candidates[0]);

  // Sync state if urlSeries is loaded
  useEffect(() => {
    if (urlSeries) {
      setDirection(urlSeries.optionType === 0 ? "call" : "put");
      setSelectedExpiry(urlSeries.expiry);
      setSelectedSeriesId(urlSeries.id);
    }
  }, [urlSeries]);

  // Investment amount
  const [spendAmount, setSpendAmount] = useState("50");

  if (loadingList) {
    return (
      <div className="w-full space-y-4 py-6">
        <Skeleton className="h-64 w-full rounded-3xl" />
        <Skeleton className="h-48 w-full rounded-3xl" />
      </div>
    );
  }

  if (!product || !selectedSeries) {
    return (
      <div className="w-full py-12">
        <Card>
          <EmptyState
            title="No active markets available"
            body="Check back soon when new option expiries are listed."
            action={
              <Link to="/app/markets" className="btn-primary mt-3 text-xs">
                Back to Markets
              </Link>
            }
          />
        </Card>
      </div>
    );
  }

  return (
    <div className="w-full space-y-4 py-1 sm:py-4">
      <div className="flex items-center justify-between px-1 text-[13px]">
        <Link to="/app/markets" className="font-semibold text-muted hover:text-ink transition">
          ← Markets
        </Link>
        <button onClick={openGuide} className="font-semibold text-primary hover:underline flex items-center gap-1 cursor-pointer">
          <HelpCircle className="h-3.5 w-3.5" /> How it works
        </button>
      </div>

      <QuickTradeIntro asset={product.underlyingSymbol} quote={product.assetSymbol} />

      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px] lg:items-start">
      <div className="ticket space-y-5 p-4 sm:p-6">
        <div className="flex items-center justify-between gap-2">
          <div>
            <h1 className="font-display text-xl font-bold tracking-tight sm:text-2xl">
              Build your trade
            </h1>
            <p className="mt-0.5 text-[13px] text-muted">Direction, target, amount. The quote updates as you go.</p>
          </div>
          <span className="pill border border-good/25 bg-good/10 text-good">Capped risk</span>
        </div>

        <div>
          <div className="label mb-2">
            Direction
          </div>
          <div className="grid grid-cols-2 gap-3">
            <button
              type="button"
              onClick={() => {
                setDirection("call");
                setSelectedSeriesId(undefined);
              }}
              className={cx(
                "flex items-center gap-2.5 rounded-2xl border p-3 text-left transition active:scale-[0.98] cursor-pointer",
                direction === "call"
                  ? "border-good/60 bg-good/8"
                  : "border-line bg-surface-2/60 hover:border-good/30"
              )}
            >
              <span className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-good/15 text-good">
                <TrendingUp className="h-4.5 w-4.5" />
              </span>
              <span>
                <span className="block text-sm font-bold">Up</span>
                <span className="block text-xs font-semibold text-good">Call option</span>
              </span>
            </button>

            <button
              type="button"
              onClick={() => {
                setDirection("put");
                setSelectedSeriesId(undefined);
              }}
              className={cx(
                "flex items-center gap-2.5 rounded-2xl border p-3 text-left transition active:scale-[0.98] cursor-pointer",
                direction === "put"
                  ? "border-bad/60 bg-bad/8"
                  : "border-line bg-surface-2/60 hover:border-bad/30"
              )}
            >
              <span className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-bad/15 text-bad">
                <TrendingDown className="h-4.5 w-4.5" />
              </span>
              <span>
                <span className="block text-sm font-bold">Down</span>
                <span className="block text-xs font-semibold text-bad">Put option</span>
              </span>
            </button>
          </div>
        </div>

        <div>
          <div className="mb-2 flex items-center justify-between">
            <span className="label">
              Target and expiry
            </span>
            {productMarket && (
              <span className="text-[13px] text-muted">
                Spot <b className="num font-display text-ink">${fmtLevel(productMarket.spotWad)}</b>
              </span>
            )}
          </div>

          <div className="mb-2.5 flex gap-1.5 overflow-x-auto pb-1 scrollbar-none">
            {expiries.map((exp) => (
              <button
                key={exp.toString()}
                type="button"
                onClick={() => {
                  setSelectedExpiry(exp);
                  setSelectedSeriesId(undefined);
                }}
                className={cx(
                  "whitespace-nowrap rounded-xl border px-2.5 py-1.5 text-[13px] font-semibold transition cursor-pointer",
                  exp === chosenExpiry
                    ? "border-primary/60 bg-primary-soft text-primary"
                    : "border-line bg-surface-2 text-muted hover:text-ink"
                )}
              >
                {fmtExpiryShort(exp)} {now !== undefined ? `· ${fmtDuration(exp - now)}` : ""}
              </button>
            ))}
          </div>

          {/* Strike cards: the target, and how far the price has to move to reach it */}
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
            {candidates.map((s) => {
              const isSelected = s.id === selectedSeries.id;
              const leg = legOf(s);
              const spot = productMarket ? Number(productMarket.spotWad) / 1e18 : undefined;
              const move = spot !== undefined ? moveNeeded(leg, spot, leg.strike) : undefined;

              return (
                <button
                  key={s.id}
                  type="button"
                  onClick={() => setSelectedSeriesId(s.id)}
                  className={cx(
                    "flex flex-col items-center justify-center rounded-2xl border p-3 text-center transition-all active:scale-[0.98]",
                    isSelected
                      ? "border-primary bg-primary-soft text-primary shadow-sm ring-1 ring-primary/40 font-bold"
                      : "border-line bg-surface-2/60 text-ink hover:border-primary/40"
                  )}
                >
                  <span className="num text-base font-extrabold">{priceLevel(leg.strike)}</span>
                  {move !== undefined && (
                    <span className={cx("num text-[11px] font-semibold mt-0.5", move <= 0 ? "text-good" : "text-muted")}>
                      {move <= 0 ? "Already past" : `Needs to ${moveText(leg, move, 0)}`}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
          <p className="mt-2 text-xs text-muted">
            The target is the strike. {direction === "call" ? "Above it" : "Below it"}, every option pays the difference in{" "}
            {product.assetSymbol} at expiry.
          </p>
        </div>

        <div>
          <div className="label mb-2">
            Premium to spend
          </div>
          <TradeForm
            series={selectedSeries}
            amount={spendAmount}
            onAmountChange={setSpendAmount}
            productMarket={productMarket}
          />
        </div>

        {/* Advanced link */}
        <div className="text-center pt-2 border-t border-line">
          <Link
            to={`/app/series/${selectedSeries.id}`}
            className="text-xs text-primary font-semibold hover:underline inline-flex items-center gap-1"
          >
            See payoff chart, details and what backs this option <ArrowRight className="h-3 w-3" />
          </Link>
        </div>
      </div>
      <TradeSideGuide series={selectedSeries} spot={productMarket?.spotWad} />
      </div>
    </div>
  );
}

function QuickTradeIntro({ asset, quote }: { asset: string; quote: string }) {
  return (
    <section className="page-band">
      <div className="grid gap-3 md:grid-cols-3">
        <GuideItem title="1. Pick direction" text={`Up buys a call. Down buys a put on ${asset}.`} />
        <GuideItem title="2. Pick target" text={`The target is the price ${asset} must pass by expiry.`} />
        <GuideItem title="3. Pay premium" text={`Your option pays out in ${quote}. Max loss is the total paid.`} />
      </div>
    </section>
  );
}

function GuideItem({ title, text }: { title: string; text: string }) {
  return (
    <div className="info-row">
      <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0 text-good" />
      <span>
        <span className="block text-sm font-bold">{title}</span>
        <span className="block text-xs leading-5 text-muted">{text}</span>
      </span>
    </div>
  );
}

function TradeSideGuide({ series, spot }: { series: Series; spot?: bigint }) {
  const leg = legOf(series);
  const spotN = spot !== undefined ? Number(spot) / 1e18 : undefined;
  const move = spotN !== undefined ? moveNeeded(leg, spotN, leg.strike) : undefined;
  return (
    <aside className="page-band space-y-3 lg:sticky lg:top-[88px]">
      <div>
        <div className="text-[11px] font-bold uppercase text-faint">Selected option</div>
        <div className="mt-1 flex items-center gap-2">
          <TokenIcon symbol={series.underlyingSymbol} className="h-8 w-8" />
          <div>
            <div className="font-display text-lg font-bold">{optionTypeName(series.optionType)} {priceLevel(leg.strike)}</div>
            <div className="text-xs text-muted">Expires {fmtExpiry(series.expiry)}</div>
          </div>
        </div>
      </div>
      <div className="info-row">
        <TrendingUp className="mt-0.5 h-4 w-4 shrink-0 text-primary" />
        <div className="text-sm">
          {move === undefined
            ? "Waiting for live spot."
            : move <= 0
            ? "This option is already past its target."
            : `It starts paying intrinsic value after the price ${moveText(leg, move, 1, true)}.`}
        </div>
      </div>
      <div className="rounded-lg border border-good/25 bg-good/8 p-3 text-xs leading-5 text-good">
        Buying is capped risk: you cannot be liquidated and cannot owe more later.
      </div>
    </aside>
  );
}

function TradeForm({
  series,
  amount,
  onAmountChange,
  productMarket,
}: {
  series: Series;
  amount: string;
  onAmountChange: (a: string) => void;
  productMarket?: any;
}) {
  const { address } = useConnection();
  const { data: market } = useSeriesMarket(series);
  const { data: balance } = useTokenBalance(series.settlementAsset, address);

  const premiumIn = parseFixed(amount, series.assetDecimals);
  const [slip] = useSlippage();
  const ask = market?.quote?.ask;
  const kuruMarket = market?.quote?.market;

  const fees = useQuery({
    queryKey: ["instantBuyFees", series.id, premiumIn?.toString(), kuruMarket],
    queryFn: async () => ({
      optara: await previewBuyerFee(premiumIn!),
      kuru: kuruMarket ? await kuruTakerFee(kuruMarket, premiumIn!) : 0n,
    }),
    enabled: !!premiumIn && !!kuruMarket,
  });

  const estQty =
    premiumIn && ask && fees.data
      ? (toWadFromNative(premiumIn - fees.data.kuru, series.assetDecimals) * WAD) / ask
      : undefined;

  const total = premiumIn !== undefined && fees.data ? premiumIn + fees.data.optara : undefined;
  // Far above fair value, the buyer must confirm first (re-asked whenever the option or amount changes).
  const check = buyCheck(estQty, total, series.assetDecimals, market?.mark);
  const [ack, setAck] = useState(false);
  useEffect(() => setAck(false), [series.id, amount]);
  const tooMuch = total !== undefined && balance !== undefined && total > balance;

  const ctx: ActionContext = {
    connected: !!address,
    groupState: market?.state ?? "ACTIVE",
    productCloseOnly: productMarket?.closeOnly ?? false,
    dataFresh: !!productMarket?.spotFresh && productMarket?.surface === "FRESH",
    marketTradable: !!market?.quote,
    hasAccount: true,
    health: "HEALTHY",
    accountBalance: 0n,
    walletWrappers: 0n,
    credit: false,
  };

  const a = availability("buy", ctx);

  const steps =
    address && premiumIn && fees.data && estQty
      ? buySteps(
          series,
          premiumIn,
          venueMinQty(estQty, slip),
          withSlip(fees.data.optara, slip),
          withSlip(fees.data.kuru, slip),
          address
        )
      : undefined;

  const spotNum = productMarket ? Number(productMarket.spotWad) / 1e18 : undefined;
  const qtyNum = estQty !== undefined ? Number(estQty) / 1e18 : undefined;

  return (
    <div className="space-y-3.5">
      <AmountInput
        label="Premium to spend"
        value={amount}
        onChange={onAmountChange}
        unit={series.assetSymbol}
        presets={["25", "50", "100", "250"]}
        max={balance !== undefined ? fmtNative(balance, series.assetDecimals, 2).replace(/,/g, "") : undefined}
        maxLabel="Wallet"
        hint="Paid from your wallet, not your margin account. A small Optara fee is added on top; the total is shown below."
        invalid={tooMuch ? `You need ${fmtNative(total!, series.assetDecimals)} ${series.assetSymbol} including fees; your wallet holds ${fmtNative(balance!, series.assetDecimals)}.` : undefined}
      />

      <div className="rounded-2xl border border-line bg-surface-2/70 p-3.5 space-y-2.5">
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-[13px] text-muted">You get about</span>
          <span className="num font-display text-2xl font-bold tracking-tight">
            {estQty !== undefined ? `${fmtQty(estQty)} option${qtyNum === 1 ? "" : "s"}` : "—"}
          </span>
        </div>

        {ask === undefined && kuruMarket !== undefined && (
          <p className="text-xs text-warn">Nobody is selling this option right now. Try another target or expiry.</p>
        )}

        <BuyOutcome series={series} qty={estQty} total={total} spot={spotNum} mark={market?.mark} ack={ack} onAck={setAck} />

        <Details summary={<span>Total cost <b className="num">{total !== undefined ? `${fmtNative(total, series.assetDecimals)} ${series.assetSymbol}` : "—"}</b></span>}>
          <Row
            label="Premium"
            value={premiumIn !== undefined ? `${fmtNative(premiumIn, series.assetDecimals)} ${series.assetSymbol}` : "—"}
          />
          <Row
            label={<Term tip="Charged by the Kuru order book. It comes out of the premium, so you get slightly fewer options.">Order book fee (in premium)</Term>}
            value={fees.data ? `≈ ${fmtNative(fees.data.kuru, series.assetDecimals)}` : "—"}
          />
          <Row
            label={<Term tip="Added on top of the premium. Funds the insurance fund and the keepers that settle trades.">Optara fee (added)</Term>}
            value={fees.data ? `${fmtNative(fees.data.optara, series.assetDecimals)}` : "—"}
          />
          <Row
            label="Price per option"
            value={ask !== undefined ? `${fmtPrice(ask)} ${series.assetSymbol}` : "—"}
          />
        </Details>
      </div>

      <LimitsPanel limits={buyLimits(series, premiumIn, estQty, fees.data, slip)} />

      <TxButton
        label={estQty && total !== undefined ? `Buy ${fmtQty(estQty)} for ${fmtNative(total, series.assetDecimals)} ${series.assetSymbol}` : "Buy"}
        summary={estQty && total !== undefined ? `Pay up to ${fmtNative(total, series.assetDecimals)} ${series.assetSymbol} (fees included) for about ${fmtQty(estQty)} ${seriesName(series)} options${check.over !== undefined && check.over > 0.1 ? `, ${(check.over * 100).toFixed(0)}% above fair value` : ""}` : undefined}
        steps={steps}
        disabled={!a.enabled || !steps || tooMuch || (check.needsAck && !ack)}
        disabledReason={a.reason ?? (check.needsAck && !ack ? "Confirm the price above first." : undefined)}
        disclosures={disclosuresFor("buy", series.underlyingSymbol)}
        successMessage="Bought. Tokens are in your wallet."

        onDone={() => recordTrade(address, series.id, "buy")}
      />
    </div>
  );
}

/** The limits a buy is signed with (VenueRouter.buyThroughVenue). */
export function buyLimits(s: Series, premiumIn: bigint | undefined, estQty: bigint | undefined, fees: { optara: bigint; kuru: bigint } | undefined, slip: number) {
  if (!premiumIn || !estQty || !fees) return [];
  const n = (x: bigint) => `${fmtNative(x, s.assetDecimals)} ${s.assetSymbol}`;
  return [
    { label: "Premium budget", value: n(premiumIn), tip: "The most premium you spend. Anything not used is refunded." },
    { label: "Fewest options accepted", value: fmtQty(venueMinQty(estQty, slip)), tip: "If the venue would give you fewer options than this, the buy is cancelled. Rounded to the venue's 0.01 option fill increment." },
    { label: "Max Optara fee", value: n(withSlip(fees.optara, slip)), tip: "The buyer fee can't exceed this." },
    { label: "Max venue fee", value: n(withSlip(fees.kuru, slip)), tip: "The selected venue's fee can't exceed this." },
  ];
}
