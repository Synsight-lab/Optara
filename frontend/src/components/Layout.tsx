import { useState } from "react";
import { NavLink, Outlet, Link, useLocation } from "react-router";
import {
  Activity,
  Coins,
  Compass,
  HelpCircle,
  Menu,
  Moon,
  PieChart,
  Server,
  ShieldAlert,
  Sun,
  X,
  Zap,
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
  const location = useLocation();
  const onTrade = location.pathname.startsWith("/trade") || location.pathname.startsWith("/series");

  return (
    <div className="app-shell flex min-h-screen flex-col overflow-x-clip">
      <header className="sticky top-0 z-40 border-b border-line bg-bg/90 backdrop-blur-xl">
        <div className="app-column flex h-[64px] items-center gap-3">
          <Link to="/" className="flex shrink-0 items-center gap-2" aria-label="Optara home">
            <span className="font-display grid h-9 w-9 place-items-center rounded-xl bg-primary text-[18px] font-bold text-white shadow-lg">
              O
            </span>
            <span className="leading-none">
              <span className="font-display block text-[16px] font-bold tracking-tight">
                Optara
              </span>
              <span className="block text-[11px] font-medium text-muted">Options</span>
            </span>
          </Link>

          <div className="ml-auto flex min-w-0 items-center gap-1.5">
            <div className="hidden items-center gap-1 lg:flex">
              <DesktopNav to="/" label="Markets" />
              <DesktopNav to="/trade" label="Trade" />
              <DesktopNav to="/write" label="Earn" />
              <DesktopNav to="/portfolio" label="Portfolio" />
            </div>
            <div className="hidden items-center gap-1 xl:flex">
              <DesktopNav to="/settlement" label="Settle" />
              <DesktopNav to="/liquidations" label="Liquidations" />
              <DesktopNav to="/system" label="System" />
            </div>
            <button
              onClick={openGuide}
              className="hidden rounded-lg border border-line px-3 py-2 text-[13px] font-semibold text-muted transition hover:bg-surface-2 hover:text-ink md:inline-flex md:items-center md:gap-1.5"
            >
              <HelpCircle className="h-4 w-4" /> Guide
            </button>
            <div className="hidden sm:block">
              <SpotPill />
            </div>
            <button
              className="rounded-lg border border-line p-2 text-muted transition hover:text-ink cursor-pointer"
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
      <nav className="fixed inset-x-0 bottom-0 z-40 border-t border-line bg-bg/95 backdrop-blur-2xl safe-area-pb md:hidden" aria-label="App">
        <div className="app-column grid grid-cols-5 items-end px-1 pb-1 pt-1.5">
          <MobileTab to="/" label="Markets" icon={Compass} />
          <MobileTab to="/portfolio" label="Portfolio" icon={PieChart} />
          <Link to="/trade" className="flex flex-col items-center gap-1 pb-0.5" aria-label="Trade">
            <span className={cx("grid h-12 w-12 place-items-center rounded-[18px] shadow-lg active:scale-95 transition", onTrade ? "bg-good text-[#04281c]" : "bg-primary text-white")}>
              <Zap className="h-5 w-5" />
            </span>
            <span className={cx("text-[11px] font-semibold", onTrade ? "text-ink" : "text-muted")}>Trade</span>
          </Link>
          <MobileTab to="/settlement" label="Settle" icon={Activity} />
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
            <Link to="/write" onClick={() => setMoreOpen(false)} className="flex items-center gap-2.5 rounded-2xl border border-accent/40 bg-accent/10 p-3.5 text-sm font-semibold text-accent">
              <Coins className="h-4 w-4" /> Earn: write options
            </Link>
            <Link to="/new" onClick={() => setMoreOpen(false)} className="flex items-center gap-2.5 rounded-2xl border border-primary/40 bg-primary-soft p-3.5 text-sm font-semibold text-primary">
              <Zap className="h-4 w-4" /> New market
            </Link>
            <Link to="/liquidations" onClick={() => setMoreOpen(false)} className="flex items-center gap-2.5 rounded-2xl border border-line bg-surface-2 p-3.5 text-sm font-semibold">
              <ShieldAlert className="h-4 w-4 text-warn" /> Liquidation auctions
            </Link>
            <Link to="/system" onClick={() => setMoreOpen(false)} className="flex items-center gap-2.5 rounded-2xl border border-line bg-surface-2 p-3.5 text-sm font-semibold">
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

function DesktopNav({ to, label }: { to: string; label: string }) {
  return (
    <NavLink
      to={to}
      end={to === "/"}
      className={({ isActive }) =>
        cx("rounded-lg px-3 py-2 text-[13px] font-semibold transition", isActive ? "bg-primary-soft text-primary" : "text-muted hover:bg-surface-2 hover:text-ink")
      }
    >
      {label}
    </NavLink>
  );
}

function MobileTab({ to, label, icon: Icon }: { to: string; label: string; icon: typeof Compass }) {
  return (
    <NavLink to={to} end={to === "/"} className={({ isActive }) => cx("flex min-h-[56px] flex-col items-center justify-center gap-0.5 py-1 transition", isActive ? "text-ink" : "text-muted")}>
      {({ isActive }) => (
        <>
          <span className={cx("rounded-xl px-2 py-1", isActive && "bg-primary-soft")}><Icon className={cx("h-[22px] w-[22px]", isActive ? "text-primary" : "")} /></span>
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
