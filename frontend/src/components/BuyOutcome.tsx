/** What a buy means at expiry, fees included: breakeven, exposure past it, and the most you can lose. */
import { fmtQty } from "../lib/optara/format.ts";
import { breakeven, legOf, moveNeeded, moveText, OVERPAY_CONFIRM, OVERPAY_WARN, overFairValue, priceLevel, usd } from "../lib/optara/payoff.ts";
import type { Series } from "../lib/optara/types.ts";

/**
 * The buy compared with Optara's fair value (the mark), all fees included. `needsAck` is true when the price is far
 * enough above fair value that the buyer must confirm before the Buy button unlocks.
 */
export function buyCheck(qty: bigint | undefined, total: bigint | undefined, decimals: number, mark: bigint | undefined) {
  if (!qty || total === undefined) return { over: undefined, needsAck: false };
  const allIn = Number(total) / 10 ** decimals / (Number(qty) / 1e18);
  const over = overFairValue(allIn, mark !== undefined ? Number(mark) / 1e18 : undefined);
  return { over, needsAck: over !== undefined && over > OVERPAY_CONFIRM };
}

/** The cash a seller receives compared with Optara's fair value. Positive `under` means the seller receives less. */
export function sellCheck(qty: bigint | undefined, proceeds: bigint | undefined, decimals: number, mark: bigint | undefined) {
  if (!qty || proceeds === undefined) return { under: undefined };
  const received = Number(proceeds) / 10 ** decimals / (Number(qty) / 1e18);
  const fair = mark !== undefined ? Number(mark) / 1e18 : undefined;
  if (fair === undefined || !(fair > 0) || !(received > 0)) return { under: undefined };
  return { under: 1 - received / fair };
}

export function BuyOutcome({
  series,
  qty,
  total,
  spot,
  mark,
  ack,
  onAck,
}: {
  series: Series;
  qty?: bigint;
  total?: bigint;
  spot?: number;
  /** Optara's fair value per option (WAD). */
  mark?: bigint;
  ack?: boolean;
  onAck?: (v: boolean) => void;
}) {
  if (qty === undefined || qty === 0n || total === undefined) return null;
  const leg = legOf(series);
  const qtyNum = Number(qty) / 1e18;
  const totalNum = Number(total) / 10 ** series.assetDecimals;
  const be = breakeven(leg, totalNum / qtyNum);
  const beMove = be !== undefined && spot !== undefined ? moveNeeded(leg, spot, be) : undefined;
  const isCall = series.optionType === 0;
  const stepRef = be ?? spot ?? leg.strike;
  const moveStepPct = stepRef < 1 ? 1 : 5;
  const moveStep = stepRef * (moveStepPct / 100);
  const stepProfit = qtyNum * leg.size * moveStep;
  const covers = qtyNum * leg.size;
  const allIn = totalNum / qtyNum;
  const { over, needsAck } = buyCheck(qty, total, series.assetDecimals, mark);
  const tone = over === undefined ? "" : over > OVERPAY_CONFIRM ? "border-bad/40 bg-bad/8" : over > OVERPAY_WARN ? "border-warn/40 bg-warn/8" : "border-line bg-surface-2/60";

  const exposureText = `${covers.toLocaleString("en-US", { maximumFractionDigits: 2 })} ${series.underlyingSymbol}`;
  const exposureHelp = spot !== undefined ? `About ${usd(covers * spot)} of ${series.underlyingSymbol} exposure today. Payout only starts past strike.` : "Payout only starts past strike.";
  const breakevenHelp = beMove === undefined ? undefined : beMove <= 0 ? "Already past breakeven at the current spot." : `${moveText(leg, beMove)} from today's spot.`;
  const stepLabel = `${moveStepPct}% ${isCall ? "above" : "below"} breakeven`;

  return (
    <div className="space-y-3">
      <div className="grid gap-2 border-t border-line/60 pt-3 sm:grid-cols-2">
        <BuyMetric label="Payoff exposure" value={exposureText} help={exposureHelp} />
        <BuyMetric
          label={`Profit starts ${isCall ? "above" : "below"}`}
          value={be !== undefined ? priceLevel(be) : "—"}
          help={breakevenHelp}
        />
        <BuyMetric
          label={`If settlement is ${stepLabel}`}
          value={usd(stepProfit, { sign: true })}
          help="Estimated profit after premium and fees."
          tone="good"
        />
        <BuyMetric label="Maximum loss" value={usd(totalNum)} help="This is the total you sign for this buy." tone="bad" />
      </div>

    {over !== undefined && (
      <div className={`rounded-2xl border p-3 text-[13px] ${tone}`}>
        <div className="grid gap-2 sm:grid-cols-2">
          <div>
            <div className="text-[11px] font-bold uppercase text-faint">All-in price</div>
            <div className="num mt-0.5 font-display text-lg font-bold text-ink">{usd(allIn)}</div>
            <div className="text-[11px] text-muted">per option, fees included</div>
          </div>
          <div>
            <div className="text-[11px] font-bold uppercase text-faint">Optara mark</div>
            <div className="num mt-0.5 font-display text-lg font-bold text-ink">{usd(Number(mark) / 1e18)}</div>
            <div className="text-[11px] text-muted">model fair value</div>
          </div>
        </div>
        <p className={over > OVERPAY_CONFIRM ? "mt-2 font-semibold text-bad" : over > OVERPAY_WARN ? "mt-2 font-semibold text-warn" : "mt-2 text-muted"}>
          {over <= 0
            ? "This order is at or below Optara's current mark."
            : over > OVERPAY_WARN
            ? `This order is ${(over * 100).toFixed(0)}% above Optara's mark because it fills the current asks plus fees. A smaller amount, or another strike or expiry, may price better.`
            : `${(over * 100).toFixed(1)}% above Optara's mark from spread and fees.`}
        </p>
        {needsAck && onAck && (
          <label className="mt-2 flex cursor-pointer items-start gap-2 font-semibold">
            <input type="checkbox" className="mt-0.5 h-4 w-4" checked={!!ack} onChange={(e) => onAck(e.target.checked)} />
            <span>I understand I'm paying {(over * 100).toFixed(0)}% more than this option's fair value.</span>
          </label>
        )}
      </div>
    )}
    </div>
  );
}

function BuyMetric({
  label,
  value,
  help,
  tone,
}: {
  label: string;
  value: string;
  help?: string;
  tone?: "good" | "bad";
}) {
  return (
    <div className="min-w-0 rounded-xl border border-line bg-surface px-3 py-2.5">
      <div className="text-[11px] font-bold uppercase text-faint">{label}</div>
      <div className={`num mt-1 break-words font-display text-lg font-bold ${tone === "good" ? "text-good" : tone === "bad" ? "text-bad" : "text-ink"}`}>
        {value}
      </div>
      {help && <div className="mt-1 text-[11px] leading-4 text-muted">{help}</div>}
    </div>
  );
}

export function SellValueNotice({
  qty,
  proceeds,
  decimals,
  mark,
}: {
  qty?: bigint;
  /** Seller proceeds after order-book fees, in native settlement units. */
  proceeds?: bigint;
  decimals: number;
  /** Optara's fair value per option (WAD). */
  mark?: bigint;
}) {
  const { under } = sellCheck(qty, proceeds, decimals, mark);
  if (!qty || qty === 0n || proceeds === undefined || under === undefined) return null;
  const received = Number(proceeds) / 10 ** decimals / (Number(qty) / 1e18);
  const tone = under > OVERPAY_CONFIRM ? "border-bad/40 bg-bad/8" : under > OVERPAY_WARN ? "border-warn/40 bg-warn/8" : "border-line bg-surface-2/60";

  return (
    <div className={`rounded-xl border px-3 py-2.5 text-[13px] ${tone}`}>
      <div className="flex justify-between gap-3">
        <span className="text-muted">You receive per option, fees deducted</span>
        <span className="num shrink-0 font-semibold">{usd(received)}</span>
      </div>
      <div className="flex justify-between gap-3">
        <span className="text-muted">Optara fair value</span>
        <span className="num shrink-0 font-semibold">{usd(Number(mark) / 1e18)}</span>
      </div>
      <p className={under > OVERPAY_CONFIRM ? "mt-1.5 font-semibold text-bad" : under > OVERPAY_WARN ? "mt-1.5 font-semibold text-warn" : "mt-1.5 text-muted"}>
        {under <= 0
          ? `You receive ${Math.abs(under * 100).toFixed(under < -0.1 ? 0 : 1)}% above fair value.`
          : under > OVERPAY_WARN
          ? `You receive ${(under * 100).toFixed(0)}% below fair value. This sale fills the current bids, and buyers are bidding below Optara's mark right now. A smaller amount, or a different strike or expiry, may price better.`
          : `${(under * 100).toFixed(1)}% below fair value: order-book spread plus fees.`}
      </p>
    </div>
  );
}
