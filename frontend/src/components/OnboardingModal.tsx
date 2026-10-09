import { ArrowRight, CheckCircle2, HelpCircle, ShieldAlert, ShieldCheck, TrendingDown, TrendingUp, Wallet, X } from "lucide-react";
import { useQuickGuide } from "../state.tsx";
import { cx } from "./ui.tsx";

export function OnboardingModal() {
  const { isOpen, close } = useQuickGuide();

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4 backdrop-blur-md">
      <div
        className="ticket relative max-h-[88vh] w-full max-w-3xl overflow-y-auto p-5 sm:p-7"
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

        <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div className="font-display grid h-10 w-10 place-items-center rounded-2xl bg-primary text-lg font-bold text-white">
            O
          </div>
          <div className="min-w-0 flex-1">
            <h2 id="guide-title" className="font-display text-2xl font-bold tracking-tight">
              Simple Optara guide
            </h2>
            <p className="mt-1 max-w-xl text-sm leading-6 text-muted">
              Optara has two main actions: <b className="text-ink">buy</b> an option with fixed risk, or <b className="text-ink">write</b> an option to earn premium with margin risk.
            </p>
          </div>
        </div>

        <div className="mt-5 grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
          <section className="rounded-3xl border border-good/30 bg-good/8 p-4">
            <div className="flex items-start gap-3">
              <span className="grid h-10 w-10 shrink-0 place-items-center rounded-2xl bg-good/12 text-good">
                <ShieldCheck className="h-5 w-5" />
              </span>
              <div>
                <h3 className="font-display text-lg font-bold">Buy options</h3>
                <p className="mt-1 text-sm leading-6 text-muted">
                  Use this when you want exposure without liquidation risk.
                </p>
              </div>
            </div>
            <div className="mt-4 space-y-2.5">
              <GuidePoint icon={TrendingUp} title="Call means up" text="You profit if the asset finishes above the target price." tone="good" />
              <GuidePoint icon={TrendingDown} title="Put means down" text="You profit if the asset finishes below the target price." tone="bad" />
              <GuidePoint icon={Wallet} title="You pay once" text="Your maximum loss is the premium shown before you sign." tone="primary" />
            </div>
          </section>

          <section className="rounded-3xl border border-warn/35 bg-warn/8 p-4">
            <div className="flex items-start gap-3">
              <span className="grid h-10 w-10 shrink-0 place-items-center rounded-2xl bg-warn/12 text-warn">
                <ShieldAlert className="h-5 w-5" />
              </span>
              <div>
                <h3 className="font-display text-lg font-bold">Write options</h3>
                <p className="mt-1 text-sm leading-6 text-muted">
                  Use this when you want to earn premium and can manage collateral.
                </p>
              </div>
            </div>
            <div className="mt-4 space-y-2.5">
              <GuidePoint icon={Wallet} title="Deposit cash first" text="This cash backs what your account may owe at expiry." tone="warn" />
              <GuidePoint icon={CheckCircle2} title="Stay healthy" text="If margin gets too low, add cash or close risk before liquidation." tone="warn" />
              <GuidePoint icon={HelpCircle} title="Risk can be larger than premium" text="Writing is not the same as buying. You collect premium but take payout risk." tone="bad" />
            </div>
          </section>
        </div>

        <div className="mt-4 rounded-3xl border border-line bg-surface-2/55 p-4">
          <div className="mb-3 flex items-center gap-2">
            <CheckCircle2 className="h-4 w-4 text-primary" />
            <h3 className="font-display text-base font-bold">What happens after you trade?</h3>
          </div>
          <div className="grid gap-2 sm:grid-cols-3">
            {[
              ["1", "Before expiry", "You can keep, sell, or manage the position."],
              ["2", "At expiry", "The official price decides the payout."],
              ["3", "After settlement", "Profitable option tokens can be redeemed for stablecoin."],
            ].map(([n, title, text]) => (
              <div key={n} className="rounded-2xl border border-line bg-surface/80 p-3">
                <div className="grid h-7 w-7 place-items-center rounded-full bg-primary-soft text-xs font-bold text-primary">{n}</div>
                <div className="mt-2 text-sm font-bold">{title}</div>
                <p className="mt-1 text-xs leading-5 text-muted">{text}</p>
              </div>
            ))}
          </div>
        </div>

        <div className="mt-6 flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4">
          <div className="text-xs text-muted flex items-center gap-1.5">
            <HelpCircle className="h-4 w-4 text-primary" />
            New users should usually start by buying, because the maximum loss is shown upfront.
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

function GuidePoint({
  icon: Icon,
  title,
  text,
  tone,
}: {
  icon: typeof TrendingUp;
  title: string;
  text: string;
  tone: "primary" | "good" | "warn" | "bad";
}) {
  return (
    <div className="flex gap-2.5 rounded-2xl border border-line bg-surface/75 p-3">
      <span
        className={cx(
          "mt-0.5 grid h-7 w-7 shrink-0 place-items-center rounded-xl",
          tone === "good" && "bg-good/12 text-good",
          tone === "warn" && "bg-warn/12 text-warn",
          tone === "bad" && "bg-bad/12 text-bad",
          tone === "primary" && "bg-primary-soft text-primary",
        )}
      >
        <Icon className="h-4 w-4" />
      </span>
      <span className="min-w-0">
        <span className="block text-sm font-bold">{title}</span>
        <span className="mt-0.5 block text-xs leading-5 text-muted">{text}</span>
      </span>
    </div>
  );
}
