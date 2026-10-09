import { useState } from "react";
import { NavLink, Outlet, Link } from "react-router";
import {
  Activity,
  Coins,
  Compass,
  HelpCircle,
  LockKeyhole,
  Menu,
  Moon,
  PieChart,
  Server,
  ShieldAlert,
  Sun,
  X,
  Zap,
  type LucideIcon,
} from "lucide-react";
import { fmtLevel, fmtWad } from "../lib/optara/format.ts";
import { useProductMarket, useSeriesList } from "../lib/optara/hooks.ts";
import { useQuickGuide, useTheme } from "../state.tsx";
import { ConnectButton } from "./ConnectButton.tsx";
import { OnboardingModal } from "./OnboardingModal.tsx";
import { Toaster } from "./Toaster.tsx";
import { cx } from "./ui.tsx";
import { TokenIcon } from "./Icons.tsx";

export function Layout() {
  const [theme, toggleTheme] = useTheme();
  const { open: openGuide } = useQuickGuide();
  const [moreOpen, setMoreOpen] = useState(false);

  return (
    <div className="app-shell flex min-h-screen flex-col overflow-x-clip">
      <header className="sticky top-0 z-40 border-b border-line bg-bg/90 backdrop-blur-xl">
        <div className="app-column flex h-[64px] items-center gap-3">
          <Link to="/" className="flex shrink-0 items-center gap-2" aria-label="Optara home">
            <img src="/brand/logo/optara-lockup-light.svg" alt="Optara" className="theme-logo-light h-9 w-auto" />
            <img src="/brand/logo/optara-lockup-dark.svg" alt="Optara" className="theme-logo-dark h-9 w-auto" />
          </Link>

          <div className="ml-auto flex min-w-0 items-center gap-2">
            <div className="hidden items-center rounded-2xl border border-line bg-surface/70 p-1 shadow-sm lg:flex">
              <DesktopNav to="/app/markets" label="Markets" icon={Compass} />
              <DesktopNav to="/app/write" label="Earn" icon={Coins} />
              <DesktopNav to="/app/portfolio" label="Portfolio" icon={PieChart} />
            </div>
            <div className="hidden items-center rounded-2xl border border-line bg-surface/70 p-1 shadow-sm xl:flex">
              <DesktopNav to="/app/settlement" label="Settle" icon={Activity} />
              <DesktopNav to="/app/liquidations" label="Risk" icon={ShieldAlert} />
              <DesktopNav to="/app/admin" label="Admin" icon={LockKeyhole} />
              <DesktopNav to="/app/system" label="System" icon={Server} />
            </div>
            <button
              onClick={openGuide}
              className="hidden rounded-xl border border-line bg-surface/70 px-3 py-2 text-[13px] font-semibold text-muted transition hover:bg-surface-2 hover:text-ink md:inline-flex md:items-center md:gap-1.5"
            >
              <HelpCircle className="h-4 w-4" /> Guide
            </button>
            <div className="hidden sm:block">
              <SpotPill />
            </div>
            <button
              className="cursor-pointer rounded-xl border border-line bg-surface/70 p-2 text-muted transition hover:bg-surface-2 hover:text-ink"
              onClick={toggleTheme}
              aria-label="Toggle theme"
            >
              {theme === "dark" ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
            </button>
            <ConnectButton />
          </div>
        </div>
      </header>

      <main className="app-column w-full flex-1 pb-28 pt-3 sm:pt-4 md:pb-8 md:pt-6">
        <Outlet />
      </main>

      {/* Bottom tab bar — always visible, app-style */}
      <nav className="fixed inset-x-0 bottom-0 z-40 bg-transparent px-3 pb-3 safe-area-pb md:hidden" aria-label="App">
        <div className="mx-auto grid max-w-[520px] grid-cols-5 items-end rounded-3xl border border-line bg-surface/92 px-1 pb-1 pt-1.5 shadow-2xl backdrop-blur-2xl">
          <MobileTab to="/app/markets" label="Markets" icon={Compass} />
          <MobileTab to="/app/write" label="Earn" icon={Coins} />
          <MobileTab to="/app/portfolio" label="Portfolio" icon={PieChart} />
          <MobileTab to="/app/settlement" label="Settle" icon={Activity} />
          <button onClick={() => setMoreOpen(true)} className="flex flex-col items-center gap-1 py-1 text-muted cursor-pointer">
            <Menu className="h-5 w-5" />
            <span className="text-[11px] font-semibold">More</span>
          </button>
        </div>
      </nav>

      {moreOpen && (
        <div className="fixed inset-0 z-50 flex flex-col items-center justify-end bg-black/60 p-4 backdrop-blur-sm" onClick={() => setMoreOpen(false)}>
          <div className="w-full max-w-[440px] rounded-3xl border border-line bg-surface space-y-2 p-4 safe-area-pb" onClick={(e) => e.stopPropagation()}>
            <div className="mb-1 flex items-center justify-between">
              <span className="font-display text-sm font-semibold">More</span>
              <button onClick={() => setMoreOpen(false)} className="rounded-full p-1.5 text-muted cursor-pointer" aria-label="Close">
                <X className="h-5 w-5" />
              </button>
            </div>
            <Link to="/app/write" onClick={() => setMoreOpen(false)} className="flex items-center gap-2.5 rounded-2xl border border-accent/40 bg-accent/10 p-3.5 text-sm font-semibold text-accent">
              <Coins className="h-4 w-4" /> Earn: write options
            </Link>
            <Link to="/app/new" onClick={() => setMoreOpen(false)} className="flex items-center gap-2.5 rounded-2xl border border-primary/40 bg-primary-soft p-3.5 text-sm font-semibold text-primary">
              <Zap className="h-4 w-4" /> New market
            </Link>
            <Link to="/app/liquidations" onClick={() => setMoreOpen(false)} className="flex items-center gap-2.5 rounded-2xl border border-line bg-surface-2 p-3.5 text-sm font-semibold">
              <ShieldAlert className="h-4 w-4 text-warn" /> Liquidation auctions
            </Link>
            <Link to="/app/admin" onClick={() => setMoreOpen(false)} className="flex items-center gap-2.5 rounded-2xl border border-line bg-surface-2 p-3.5 text-sm font-semibold">
              <LockKeyhole className="h-4 w-4 text-primary" /> Admin controls
            </Link>
            <Link to="/app/system" onClick={() => setMoreOpen(false)} className="flex items-center gap-2.5 rounded-2xl border border-line bg-surface-2 p-3.5 text-sm font-semibold">
              <Server className="h-4 w-4 text-primary" /> System status
            </Link>
            <button onClick={() => { setMoreOpen(false); openGuide(); }} className="flex w-full items-center gap-2.5 rounded-2xl border border-line bg-surface-2 p-3.5 text-left text-sm font-semibold cursor-pointer">
              Learn how options work
            </button>
          </div>
        </div>
      )}

      <OnboardingModal />
      <Toaster />
    </div>
  );
}

function DesktopNav({ to, label, icon: Icon }: { to: string; label: string; icon: LucideIcon }) {
  return (
    <NavLink
      to={to}
      end={to === "/"}
      className={({ isActive }) =>
        cx(
          "inline-flex items-center gap-1.5 rounded-xl px-3 py-2 text-[13px] font-semibold transition",
          isActive ? "bg-primary text-white shadow-sm" : "text-muted hover:bg-surface-2 hover:text-ink",
        )
      }
    >
      <Icon className="h-3.5 w-3.5" />
      {label}
    </NavLink>
  );
}

function MobileTab({ to, label, icon: Icon }: { to: string; label: string; icon: typeof Compass }) {
  return (
    <NavLink to={to} end={to === "/"} className={({ isActive }) => cx("flex min-h-[56px] flex-col items-center justify-center gap-0.5 rounded-2xl py-1 transition", isActive ? "text-ink" : "text-muted")}>
      {({ isActive }) => (
        <>
          <span className={cx("rounded-xl px-2 py-1", isActive && "bg-primary text-white shadow-sm")}><Icon className="h-[22px] w-[22px]" /></span>
          <span className="text-[11px] font-semibold">{label}</span>
        </>
      )}
    </NavLink>
  );
}

function SpotPill() {
  const { data: series } = useSeriesList();
  const first = series?.[0];
  const { data: m } = useProductMarket(first?.productId);
  if (!first || !m) return null;
  return (
    <div className="flex items-center gap-1.5 rounded-xl border border-line bg-surface/70 px-2 py-1.5" title={m.spotFresh ? "Live" : "Delayed"}>
      <TokenIcon symbol={first.underlyingSymbol} className="h-4 w-4" />
      <span className="num font-display text-[13px] font-semibold">${fmtLevel(m.spotWad)}</span>
      <span className={cx("h-1.5 w-1.5 rounded-full", m.spotFresh ? "live-dot bg-good" : "bg-warn")} />
    </div>
  );
}
