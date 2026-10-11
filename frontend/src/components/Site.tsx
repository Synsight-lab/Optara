/**
 * The public site chrome shared by the home page, the docs and the blog: header, footer and social links.
 * The app under /app has its own shell (Layout.tsx).
 */
import type { ReactNode, SVGProps } from "react";
import { Link, NavLink } from "react-router";
import { ArrowRight, BookOpen, Moon, Newspaper, Sun } from "lucide-react";
import { cx } from "./ui.tsx";
import { useTheme } from "../state.tsx";

export const SOCIALS = {
  x: { label: "X (Twitter)", handle: "@0Xoptara", href: "https://x.com/0Xoptara" },
};

export function XIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" {...props}>
      <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231 5.45-6.231Zm-1.161 17.52h1.833L7.084 4.126H5.117L17.083 19.77Z" />
    </svg>
  );
}

export function SiteLogo({ size = "md" }: { size?: "sm" | "md" }) {
  const h = size === "sm" ? "h-8" : "h-10";
  return (
    <Link to="/" aria-label="Optara home" className="flex shrink-0 items-center gap-3">
      <img src="/brand/logo/optara-lockup-light.svg" alt="Optara" className={cx("theme-logo-light w-auto", h)} />
      <img src="/brand/logo/optara-lockup-dark.svg" alt="Optara" className={cx("theme-logo-dark w-auto", h)} />
    </Link>
  );
}

const navCls = ({ isActive }: { isActive: boolean }) =>
  cx(
    "hidden items-center gap-1.5 rounded-xl px-3 py-2 text-[13.5px] font-semibold transition sm:inline-flex",
    isActive ? "bg-primary-soft text-ink" : "text-muted hover:bg-surface-2 hover:text-ink",
  );

/** Header for the public pages. `wide` stretches it for the three-column docs layout. */
export function SiteHeader({ wide, sticky, children }: { wide?: boolean; sticky?: boolean; children?: ReactNode }) {
  const [theme, toggleTheme] = useTheme();
  return (
    <header className={cx(sticky && "site-header sticky top-0 z-40 border-b border-line")}>
      <div className={cx("flex h-[68px] items-center justify-between gap-3", wide ? "docs-column" : "home-column")}>
        <div className="flex min-w-0 items-center gap-2">
          {children}
          <SiteLogo size={sticky ? "sm" : "md"} />
        </div>
        <nav className="flex items-center gap-1">
          <NavLink to="/docs" className={navCls}>
            <BookOpen className="h-4 w-4" /> Docs
          </NavLink>
          <NavLink to="/blog" className={navCls}>
            <Newspaper className="h-4 w-4" /> Blog
          </NavLink>
          <a
            href={SOCIALS.x.href}
            target="_blank"
            rel="noreferrer"
            aria-label={`Optara on ${SOCIALS.x.label}`}
            title={SOCIALS.x.handle}
            className="hidden h-9 w-9 place-items-center rounded-xl text-muted transition hover:bg-surface-2 hover:text-ink sm:grid"
          >
            <XIcon className="h-[15px] w-[15px]" />
          </a>
          <button
            type="button"
            onClick={toggleTheme}
            aria-label={theme === "dark" ? "Switch to light theme" : "Switch to dark theme"}
            className="grid h-9 w-9 cursor-pointer place-items-center rounded-xl text-muted transition hover:bg-surface-2 hover:text-ink"
          >
            {theme === "dark" ? <Sun className="h-[17px] w-[17px]" /> : <Moon className="h-[17px] w-[17px]" />}
          </button>
          <Link to="/app" className="btn-primary ml-1 !px-3.5 !py-2 text-sm whitespace-nowrap">
            <span className="sm:hidden">App</span>
            <span className="hidden sm:inline">Launch app</span> <ArrowRight className="h-4 w-4" />
          </Link>
        </nav>
      </div>
    </header>
  );
}

const FOOTER_COLUMNS: { title: string; links: { label: string; to: string; external?: boolean }[] }[] = [
  {
    title: "Product",
    links: [
      { label: "Markets", to: "/app/markets" },
      { label: "Earn (write options)", to: "/app/write" },
      { label: "Portfolio", to: "/app/portfolio" },
      { label: "Settlement", to: "/app/settlement" },
    ],
  },
  {
    title: "Learn",
    links: [
      { label: "Introduction", to: "/docs/introduction" },
      { label: "Whitepaper", to: "/docs/whitepaper" },
      { label: "Options in plain words", to: "/docs/options-101" },
      { label: "Kuru order book", to: "/docs/kuru-order-book" },
      { label: "FAQ", to: "/docs/faq" },
    ],
  },
  {
    title: "Protocol",
    links: [
      { label: "How it works", to: "/docs/architecture" },
      { label: "Settlement", to: "/docs/settlement" },
      { label: "Risks", to: "/docs/risks" },
      { label: "Contracts", to: "/docs/contracts" },
    ],
  },
  {
    title: "Community",
    links: [
      { label: "Blog", to: "/blog" },
      { label: `X ${SOCIALS.x.handle}`, to: SOCIALS.x.href, external: true },
    ],
  },
];

export function SiteFooter({ wide }: { wide?: boolean }) {
  return (
    <footer className="border-t border-line">
      <div className={cx("grid gap-10 py-12 md:grid-cols-[1.2fr_2fr]", wide ? "docs-column" : "home-column")}>
        <div className="max-w-sm">
          <SiteLogo />
          <p className="mt-4 text-sm leading-6 text-muted">
            Cash-settled options on Monad. Every option token is backed by a written short and paid out in stablecoin at expiry.
          </p>
          <a
            href={SOCIALS.x.href}
            target="_blank"
            rel="noreferrer"
            className="mt-5 inline-flex items-center gap-2 rounded-xl border border-line px-3 py-2 text-sm font-semibold text-muted transition hover:border-primary/40 hover:text-ink"
          >
            <XIcon className="h-3.5 w-3.5" /> Follow {SOCIALS.x.handle}
          </a>
        </div>
        <div className="grid grid-cols-2 gap-8 sm:grid-cols-4">
          {FOOTER_COLUMNS.map((c) => (
            <div key={c.title}>
              <div className="text-[11px] font-bold uppercase tracking-[0.1em] text-faint">{c.title}</div>
              <ul className="mt-3 space-y-2.5">
                {c.links.map((l) => (
                  <li key={l.label}>
                    {l.external ? (
                      <a href={l.to} target="_blank" rel="noreferrer" className="text-sm text-muted transition hover:text-ink">
                        {l.label}
                      </a>
                    ) : (
                      <Link to={l.to} className="text-sm text-muted transition hover:text-ink">
                        {l.label}
                      </Link>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </div>
      <div className={cx("flex flex-wrap items-center justify-between gap-2 border-t border-line py-5 text-xs text-faint", wide ? "docs-column" : "home-column")}>
        <span>© {new Date().getFullYear()} Optara. Options carry risk: buyers can lose the whole premium.</span>
        <span>Built on Monad · Liquidity via Kuru</span>
      </div>
    </footer>
  );
}
