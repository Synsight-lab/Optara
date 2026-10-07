/** `/trade` and `/trade/:id`: Frictionless, Swap-like Options Trading Interface (NectarFi-style simplicity). */
import { useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import type { Hex } from "viem";
import {
  ArrowRight,
  Calendar,
  CheckCircle2,
  Clock,
  HelpCircle,
  Info,
  ShieldCheck,
  Sparkles,
  TrendingDown,
  TrendingUp,
  Wallet,
  Zap,
} from "lucide-react";
import { AmountInput, Card, EmptyState, Pill, Row, Skeleton, Term, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { buySteps } from "../lib/optara/actions.ts";
import { availability, type ActionContext } from "../lib/optara/availability.ts";
import { disclosuresFor } from "../lib/optara/disclosures.ts";
import {
  fmtDuration,
  fmtExpiry,
  fmtExpiryShort,
  fmtNative,
  fmtPrice,
  fmtQty,
  fmtWad,
  optionTypeName,
  parseFixed,
  WAD,
} from "../lib/optara/format.ts";
import {
  useChainTime,
  useProductMarket,
  useSeries,
  useSeriesList,
  useSeriesMarket,
  useTokenBalance,
} from "../lib/optara/hooks.ts";
import { kuruTakerFee, previewBuyerFee } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { useQuickGuide } from "../state.tsx";

const SLIPPAGE_BPS = 100n;
const withSlip = (x: bigint) => (x * (10_000n + SLIPPAGE_BPS)) / 10_000n + 1n;
const lessSlip = (x: bigint) => (x * (10_000n - SLIPPAGE_BPS)) / 10_000n;
const toWadFromNative = (native: bigint, decimals: number) => native * 10n ** BigInt(18 - decimals);

export function TradePage() {
  const { id } = useParams();
  const navigate = useNavigate();
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
      <div className="mx-auto max-w-xl space-y-4 py-6">
        <Skeleton className="h-64 w-full rounded-3xl" />
        <Skeleton className="h-48 w-full rounded-3xl" />
      </div>
    );
  }

  if (!product || !selectedSeries) {
    return (
      <div className="mx-auto max-w-xl py-12">
        <Card>
          <EmptyState
            title="No active markets available"
            body="Check back soon when new option expiries are listed."
            action={
              <Link to="/" className="btn-primary mt-3 text-xs">
                Back to Markets
              </Link>
            }
          />
        </Card>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-xl space-y-6 py-2 sm:py-6">
      {/* Top Breadcrumb & Education Link */}
      <div className="flex items-center justify-between text-xs">
        <Link to="/" className="text-muted hover:text-primary transition font-semibold">
          ← Back to Markets
        </Link>
        <button onClick={openGuide} className="text-primary hover:underline flex items-center gap-1 font-semibold">
          <HelpCircle className="h-3.5 w-3.5" /> How does this work?
        </button>
      </div>

      {/* Main Swap-Like Card */}
      <div className="relative overflow-hidden rounded-3xl border border-line bg-surface/90 p-5 sm:p-7 backdrop-blur-2xl shadow-2xl space-y-6">
        {/* Header */}
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-xl sm:text-2xl font-black tracking-tight text-ink flex items-center gap-2">
              Instant Option Trade
            </h1>
            <p className="text-xs text-muted mt-0.5">Pick your market prediction in 3 simple steps</p>
          </div>
          <div className="flex items-center gap-1.5 rounded-full bg-good/15 px-3 py-1 text-xs font-bold text-good">
            <ShieldCheck className="h-4 w-4" /> 100% Capped Risk
          </div>
        </div>

        {/* STEP 1: Direction Selection */}
        <div>
          <label className="text-xs font-bold text-muted uppercase tracking-wider block mb-2">
            1. What's your prediction for {product.underlyingSymbol}?
          </label>
          <div className="grid grid-cols-2 gap-3">
            <button
              type="button"
              onClick={() => {
                setDirection("call");
                setSelectedSeriesId(undefined);
              }}
              className={cx(
                "flex items-center gap-3 rounded-2xl border p-3.5 text-left transition-all active:scale-[0.98]",
                direction === "call"
                  ? "border-good bg-good/15 shadow-md ring-1 ring-good/40 text-good"
                  : "border-line bg-surface-2/60 text-muted hover:border-good/40 hover:text-ink"
              )}
            >
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-good/20 text-good">
                <TrendingUp className="h-5 w-5" />
              </div>
              <div>
                <span className="block font-black text-sm text-ink">Price Goes UP</span>
                <span className="block text-[11px] font-semibold text-good">Buy CALL Option</span>
              </div>
            </button>

            <button
              type="button"
              onClick={() => {
                setDirection("put");
                setSelectedSeriesId(undefined);
              }}
              className={cx(
                "flex items-center gap-3 rounded-2xl border p-3.5 text-left transition-all active:scale-[0.98]",
                direction === "put"
                  ? "border-bad bg-bad/15 shadow-md ring-1 ring-bad/40 text-bad"
                  : "border-line bg-surface-2/60 text-muted hover:border-bad/40 hover:text-ink"
              )}
            >
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-bad/20 text-bad">
                <TrendingDown className="h-5 w-5" />
              </div>
              <div>
                <span className="block font-black text-sm text-ink">Price Drops</span>
                <span className="block text-[11px] font-semibold text-bad">Buy PUT Option</span>
              </div>
            </button>
          </div>
        </div>

        {/* STEP 2: Target Price & Expiry */}
        <div>
          <div className="flex items-center justify-between mb-2">
            <label className="text-xs font-bold text-muted uppercase tracking-wider">
              2. Target Price & Expiry Date
            </label>
            {productMarket && (
              <span className="text-xs text-muted font-medium">
                Spot now: <b className="num text-ink font-bold">${fmtWad(productMarket.spotWad, 0)}</b>
              </span>
            )}
          </div>

          {/* Expiry Selector Pills */}
          <div className="flex gap-2 overflow-x-auto pb-1 mb-3 scrollbar-none">
            {expiries.map((exp) => (
              <button
                key={exp.toString()}
                type="button"
                onClick={() => {
                  setSelectedExpiry(exp);
                  setSelectedSeriesId(undefined);
                }}
                className={cx(
                  "whitespace-nowrap rounded-xl px-3 py-1.5 text-xs font-semibold border transition",
                  exp === chosenExpiry
                    ? "border-primary bg-primary-soft text-primary font-bold shadow-sm"
                    : "border-line bg-surface-2 text-muted hover:text-ink"
                )}
              >
                {fmtExpiryShort(exp)} {now !== undefined ? `(${fmtDuration(exp - now)})` : ""}
              </button>
            ))}
          </div>

          {/* Strike Cards */}
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
            {candidates.map((s) => {
              const isSelected = s.id === selectedSeries.id;
              const strike = Number(s.strikeWad) / 1e18;
              const spot = productMarket ? Number(productMarket.spotWad) / 1e18 : undefined;
              const diffPct = spot ? (((strike - spot) / spot) * 100).toFixed(0) : undefined;

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
                  <span className="num text-base font-extrabold">${fmtWad(s.strikeWad, 0)}</span>
                  {diffPct !== undefined && (
                    <span
                      className={cx(
                        "num text-[10px] font-semibold mt-0.5",
                        Number(diffPct) > 0 ? "text-good" : "text-bad"
                      )}
                    >
                      {Number(diffPct) > 0 ? `+${diffPct}%` : `${diffPct}%`}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
        </div>

        {/* STEP 3: Amount & Execution */}
        <div>
          <label className="text-xs font-bold text-muted uppercase tracking-wider block mb-2">
            3. How much do you want to invest?
          </label>
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
            to={`/series/${selectedSeries.id}`}
            className="text-xs text-primary font-semibold hover:underline inline-flex items-center gap-1"
          >
            Switch to Advanced View (Charts & Greeks) <ArrowRight className="h-3 w-3" />
          </Link>
        </div>
      </div>
    </div>
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
          lessSlip(estQty),
          withSlip(fees.data.optara),
          withSlip(fees.data.kuru),
          address
        )
      : undefined;

  // Estimated payout if price moves past strike by 10%
  const strikeNum = Number(series.strikeWad) / 1e18;
  const spotNum = productMarket ? Number(productMarket.spotWad) / 1e18 : strikeNum;
  const estPayoutPerOption =
    series.optionType === 0
      ? Math.max(0, spotNum * 1.15 - strikeNum)
      : Math.max(0, strikeNum - spotNum * 0.85);

  const estTotalPayout = estQty ? (Number(estQty) / 1e18) * estPayoutPerOption : 0;

  return (
    <div className="space-y-4">
      <AmountInput
        label="Investment Amount"
        value={amount}
        onChange={onAmountChange}
        unit={series.assetSymbol}
        presets={["25", "50", "100", "250", "500"]}
        max={balance !== undefined ? fmtNative(balance, series.assetDecimals, 2).replace(/,/g, "") : undefined}
        maxLabel="Wallet"
        invalid={tooMuch ? `Wallet has ${fmtNative(balance!, series.assetDecimals)} ${series.assetSymbol}.` : undefined}
      />

      {/* Outcome projection card */}
      <div className="rounded-2xl border border-line bg-surface-2/80 p-4 space-y-2.5 text-xs">
        <div className="flex items-center justify-between">
          <span className="text-muted">Options you receive:</span>
          <span className="num font-black text-sm text-ink">
            {estQty !== undefined ? `${fmtQty(estQty)} options` : "—"}
          </span>
        </div>

        <div className="flex items-center justify-between">
          <span className="text-muted">Maximum risk:</span>
          <span className="num font-bold text-ink">
            ${amount || "0"} {series.assetSymbol} (100% Capped)
          </span>
        </div>

        <div className="flex items-center justify-between border-t border-line/60 pt-2 font-bold text-good">
          <span>Estimated payout (if target hit):</span>
          <span className="num text-sm font-black">
            +${estTotalPayout.toFixed(2)} {series.assetSymbol}
          </span>
        </div>
      </div>

      <TxButton
        label={estQty ? `Place Trade for $${amount || "0"}` : "Place Trade"}
        steps={steps}
        disabled={!a.enabled || !steps || tooMuch}
        disabledReason={a.reason}
        disclosures={disclosuresFor("buy", series.underlyingSymbol)}
        successMessage="Trade complete! Your options are in your wallet."
      />
    </div>
  );
}
