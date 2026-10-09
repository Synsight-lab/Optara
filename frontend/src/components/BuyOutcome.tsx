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

  return (
    <div className="space-y-2.5">
    <ul className="space-y-1.5 border-t border-line/60 pt-2.5 text-[13px]">
      <li className="flex justify-between gap-3">
        <span className="text-muted">
          Payoff exposure
        </span>
        <span className="num shrink-0 text-right font-semibold">
          {covers.toLocaleString("en-US", { maximumFractionDigits: 2 })} {series.underlyingSymbol}
          {spot !== undefined && <span className="block text-[11px] font-medium text-muted">notional ≈ {usd(covers * spot)} today, paid only past strike</span>}
        </span>
      </li>
      <li className="flex justify-between gap-3">
        <span className="text-muted">You profit if {series.underlyingSymbol} ends {isCall ? "above" : "below"}</span>
        <span className="num shrink-0 text-right font-semibold">
          {be !== undefined ? priceLevel(be) : "—"}
          {beMove !== undefined && (
            <span className="block text-[11px] font-medium text-muted">
              {beMove <= 0 ? "already there today" : `${moveText(leg, beMove)} from today`}
            </span>
          )}
        </span>
      </li>
      <li className="flex justify-between gap-3">
        <span className="text-muted">
          If it settles {moveStepPct}% {isCall ? "above" : "below"} breakeven
        </span>
        <span className="num shrink-0 text-right font-semibold text-good">
          {usd(stepProfit, { sign: true })}
          <span className="block text-[11px] font-medium text-muted">profit after cost</span>
        </span>
      </li>
      <li className="flex justify-between gap-3">
        <span className="text-muted">Most you can lose</span>
        <span className="num shrink-0 font-semibold">{usd(totalNum)}</span>
      </li>
    </ul>

    {over !== undefined && (
      <div className={`rounded-xl border px-3 py-2.5 text-[13px] ${tone}`}>
        <div className="flex justify-between gap-3">
          <span className="text-muted">You pay per option, fees included</span>
          <span className="num shrink-0 font-semibold">{usd(allIn)}</span>
        </div>
        <div className="flex justify-between gap-3">
          <span className="text-muted">Optara fair value</span>
          <span className="num shrink-0 font-semibold">{usd(Number(mark) / 1e18)}</span>
        </div>
        <p className={over > OVERPAY_CONFIRM ? "mt-1.5 font-semibold text-bad" : over > OVERPAY_WARN ? "mt-1.5 font-semibold text-warn" : "mt-1.5 text-muted"}>
          {over <= 0
            ? "You pay at or below fair value."
            : over > OVERPAY_WARN
            ? `You pay ${(over * 100).toFixed(0)}% above fair value. This buy fills the current asks, and the all-in price is above Optara's mark. A smaller amount, or a different strike or expiry, may price better.`
            : `${(over * 100).toFixed(1)}% above fair value: order-book spread plus fees.`}
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
