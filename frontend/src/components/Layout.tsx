import { useState } from "react";
import { NavLink, Outlet, Link, useLocation } from "react-router";
import {
  Activity,
  BarChart2,
  BookOpen,
  Briefcase,
  Compass,
  Flame,
  HelpCircle,
  Menu,
  Moon,
  MoreHorizontal,
  PieChart,
  Server,
  ShieldAlert,
  SlidersHorizontal,
  Sparkles,
  Sun,
  X,
  Zap,
} from "lucide-react";
import { IS_LOCAL, MANIFEST, NETWORK_LABEL, PUBLISHER_URL } from "../config/network.ts";
import { fmtWad } from "../lib/optara/format.ts";
import { useProductMarket, useSeriesList } from "../lib/optara/hooks.ts";
import { useQuickGuide, useTheme, useTradingMode } from "../state.tsx";
import { ConnectButton } from "./ConnectButton.tsx";
import { OnboardingModal } from "./OnboardingModal.tsx";
import { Toaster } from "./Toaster.tsx";
import { cx } from "./ui.tsx";
import { TokenIcon } from "./Icons.tsx";

const NAV = [
  { to: "/", label: "Markets", icon: Compass },
  { to: "/trade", label: "Trade", icon: Zap },
  { to: "/portfolio", label: "Portfolio", icon: PieChart },
  { to: "/settlement", label: "Settlement", icon: Activity },
  { to: "/liquidations", label: "Liquidations", icon: ShieldAlert },
  { to: "/system", label: "System", icon: Server },
];

export function Layout() {
  const [theme, toggleTheme] = useTheme();
  const { mode, toggle: toggleMode } = useTradingMode();
  const { open: openGuide } = useQuickGuide();
  const [mobileDrawerOpen, setMobileDrawerOpen] = useState(false);
  const location = useLocation();

  return (
    <div className="flex min-h-screen flex-col overflow-x-clip pb-20 md:pb-0">
      {/* Top Navbar */}
      <header className="sticky top-0 z-40 border-b border-line bg-bg/85 backdrop-blur-xl transition-colors">
        <div className="mx-auto flex max-w-7xl items-center gap-3 px-4 py-3 sm:gap-4 sm:py-3.5">
          {/* Logo & Brand */}
          <Link to="/" className="flex items-center gap-2.5 group" aria-label="Optara home">
            <div className="relative">
              <div className="absolute -inset-1 rounded-xl bg-primary/30 blur-sm group-hover:bg-primary/50 transition" />
              <img src="/optara.svg" alt="Optara Logo" className="relative h-8 w-8 rounded-xl object-contain" />
            </div>
            <div className="flex flex-col">
              <span className="text-lg font-black tracking-tight leading-none flex items-center gap-1.5">
                Optara
                <span className="text-[10px] font-bold px-1.5 py-0.5 rounded-full bg-primary-soft text-primary tracking-normal">
                  PM
                </span>
              </span>
              <span className="text-[10px] text-muted font-medium hidden sm:block">Options on Monad</span>
            </div>
          </Link>

          {/* Desktop Nav */}
          <nav className="hidden items-center gap-1 md:flex ml-3" aria-label="Main">
            {NAV.map((n) => {
              const Icon = n.icon;
              return (
                <NavLink
                  key={n.to}
                  to={n.to}
                  end={n.to === "/"}
                  className={({ isActive }) =>
                    cx(
                      "flex items-center gap-1.5 rounded-xl px-3 py-2 text-xs font-semibold transition-all",
                      isActive
                        ? "bg-primary-soft text-primary shadow-sm"
                        : "text-muted hover:bg-surface-2 hover:text-ink"
                    )
                  }
                >
                  <Icon className="h-3.5 w-3.5" />
                  {n.label}
                </NavLink>
              );
            })}
          </nav>

          {/* Right Actions */}
          <div className="ml-auto flex items-center gap-1.5 sm:gap-2">
            {/* Live Spot Ticker */}
            <SpotTicker />

            {/* Simple vs Pro Mode Pill */}
            <button
              onClick={toggleMode}
              className={cx(
                "hidden sm:flex items-center gap-1.5 rounded-xl border px-3 py-1.5 text-xs font-semibold transition shadow-sm",
                mode === "simple"
                  ? "border-primary/40 bg-primary-soft text-primary hover:bg-primary-soft/80"
                  : "border-line bg-surface-2 text-ink hover:border-primary/40"
              )}
              title="Click to switch trading view"
            >
              {mode === "simple" ? (
                <>
                  <Sparkles className="h-3.5 w-3.5 text-primary animate-pulse" />
                  <span>Simple Mode</span>
                </>
              ) : (
                <>
                  <SlidersHorizontal className="h-3.5 w-3.5 text-muted" />
                  <span>Pro Mode</span>
                </>
              )}
            </button>

            {/* Learn / Help Guide Trigger */}
            <button
              onClick={openGuide}
              className="flex items-center gap-1 rounded-xl border border-line bg-surface-2 px-2.5 py-1.5 text-xs font-medium text-muted hover:text-ink hover:border-primary/40 transition"
              title="Learn how options work in 60 seconds"
            >
              <BookOpen className="h-3.5 w-3.5 text-primary" />
              <span className="hidden md:inline">Learn</span>
            </button>

            {/* Network Badge */}
            <span
              className={cx(
                "pill hidden xl:inline-flex",
                IS_LOCAL ? "bg-accent/15 text-accent" : "bg-primary-soft text-primary"
              )}
            >
              <span className="live-dot h-1.5 w-1.5 rounded-full bg-current" />
              {NETWORK_LABEL[MANIFEST.chainId] ?? MANIFEST.network}
            </span>

            {/* Theme Toggle */}
            <button
              className="rounded-xl border border-line bg-surface-2 p-2 text-muted hover:text-ink hover:border-primary/40 transition"
              onClick={toggleTheme}
              aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} theme`}
              title="Toggle theme"
            >
              {theme === "dark" ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
            </button>

            {/* Connect Wallet Button */}
            <ConnectButton />
          </div>
        </div>
      </header>

      {/* Publisher Warning Bar */}
      {!PUBLISHER_URL && (
        <div className="border-b border-warn/30 bg-warn/10 px-4 py-2 text-center text-xs text-warn font-medium">
          ⚠️ Price service offline: you can browse, close, and settle existing positions, but opening new positions is temporarily blocked.
        </div>
      )}

      {/* Main Content Area */}
      <main className="mx-auto w-full max-w-7xl flex-1 px-3 sm:px-6 py-4 sm:py-6 md:py-8">
        <Outlet />
      </main>

      {/* Desktop Footer */}
      <footer className="border-t border-line px-4 py-6 text-center text-xs text-muted hidden md:block">
        <div className="mx-auto max-w-7xl flex flex-wrap items-center justify-between gap-4">
          <div className="flex items-center gap-2">
            <span className="font-semibold text-ink">Optara PM</span>
            <span>· Cash-settled European options on Monad</span>
          </div>
          <div className="flex items-center gap-4 text-xs">
            <button onClick={openGuide} className="hover:text-primary transition underline underline-offset-4">
              Options Academy
            </button>
            <Link to="/trade" className="hover:text-primary transition">
              Quick Trade
            </Link>
            <Link to="/system" className="hover:text-primary transition">
              System Health
            </Link>
            <span className="text-muted/70">Pyth Oracles · Timelock Governed</span>
          </div>
        </div>
      </footer>

      {/* Modern Mobile Bottom Navigation Bar (Fintech-style, thumb-friendly) */}
      <nav
        className="fixed bottom-0 left-0 right-0 z-40 flex items-center justify-around border-t border-line bg-bg/95 backdrop-blur-2xl py-2 px-2 md:hidden safe-area-pb"
        aria-label="Mobile Navigation"
      >
        <NavLink
          to="/"
          end
          className={({ isActive }) =>
            cx(
              "flex flex-col items-center justify-center gap-1 rounded-xl px-2.5 py-1 text-[11px] font-semibold transition active:scale-95",
              isActive ? "text-primary font-bold" : "text-muted hover:text-ink"
            )
          }
        >
          {({ isActive }) => (
            <>
              <div className={cx("p-1 rounded-lg", isActive && "bg-primary-soft")}>
                <Compass className={cx("h-5 w-5", isActive ? "text-primary" : "text-muted")} />
              </div>
              <span>Markets</span>
            </>
          )}
        </NavLink>

        <NavLink
          to="/trade"
          className={({ isActive }) =>
            cx(
              "flex flex-col items-center justify-center gap-1 rounded-xl px-2.5 py-1 text-[11px] font-semibold transition active:scale-95",
              isActive ? "text-primary font-bold" : "text-muted hover:text-ink"
            )
          }
        >
          {({ isActive }) => (
            <>
              <div className={cx("p-1 rounded-lg", isActive ? "bg-primary text-white shadow-md" : "bg-primary/10 text-primary")}>
                <Zap className={cx("h-5 w-5", isActive ? "text-white" : "text-primary")} />
              </div>
              <span className={isActive ? "text-primary font-bold" : "text-ink font-semibold"}>Trade</span>
            </>
          )}
        </NavLink>

        <NavLink
          to="/portfolio"
          className={({ isActive }) =>
            cx(
              "flex flex-col items-center justify-center gap-1 rounded-xl px-2.5 py-1 text-[11px] font-semibold transition active:scale-95",
              isActive ? "text-primary font-bold" : "text-muted hover:text-ink"
            )
          }
        >
          {({ isActive }) => (
            <>
              <div className={cx("p-1 rounded-lg", isActive && "bg-primary-soft")}>
                <PieChart className={cx("h-5 w-5", isActive ? "text-primary" : "text-muted")} />
              </div>
              <span>Portfolio</span>
            </>
          )}
        </NavLink>

        <NavLink
          to="/settlement"
          className={({ isActive }) =>
            cx(
              "flex flex-col items-center justify-center gap-1 rounded-xl px-2.5 py-1 text-[11px] font-semibold transition active:scale-95",
              isActive ? "text-primary font-bold" : "text-muted hover:text-ink"
            )
          }
        >
          {({ isActive }) => (
            <>
              <div className={cx("p-1 rounded-lg", isActive && "bg-primary-soft")}>
                <Activity className={cx("h-5 w-5", isActive ? "text-primary" : "text-muted")} />
              </div>
              <span>Settlement</span>
            </>
          )}
        </NavLink>

        {/* More Drawer Button */}
        <button
          onClick={() => setMobileDrawerOpen((o) => !o)}
          className={cx(
            "flex flex-col items-center justify-center gap-1 rounded-xl px-2.5 py-1 text-[11px] font-semibold transition active:scale-95",
            mobileDrawerOpen ? "text-primary font-bold" : "text-muted hover:text-ink"
          )}
        >
          <div className={cx("p-1 rounded-lg", mobileDrawerOpen && "bg-primary-soft")}>
            <MoreHorizontal className="h-5 w-5" />
          </div>
          <span>More</span>
        </button>
      </nav>

      {/* Mobile More Drawer Sheet */}
      {mobileDrawerOpen && (
        <div
          className="fixed inset-0 z-50 flex flex-col justify-end bg-black/60 backdrop-blur-sm md:hidden animate-in fade-in"
          onClick={() => setMobileDrawerOpen(false)}
        >
          <div
            className="rounded-t-3xl border-t border-line bg-surface p-6 shadow-2xl safe-area-pb space-y-4"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between pb-2 border-b border-line">
              <span className="font-bold text-ink text-sm">More Options & Settings</span>
              <button
                onClick={() => setMobileDrawerOpen(false)}
                className="rounded-full p-1 text-muted hover:bg-surface-2 hover:text-ink"
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            <div className="grid grid-cols-2 gap-2 text-xs font-semibold">
              <Link
                to="/liquidations"
                onClick={() => setMobileDrawerOpen(false)}
                className="flex items-center gap-2 rounded-2xl border border-line bg-surface-2 p-3 text-ink"
              >
                <ShieldAlert className="h-4 w-4 text-warn" /> Liquidations
              </Link>
              <Link
                to="/system"
                onClick={() => setMobileDrawerOpen(false)}
                className="flex items-center gap-2 rounded-2xl border border-line bg-surface-2 p-3 text-ink"
              >
                <Server className="h-4 w-4 text-primary" /> System Status
              </Link>
              <button
                onClick={() => {
                  setMobileDrawerOpen(false);
                  openGuide();
                }}
                className="flex items-center gap-2 rounded-2xl border border-line bg-surface-2 p-3 text-ink text-left"
              >
                <BookOpen className="h-4 w-4 text-accent" /> Learn Options
              </button>
              <button
                onClick={() => {
                  toggleMode();
                  setMobileDrawerOpen(false);
                }}
                className="flex items-center gap-2 rounded-2xl border border-line bg-surface-2 p-3 text-ink text-left"
              >
                <SlidersHorizontal className="h-4 w-4 text-good" />
                Mode: {mode === "simple" ? "Simple" : "Pro"}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Global Onboarding & Help Modal */}
      <OnboardingModal />

      {/* Toast Notification Container */}
      <Toaster />
    </div>
  );
}

function SpotTicker() {
  const { data: series } = useSeriesList();
  const first = series?.[0];
  const { data: m } = useProductMarket(first?.productId);
  if (!first || !m) return null;
  return (
    <div
      className="hidden sm:flex items-center gap-2 rounded-xl border border-line bg-surface-2 px-3 py-1.5 text-xs shadow-sm transition hover:border-primary/40"
      title={m.spotFresh ? "Live real-time feed from Pyth" : "Price is temporarily stale"}
    >
      <TokenIcon symbol={first.underlyingSymbol} className="h-4 w-4" />
      <span className="font-semibold text-ink">{first.underlyingSymbol}</span>
      <span className="num font-bold text-ink">${fmtWad(m.spotWad, 2)}</span>
      <span className={cx("h-2 w-2 rounded-full", m.spotFresh ? "live-dot bg-good" : "bg-warn")} />
    </div>
  );
}
