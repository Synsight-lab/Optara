/** `/docs/:slug`: the protocol docs. Sidebar of pages, the article, and an "On this page" list that follows scrolling. */
import { useEffect, useMemo, useRef, useState } from "react";
import { Link, NavLink, Navigate, useLocation, useParams } from "react-router";
import { ArrowLeft, ArrowRight, ChevronRight, Menu, Search, X } from "lucide-react";
import { DOCS, DOC_GROUPS, docBySlug, type DocPage } from "../content/docs.tsx";
import { SOCIALS, SiteFooter, SiteHeader, XIcon } from "../components/Site.tsx";
import { cx } from "../components/ui.tsx";

export function DocsPage() {
  const { slug } = useParams();
  const { hash } = useLocation();
  const page = docBySlug(slug);
  const [menuOpen, setMenuOpen] = useState(false);
  const articleRef = useRef<HTMLElement>(null);

  useEffect(() => {
    if (!page) return;
    document.title = `${page.title} · Optara Docs`;
    setMenuOpen(false);
    const target = hash ? document.getElementById(decodeURIComponent(hash.slice(1))) : null;
    if (target) target.scrollIntoView();
    else window.scrollTo({ top: 0 });
    return () => {
      document.title = "Optara";
    };
  }, [page, hash]);

  if (!page) return <Navigate to="/docs/introduction" replace />;
  const i = DOCS.indexOf(page);
  const prev = DOCS[i - 1];
  const next = DOCS[i + 1];

  return (
    <div className="home-page min-h-screen bg-bg text-ink">
      <SiteHeader wide sticky>
        <button
          type="button"
          onClick={() => setMenuOpen(true)}
          className="grid h-9 w-9 cursor-pointer place-items-center rounded-xl text-muted transition hover:bg-surface-2 hover:text-ink lg:hidden"
          aria-label="Open docs menu"
        >
          <Menu className="h-5 w-5" />
        </button>
      </SiteHeader>

      <div className="docs-column grid gap-10 lg:grid-cols-[250px_minmax(0,1fr)] xl:grid-cols-[250px_minmax(0,1fr)_210px]">
        <aside className="docs-scroll sticky top-[68px] hidden h-[calc(100vh-68px)] overflow-y-auto py-8 pr-2 lg:block">
          <Sidebar current={page.slug} />
        </aside>

        <main className="min-w-0 py-8 lg:py-10">
          <article ref={articleRef} className="mx-auto max-w-[760px]">
            <nav className="flex items-center gap-1.5 text-[13px] font-semibold text-faint">
              <Link to="/docs" className="hover:text-ink">
                Docs
              </Link>
              <ChevronRight className="h-3.5 w-3.5" />
              <span className="text-primary">{page.group}</span>
            </nav>
            <h1 className="font-display mt-3 text-4xl font-bold leading-tight tracking-tight sm:text-[2.6rem]">{page.title}</h1>
            <p className="mt-2 text-base text-faint">{page.description}</p>
            <div className="mt-6">{page.body()}</div>

            <div className="mt-14 grid gap-3 border-t border-line pt-8 sm:grid-cols-2">
              {prev ? <PageLink page={prev} dir="prev" /> : <span />}
              {next && <PageLink page={next} dir="next" />}
            </div>

            <div className="mt-8 flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-line bg-surface-2/40 px-4 py-3 text-sm text-muted">
              <span>Questions or feedback on the docs?</span>
              <a href={SOCIALS.x.href} target="_blank" rel="noreferrer" className="inline-flex items-center gap-2 font-semibold text-ink hover:text-primary">
                <XIcon className="h-3.5 w-3.5" /> Message {SOCIALS.x.handle}
              </a>
            </div>
          </article>
        </main>

        <aside className="hidden xl:block">
          <div className="sticky top-[68px] py-10">
            <OnThisPage articleRef={articleRef} pageKey={page.slug} />
          </div>
        </aside>
      </div>

      <SiteFooter wide />

      {menuOpen && (
        <div className="fixed inset-0 z-50 lg:hidden" role="dialog" aria-modal="true" aria-label="Docs menu">
          <button type="button" aria-label="Close menu" className="absolute inset-0 bg-black/50 backdrop-blur-sm" onClick={() => setMenuOpen(false)} />
          <div className="docs-scroll rise absolute inset-y-0 left-0 w-[min(320px,86vw)] overflow-y-auto border-r border-line bg-bg p-5">
            <div className="mb-4 flex items-center justify-between">
              <span className="font-display text-lg font-bold">Optara Docs</span>
              <button type="button" onClick={() => setMenuOpen(false)} aria-label="Close menu" className="grid h-9 w-9 cursor-pointer place-items-center rounded-xl text-muted hover:bg-surface-2">
                <X className="h-5 w-5" />
              </button>
            </div>
            <Sidebar current={page.slug} />
          </div>
        </div>
      )}
    </div>
  );
}

function Sidebar({ current }: { current: string }) {
  const [q, setQ] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  // "/" focuses the search, like most docs sites.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement;
      if (e.key === "/" && !/^(INPUT|TEXTAREA)$/.test(t.tagName) && inputRef.current?.offsetParent) {
        e.preventDefault();
        inputRef.current.focus();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const matches = useMemo(() => {
    const words = q.toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length) return DOCS;
    return DOCS.filter((d) => {
      const hay = `${d.title} ${d.description} ${d.keywords ?? ""} ${d.group}`.toLowerCase();
      return words.every((w) => hay.includes(w));
    });
  }, [q]);

  return (
    <div>
      <label className="relative block">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-faint" />
        <input
          ref={inputRef}
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Search docs"
          aria-label="Search docs"
          className="w-full rounded-xl border border-line bg-surface-2/60 py-2 pl-9 pr-8 text-sm outline-none transition placeholder:text-faint focus:border-primary focus:ring-2 focus:ring-primary/20"
        />
        <kbd className="pointer-events-none absolute right-2.5 top-1/2 -translate-y-1/2 rounded border border-line px-1.5 text-[11px] text-faint">/</kbd>
      </label>

      {matches.length === 0 && <p className="mt-6 px-2 text-sm text-muted">No page matches “{q}”.</p>}

      {DOC_GROUPS.map((g) => {
        const pages = matches.filter((d) => d.group === g);
        if (!pages.length) return null;
        return (
          <div key={g} className="mt-6">
            <div className="px-3 text-[11px] font-bold uppercase tracking-[0.1em] text-faint">{g}</div>
            <ul className="mt-2 space-y-0.5">
              {pages.map((d) => (
                <li key={d.slug}>
                  <NavLink
                    to={`/docs/${d.slug}`}
                    className={cx(
                      "block rounded-lg border-l-2 px-3 py-1.5 text-[14px] transition",
                      d.slug === current ? "border-primary bg-primary-soft font-semibold text-ink" : "border-transparent text-muted hover:bg-surface-2 hover:text-ink",
                    )}
                  >
                    {d.title}
                  </NavLink>
                </li>
              ))}
            </ul>
          </div>
        );
      })}
    </div>
  );
}

function OnThisPage({ articleRef, pageKey }: { articleRef: React.RefObject<HTMLElement | null>; pageKey: string }) {
  const [items, setItems] = useState<{ id: string; text: string; level: number }[]>([]);
  const [active, setActive] = useState<string>();

  useEffect(() => {
    const root = articleRef.current;
    if (!root) return;
    const hs = [...root.querySelectorAll<HTMLElement>("[data-toc]")];
    setItems(hs.map((h) => ({ id: h.id, text: h.textContent ?? "", level: Number(h.dataset.toc) })));
    setActive(hs[0]?.id);
    const io = new IntersectionObserver(
      (entries) => {
        const visible = entries.filter((e) => e.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
        if (visible[0]) setActive(visible[0].target.id);
      },
      { rootMargin: "-80px 0px -65% 0px" },
    );
    hs.forEach((h) => io.observe(h));
    return () => io.disconnect();
  }, [articleRef, pageKey]);

  if (items.length < 2) return null;
  return (
    <nav aria-label="On this page">
      <div className="text-[11px] font-bold uppercase tracking-[0.1em] text-faint">On this page</div>
      <ul className="mt-3 space-y-1 border-l border-line">
        {items.map((it) => (
          <li key={it.id}>
            <a
              href={`#${it.id}`}
              className={cx(
                "-ml-px block border-l-2 py-1 text-[13px] leading-5 transition",
                it.level === 3 ? "pl-6" : "pl-3",
                active === it.id ? "border-primary font-semibold text-ink" : "border-transparent text-muted hover:text-ink",
              )}
            >
              {it.text}
            </a>
          </li>
        ))}
      </ul>
      <button type="button" onClick={() => window.scrollTo({ top: 0, behavior: "smooth" })} className="mt-5 cursor-pointer text-[13px] font-semibold text-faint hover:text-ink">
        Back to top ↑
      </button>
    </nav>
  );
}

function PageLink({ page, dir }: { page: DocPage; dir: "prev" | "next" }) {
  return (
    <Link
      to={`/docs/${page.slug}`}
      className={cx(
        "group rounded-2xl border border-line p-4 transition hover:border-primary/40 hover:bg-primary-soft/40",
        dir === "next" && "text-right sm:col-start-2",
      )}
    >
      <div className={cx("flex items-center gap-1.5 text-xs font-semibold text-faint", dir === "next" && "justify-end")}>
        {dir === "prev" && <ArrowLeft className="h-3.5 w-3.5 transition group-hover:-translate-x-0.5" />}
        {dir === "prev" ? "Previous" : "Next"}
        {dir === "next" && <ArrowRight className="h-3.5 w-3.5 transition group-hover:translate-x-0.5" />}
      </div>
      <div className="mt-1 font-display text-base font-bold text-ink">{page.title}</div>
    </Link>
  );
}
