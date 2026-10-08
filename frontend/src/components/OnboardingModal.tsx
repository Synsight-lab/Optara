import { useState } from "react";
import { ArrowRight, BookOpen, CheckCircle2, ChevronRight, HelpCircle, ShieldCheck, Sparkles, TrendingDown, TrendingUp, X } from "lucide-react";
import { useQuickGuide } from "../state.tsx";
import { cx } from "./ui.tsx";

export function OnboardingModal() {
  const { isOpen, close } = useQuickGuide();
  const [activeTab, setActiveTab] = useState<"basics" | "calls-puts" | "buyer-safety" | "simulator">("basics");
  const [simPrice, setSimPrice] = useState(3400);

  if (!isOpen) return null;

  // Simulator math for a $3,000 Call bought for $60
  const strike = 3000;
  const premium = 60;
  const grossPayout = Math.max(0, simPrice - strike);
  const netProfit = grossPayout - premium;
  const roi = ((netProfit / premium) * 100).toFixed(0);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4 backdrop-blur-md">
      <div
        className="ticket relative max-h-[88vh] w-full max-w-2xl overflow-y-auto p-5 sm:p-7"
        role="dialog"
        aria-modal="true"
        aria-labelledby="guide-title"
      >
        <button
          onClick={close}
          className="absolute right-4 top-4 rounded-full p-2 text-muted transition hover:bg-surface-2 hover:text-ink cursor-pointer"
          aria-label="Close guide"
        >
          <X className="h-5 w-5" />
        </button>

        <div className="flex items-center gap-3">
          <div className="font-display grid h-10 w-10 place-items-center rounded-2xl bg-primary text-lg font-bold text-white">
            O
          </div>
          <div>
            <h2 id="guide-title" className="font-display text-xl font-bold tracking-tight">
              Options in 60 seconds
            </h2>
            <p className="text-[13px] text-muted">Pick direction, pay once, settle in cash</p>
          </div>
        </div>

        <div className="mt-5 flex gap-1.5 overflow-x-auto rounded-xl border border-line bg-surface-2/70 p-1 scrollbar-none">
          {[
            { id: "basics", label: "The Basics" },
            { id: "calls-puts", label: "Calls vs Puts" },
            { id: "buyer-safety", label: "Risk & Safety" },
            { id: "simulator", label: "Interactive Calculator" },
          ].map((t) => (
            <button
              key={t.id}
              onClick={() => setActiveTab(t.id as any)}
              className={cx(
                "whitespace-nowrap rounded-xl px-3.5 py-1.5 text-xs font-semibold transition",
                activeTab === t.id
                  ? "bg-primary text-white shadow-sm"
                  : "text-muted hover:bg-surface-2 hover:text-ink"
              )}
            >
              {t.label}
            </button>
          ))}
        </div>

        {/* Tab Contents */}
        <div className="mt-5 min-h-[260px]">
          {activeTab === "basics" && (
            <div className="space-y-4">
              <p className="text-sm leading-relaxed text-muted">
                An <b className="text-ink">option</b> gives you the right to earn money if a cryptocurrency (like ETH or MON) reaches a target price by a specific expiry date.
              </p>
              <div className="grid gap-3 sm:grid-cols-2">
                <div className="rounded-2xl border border-line bg-surface-2/60 p-4">
                  <div className="flex items-center gap-2 text-primary font-semibold text-sm">
                    <TrendingUp className="h-4 w-4" /> 1. Pick Your View
                  </div>
                  <p className="mt-1 text-xs text-muted">
                    Think the price will go up? Buy a <b className="text-ink">Call</b>. Think it will drop? Buy a <b className="text-ink">Put</b>.
                  </p>
                </div>
                <div className="rounded-2xl border border-line bg-surface-2/60 p-4">
                  <div className="flex items-center gap-2 text-good font-semibold text-sm">
                    <ShieldCheck className="h-4 w-4" /> 2. Pay Once, Zero Surprise
                  </div>
                  <p className="mt-1 text-xs text-muted">
                    Pay a small price upfront. If you are wrong, you can <b className="text-ink">never lose more</b> than what you spent.
                  </p>
                </div>
              </div>
              <div className="rounded-2xl border border-line bg-surface-2/60 p-4">
                <div className="flex items-center gap-2 text-accent font-semibold text-sm">
                  <CheckCircle2 className="h-4 w-4" /> 3. Automatic Cash Settlement
                </div>
                <p className="mt-1 text-xs text-muted">
                  No need to manually buy the underlying coin. At expiry, your profit is calculated automatically and sent directly to your wallet in USDC.
                </p>
              </div>
            </div>
          )}

          {activeTab === "calls-puts" && (
            <div className="space-y-4">
              <div className="grid gap-4 sm:grid-cols-2">
                <div className="rounded-2xl border border-good/30 bg-good/5 p-4.5">
                  <div className="flex items-center justify-between">
                    <span className="pill bg-good/20 text-good font-bold">CALL OPTION</span>
                    <TrendingUp className="h-5 w-5 text-good" />
                  </div>
                  <h3 className="mt-2 text-base font-bold text-ink">Bet on Price Rising</h3>
                  <p className="mt-1 text-xs leading-relaxed text-muted">
                    You predict ETH will rise above the strike (e.g. $3,000). The higher ETH climbs, the bigger your payout!
                  </p>
                  <div className="mt-3 rounded-xl bg-surface/80 p-2.5 text-xs">
                    <span className="text-muted">Example:</span> ETH ends at $3,500 → You get paid <b className="text-good font-semibold">+$500</b> per option.
                  </div>
                </div>

                <div className="rounded-2xl border border-bad/30 bg-bad/5 p-4.5">
                  <div className="flex items-center justify-between">
                    <span className="pill bg-bad/20 text-bad font-bold">PUT OPTION</span>
                    <TrendingDown className="h-5 w-5 text-bad" />
                  </div>
                  <h3 className="mt-2 text-base font-bold text-ink">Bet on Price Falling</h3>
                  <p className="mt-1 text-xs leading-relaxed text-muted">
                    You predict ETH will fall below the strike (e.g. $2,800). Great for profiting from market dumps or hedging your crypto bag!
                  </p>
                  <div className="mt-3 rounded-xl bg-surface/80 p-2.5 text-xs">
                    <span className="text-muted">Example:</span> ETH drops to $2,300 → You get paid <b className="text-good font-semibold">+$500</b> per option.
                  </div>
                </div>
              </div>
            </div>
          )}

          {activeTab === "buyer-safety" && (
            <div className="space-y-3.5">
              <div className="rounded-2xl border border-good/30 bg-good/10 p-4">
                <div className="flex items-center gap-2 font-bold text-good text-sm">
                  <ShieldCheck className="h-5 w-5" /> 100% Limited Risk for Buyers
                </div>
                <p className="mt-1 text-xs text-muted leading-relaxed">
                  Unlike futures or perpetual leverage where market spikes can liquidate you, <b className="text-ink">buying an option has ZERO liquidation risk</b>. You can never owe extra money.
                </p>
              </div>

              <div className="rounded-2xl border border-line bg-surface-2 p-4">
                <div className="font-semibold text-ink text-sm">What about Writing (Selling) Options?</div>
                <p className="mt-1 text-xs text-muted leading-relaxed">
                  Option writers act as liquidity providers who collect upfront premiums from buyers. Because writers owe the payout at expiry, they must deposit stablecoin collateral and maintain a healthy margin.
                </p>
              </div>

              <div className="rounded-2xl border border-primary/20 bg-primary-soft/50 p-3.5 text-xs text-muted">
                💡 <b className="text-ink">New to options?</b> Start by <b className="text-ink">buying</b> a Call or Put. It requires no margin setup and your tokens land directly in your wallet!
              </div>
            </div>
          )}

          {activeTab === "simulator" && (
            <div className="space-y-4">
              <div className="rounded-2xl border border-line bg-surface-2 p-4">
                <div className="flex items-center justify-between text-xs text-muted">
                  <span>Scenario: <b className="text-ink">ETH $3,000 Call</b></span>
                  <span>Cost: <b className="text-ink">${premium}</b></span>
                </div>

                <div className="mt-4">
                  <div className="flex justify-between text-xs font-semibold">
                    <span>If ETH settles at:</span>
                    <span className="num text-primary text-sm">${simPrice.toLocaleString()}</span>
                  </div>
                  <input
                    type="range"
                    min="2700"
                    max="4000"
                    step="25"
                    value={simPrice}
                    onChange={(e) => setSimPrice(Number(e.target.value))}
                    className="mt-2 w-full accent-[var(--primary)] cursor-pointer"
                  />
                  <div className="flex justify-between text-[10px] text-muted mt-1">
                    <span>$2,700 (Drop)</span>
                    <span>$3,000 (Strike)</span>
                    <span>$4,000 (Moon)</span>
                  </div>
                </div>

                <div className="mt-4 grid grid-cols-3 gap-2 border-t border-line pt-3 text-center">
                  <div>
                    <div className="text-[10px] text-muted">Gross Payout</div>
                    <div className="num mt-0.5 text-sm font-semibold">${grossPayout}</div>
                  </div>
                  <div>
                    <div className="text-[10px] text-muted">Net Profit / Loss</div>
                    <div className={cx("num mt-0.5 text-sm font-bold", netProfit >= 0 ? "text-good" : "text-bad")}>
                      {netProfit >= 0 ? `+$${netProfit}` : `-$${Math.abs(netProfit)}`}
                    </div>
                  </div>
                  <div>
                    <div className="text-[10px] text-muted">Return (ROI)</div>
                    <div className={cx("num mt-0.5 text-sm font-bold", netProfit >= 0 ? "text-good" : "text-bad")}>
                      {netProfit >= 0 ? `+${roi}%` : `${roi}%`}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Footer Actions */}
        <div className="mt-6 flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4">
          <div className="text-xs text-muted flex items-center gap-1.5">
            <HelpCircle className="h-4 w-4 text-primary" />
            No margin needed to buy. You only risk what you pay.
          </div>
          <div className="flex gap-2">
            <button
              onClick={() => {
                close();
              }}
              className="btn-primary text-xs"
            >
              Start trading <ArrowRight className="h-3.5 w-3.5 ml-1 inline" />
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
