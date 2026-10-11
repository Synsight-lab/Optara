/**
 * What a market buy can fill right now, from the venue's resting asks (Kuru's L2 book). Prices are quote per option
 * and sizes are options, both WAD. A market buy walks the asks from the best price up, so the honest estimate for a
 * budget is the walk, not budget ÷ best ask (which over-promises as soon as the first level is too small).
 */
const WAD = 10n ** 18n;

export interface AskLevel {
  price: bigint;
  size: bigint;
}

export interface AskFill {
  /** Options the budget buys (all of the book when the budget is larger than the book). */
  qty: bigint;
  /** Quote the fill spends, WAD. */
  cost: bigint;
  /** Price levels the fill touches. */
  levels: number;
  /** The budget is bigger than every resting ask: the rest is refunded. */
  exhausted: boolean;
  /** Everything for sale right now, and what buying all of it costs (WAD). */
  depthQty: bigint;
  depthCost: bigint;
}

/** Walk `asks` (best first) with `budget` (quote, WAD). Without a budget, only the depth totals are meaningful. */
export function fillFromAsks(asks: AskLevel[], budget = 0n): AskFill {
  let left = budget;
  let qty = 0n;
  let cost = 0n;
  let levels = 0;
  let depthQty = 0n;
  let depthCost = 0n;
  for (const l of asks) {
    if (l.price <= 0n || l.size <= 0n) continue;
    const levelCost = (l.size * l.price) / WAD;
    depthQty += l.size;
    depthCost += levelCost;
    if (left <= 0n) continue;
    levels += 1;
    if (left >= levelCost) {
      qty += l.size;
      cost += levelCost;
      left -= levelCost;
    } else {
      const part = (left * WAD) / l.price;
      qty += part;
      cost += (part * l.price) / WAD;
      left = 0n;
    }
  }
  return { qty, cost, levels, exhausted: depthQty > 0n && qty === depthQty && budget > depthCost, depthQty, depthCost };
}
