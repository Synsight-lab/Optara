import { NavLink, Outlet, Link } from "react-router";
import { IS_LOCAL, MANIFEST, NETWORK_LABEL, PUBLISHER_URL } from "../config/network.ts";
import { fmtWad } from "../lib/optara/format.ts";
import { useProductMarket, useSeriesList } from "../lib/optara/hooks.ts";
import { useTheme } from "../state.tsx";
import { ConnectButton } from "./ConnectButton.tsx";
import { Toaster } from "./Toaster.tsx";
import { cx } from "./ui.tsx";

const NAV = [
  { to: "/", label: "Markets" },
  { to: "/portfolio", label: "Portfolio" },
  { to: "/settlement", label: "Settlement" },
  { to: "/liquidations", label: "Liquidations" },
  { to: "/system", label: "System" },
];

export function Layout() {
  const [theme, toggle] = useTheme();
  return (
    <div className="flex min-h-screen flex-col overflow-x-clip">
      <header className="sticky top-0 z-30 border-b border-line bg-bg/75 backdrop-blur-xl">
        <div className="mx-auto flex max-w-7xl items-center gap-4 px-4 py-3">
          <Link to="/" className="flex items-center gap-2.5" aria-label="Optara home">
            <img src="/optara.svg" alt="" className="h-8 w-8" />
            <span className="text-lg font-bold tracking-tight">Optara</span>
          </Link>
          <nav className="hidden items-center gap-1 md:flex" aria-label="Main">
            {NAV.map((n) => (
              <NavLink key={n.to} to={n.to} end={n.to === "/"} className={({ isActive }) => cx("rounded-lg px-3 py-1.5 text-sm font-medium transition", isActive ? "bg-primary-soft text-primary" : "text-muted hover:text-ink")}>
                {n.label}
              </NavLink>
            ))}
          </nav>
          <div className="ml-auto flex items-center gap-2">
            <SpotTicker />
            <span className={cx("pill hidden sm:inline-flex", IS_LOCAL ? "bg-accent/15 text-accent" : "bg-primary-soft text-primary")}>
              <span className="live-dot h-1.5 w-1.5 rounded-full bg-current" />
              {NETWORK_LABEL[MANIFEST.chainId] ?? MANIFEST.network}
            </span>
            <button className="btn-ghost px-2.5" onClick={toggle} aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} theme`} title="Theme">
              {theme === "dark" ? "☀" : "☾"}
            </button>
            <ConnectButton />
          </div>
        </div>
        <nav className="flex gap-1 overflow-x-auto px-4 pb-2 md:hidden" aria-label="Main (mobile)">
          {NAV.map((n) => (
            <NavLink key={n.to} to={n.to} end={n.to === "/"} className={({ isActive }) => cx("whitespace-nowrap rounded-lg px-3 py-1.5 text-sm font-medium", isActive ? "bg-primary-soft text-primary" : "text-muted")}>
              {n.label}
            </NavLink>
          ))}
        </nav>
      </header>
      {!PUBLISHER_URL && (
        <div className="border-b border-warn/30 bg-warn/10 px-4 py-2 text-center text-sm text-warn">
          No price service configured: you can browse, close and settle, but not open new positions.
        </div>
      )}
      <main className="mx-auto w-full max-w-7xl flex-1 px-4 py-6 md:py-8">
        <Outlet />
      </main>
      <footer className="border-t border-line px-4 py-6 text-center text-xs text-muted">
        Optara — European options on Monad. Contracts are upgradeable after a 7-day timelock. Prices from Pyth; settlement from the
        round in force at expiry.
      </footer>
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
    <div className="hidden items-center gap-2 rounded-xl border border-line px-3 py-1.5 text-sm lg:flex" title={m.spotFresh ? "Live price" : "Price is stale"}>
      <span className={cx("h-2 w-2 rounded-full", m.spotFresh ? "live-dot bg-good" : "bg-warn")} />
      <span className="text-muted">{first.underlyingSymbol}</span>
      <span className="num font-semibold">{fmtWad(m.spotWad, 2)}</span>
    </div>
  );
}
