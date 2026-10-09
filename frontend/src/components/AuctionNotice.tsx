/** A running liquidation auction on one of your accounts, and how to end it (LiquidationModule.endAuction, F8). */
import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router";
import type { Address } from "viem";
import { endAuctionSteps } from "../lib/optara/actions.ts";
import { fmtBps, fmtDuration, fmtWad } from "../lib/optara/format.ts";
import { useChainTime } from "../lib/optara/hooks.ts";
import { auctionEndTarget, getAuction } from "../lib/optara/reads.ts";
import { TxButton } from "./TxButton.tsx";

export function AuctionNotice({ accountId, underlying, symbol, mine }: { accountId: bigint; underlying: Address; symbol: string; mine: boolean }) {
  const { data: now } = useChainTime();
  const { data: auction } = useQuery({ queryKey: ["auction", accountId.toString(), underlying], queryFn: () => getAuction(accountId, underlying), refetchInterval: 6_000 });
  const { data: t } = useQuery({ queryKey: ["auctionTarget", accountId.toString()], queryFn: () => auctionEndTarget(accountId), refetchInterval: 6_000 });
  if (!auction || auction.start === 0n) return null;
  const canEnd = !!t && t.equity >= 0n && t.equity >= t.target;
  const short = t && t.target > t.equity ? t.target - t.equity : 0n;

  return (
    <div className={canEnd ? "rounded-2xl border border-warn/40 bg-warn/10 p-4" : "rounded-2xl border border-bad/40 bg-bad/10 p-4"}>
      <p className="text-[13px] font-semibold">
        {mine ? "A liquidation auction is running on your" : `A liquidation auction is running on account #${accountId}'s`} {symbol} positions
        {now !== undefined ? ` (for ${fmtDuration(now - auction.start)})` : ""}.
      </p>
      <p className="mt-1 text-[13px] leading-relaxed text-muted">
        While it runs, anyone can take over slices of {mine ? "your" : "its"} positions, at a discount that is now{" "}
        <b className="text-ink">{fmtBps(auction.bonusBps, 1)}</b> and grows over time. It can be ended once the account value is at least{" "}
        <b className="text-ink">${t ? fmtWad(t.target, 2) : "…"}</b> (what's needed to open positions, plus a safety buffer).{" "}
        {t && (canEnd ? "That's met now." : `Now $${fmtWad(t.equity < 0n ? 0n : t.equity, 2)}: $${fmtWad(short, 2)} short.`)}
      </p>
      <div className="mt-3 flex flex-wrap items-center gap-3">
        <div className="min-w-[220px] flex-1">
          <TxButton
            label="End the auction"
            steps={endAuctionSteps(accountId, underlying)}
            disabled={!canEnd}
            disabledReason={canEnd ? undefined : mine ? "Add cash or close positions first, then end it." : "The account isn't back above its target yet."}
            successMessage="Auction ended. Nobody can take slices of these positions now."
          />
        </div>
        {mine && !canEnd && (
          <Link to="/app/portfolio" onClick={() => document.getElementById("cash-card")?.scrollIntoView({ behavior: "smooth" })} className="text-[13px] font-semibold text-primary">
            Add cash ↓
          </Link>
        )}
      </div>
    </div>
  );
}
