import { useEffect, useRef, useState } from "react";
import { NavLink, Outlet, Link, useLocation } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import {
  Activity,
  ChevronDown,
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
import { protocolControlAbi } from "@optara/sdk";
import { CHAIN, IS_LOCAL, IS_LOCAL_FORK, NETWORK_LABEL } from "../config/network.ts";
import { fmtLevel, fmtWad } from "../lib/optara/format.ts";
import { useProductMarket, useSeriesList } from "../lib/optara/hooks.ts";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { TRUSTED_ROLES, hasAnyTrustedRole, roleNames } from "../lib/optara/roles.ts";
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
  const { address } = useConnection();
  const { data: roleMap } = useQuery({
    queryKey: ["trustedRoles", address],
    queryFn: async () => {
      const entries = await Promise.all(
        TRUSTED_ROLES.map(async (r) => [r.key, await publicClient.readContract({ address: ADDR.control, abi: protocolControlAbi, functionName: "hasRole", args: [r.key, address!] })] as const),
      );
      return new Map(entries);
    },
    enabled: !!address,
  });
  const showAdmin = hasAnyTrustedRole(roleMap);
  const adminLabel = roleNames(roleMap, true).slice(0, 2).join(", ");
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const on = () => setScrolled(window.scrollY > 4);
    on();
    window.addEventListener("scroll", on, { passive: true });
    return () => window.removeEventListener("scroll", on);
  }, []);
  const secondary: MenuItem[] = [
    { to: "/app/liquidations", label: "Liquidations", text: "Accounts below their margin, and auctions", icon: ShieldAlert },
    { to: "/app/system", label: "System status", text: "Prices, reserves, upgrades and contracts", icon: Server },
    { to: "/app/new", label: "New market", text: "List an option with its own order book", icon: Zap },
    ...(showAdmin ? [{ to: "/app/admin", label: "Admin", text: adminLabel ? `Your roles: ${adminLabel}` : "Role-holder controls", icon: LockKeyhole }] : []),
  ];

  return (
    <div className="app-shell flex min-h-screen flex-col overflow-x-clip">
      <header className={cx("sticky top-0 z-40 border-b bg-bg/80 backdrop-blur-xl transition-shadow", scrolled ? "border-line shadow-[0_6px_24px_-12px_rgba(32,0,82,0.25)]" : "border-transparent")}>
        <div className="app-column flex h-[60px] items-center gap-3">
          <Link to="/" className="flex shrink-0 items-center gap-2" aria-label="Optara home">
            <img src="/brand/logo/optara-lockup-light.svg" alt="Optara" className="theme-logo-light h-8 w-auto" />
            <img src="/brand/logo/optara-lockup-dark.svg" alt="Optara" className="theme-logo-dark h-8 w-auto" />
          </Link>
          <NetworkBadge />

          {/* Primary navigation from tablet width up; phones use the bottom tab bar */}
          <nav className="ml-1 hidden items-center gap-0.5 md:flex lg:ml-4" aria-label="Main">
            {PRIMARY.map((n) => (
              <TopNav key={n.to} {...n} />
            ))}
            <MoreMenu items={secondary} onGuide={openGuide} />
          </nav>

          <div className="ml-auto flex min-w-0 items-center gap-1.5">
            <div className="hidden lg:block">
              <SpotPill />
            </div>
            <button
              className="grid h-9 w-9 cursor-pointer place-items-center rounded-xl text-muted transition hover:bg-surface-2 hover:text-ink"
              onClick={toggleTheme}
              aria-label={theme === "dark" ? "Switch to light theme" : "Switch to dark theme"}
              title={theme === "dark" ? "Light theme" : "Dark theme"}
            >
              {theme === "dark" ? <Sun className="h-[18px] w-[18px]" /> : <Moon className="h-[18px] w-[18px]" />}
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
            {showAdmin && (
              <Link to="/app/admin" onClick={() => setMoreOpen(false)} className="flex items-center gap-2.5 rounded-2xl border border-line bg-surface-2 p-3.5 text-sm font-semibold">
                <LockKeyhole className="h-4 w-4 text-primary" /> Admin controls{adminLabel && <span className="ml-auto text-xs text-muted">{adminLabel}</span>}
              </Link>
            )}
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

const PRIMARY: { to: string; label: string; icon: LucideIcon }[] = [
  { to: "/app/markets", label: "Markets", icon: Compass },
  { to: "/app/write", label: "Earn", icon: Coins },
  { to: "/app/portfolio", label: "Portfolio", icon: PieChart },
  { to: "/app/settlement", label: "Settle", icon: Activity },
];

interface MenuItem {
  to: string;
  label: string;
  text: string;
  icon: LucideIcon;
}

/** A top-bar link: quiet text, with a slim underline marking the current page. */
function TopNav({ to, label, icon: Icon }: { to: string; label: string; icon: LucideIcon }) {
  return (
    <NavLink
      to={to}
      className={({ isActive }) =>
        cx(
          "group relative inline-flex h-10 items-center gap-1.5 rounded-xl px-2.5 text-[13.5px] font-semibold transition lg:px-3",
          isActive ? "text-ink" : "text-muted hover:bg-surface-2/70 hover:text-ink",
        )
      }
    >
      {({ isActive }) => (
        <>
          <Icon className={cx("hidden h-4 w-4 lg:block", isActive ? "text-primary" : "text-faint group-hover:text-ink")} />
          {label}
          <span className={cx("absolute inset-x-3 -bottom-[11px] h-[2px] rounded-full transition", isActive ? "bg-primary" : "bg-transparent")} />
        </>
      )}
    </NavLink>
  );
}

/** Everything that isn't a primary page, so no page is ever unreachable at any width. */
function MoreMenu({ items, onGuide }: { items: MenuItem[]; onGuide: () => void }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const { pathname } = useLocation();
  const activeHere = items.some((i) => pathname.startsWith(i.to));
  useEffect(() => setOpen(false), [pathname]);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => ref.current && !ref.current.contains(e.target as Node) && setOpen(false);
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", close);
    document.addEventListener("keydown", esc);
    return () => (document.removeEventListener("mousedown", close), document.removeEventListener("keydown", esc));
  }, [open]);

  return (
    <div className="relative" ref={ref}>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="menu"
        aria-expanded={open}
        className={cx(
          "relative inline-flex h-10 cursor-pointer items-center gap-1 rounded-xl px-3 text-[13.5px] font-semibold transition",
          open || activeHere ? "text-ink" : "text-muted hover:bg-surface-2/70 hover:text-ink",
        )}
      >
        More
        <ChevronDown className={cx("h-4 w-4 transition", open && "rotate-180")} />
        <span className={cx("absolute inset-x-3 -bottom-[11px] h-[2px] rounded-full", activeHere ? "bg-primary" : "bg-transparent")} />
      </button>
      {open && (
        <div role="menu" className="card rise absolute right-0 top-[calc(100%+10px)] z-50 w-[300px] p-1.5 shadow-2xl lg:left-0 lg:right-auto">
          {items.map((i) => (
            <NavLink
              key={i.to}
              to={i.to}
              role="menuitem"
              className={({ isActive }) => cx("flex items-start gap-3 rounded-xl px-3 py-2.5 transition", isActive ? "bg-primary-soft" : "hover:bg-surface-2")}
            >
              {({ isActive }) => (
                <>
                  <span className={cx("mt-0.5 grid h-8 w-8 shrink-0 place-items-center rounded-lg", isActive ? "bg-primary text-white" : "bg-surface-2 text-primary")}>
                    <i.icon className="h-4 w-4" />
                  </span>
                  <span className="min-w-0">
                    <span className="block text-[13.5px] font-semibold">{i.label}</span>
                    <span className="block text-xs text-muted">{i.text}</span>
                  </span>
                </>
              )}
            </NavLink>
          ))}
          <div className="my-1 border-t border-line" />
          <button
            type="button"
            role="menuitem"
            onClick={() => (setOpen(false), onGuide())}
            className="flex w-full cursor-pointer items-center gap-3 rounded-xl px-3 py-2.5 text-left transition hover:bg-surface-2"
          >
            <span className="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-surface-2 text-primary">
              <HelpCircle className="h-4 w-4" />
            </span>
            <span>
              <span className="block text-[13.5px] font-semibold">How options work</span>
              <span className="block text-xs text-muted">A 60-second guide</span>
            </span>
          </button>
        </div>
      )}
    </div>
  );
}

/** Which chain the app is on, shown only off mainnet so nobody mistakes a test network for the real one. */
function NetworkBadge() {
  if (CHAIN.id === 143 && !IS_LOCAL) return null;
  const label = IS_LOCAL_FORK ? "Local fork" : IS_LOCAL ? "Local" : (NETWORK_LABEL[CHAIN.id] ?? CHAIN.name);
  return (
    <span className="hidden shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full border border-warn/30 bg-warn/10 px-2 py-0.5 text-[11px] font-semibold text-warn sm:inline-flex" title="Test network: not real money">
      <span className="h-1.5 w-1.5 rounded-full bg-warn" /> {label}
    </span>
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
    <div className="flex h-9 items-center gap-1.5 rounded-xl bg-surface-2/70 px-2.5" title={`${first.underlyingSymbol} spot · ${m.spotFresh ? "live" : "delayed"}`}>
      <TokenIcon symbol={first.underlyingSymbol} className="h-4 w-4" />
      <span className="num font-display text-[13px] font-semibold">${fmtLevel(m.spotWad)}</span>
      <span className={cx("h-1.5 w-1.5 rounded-full", m.spotFresh ? "live-dot bg-good" : "bg-warn")} />
    </div>
  );
}
