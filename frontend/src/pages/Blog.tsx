/** `/blog` and `/blog/:slug`: product news and deep dives. */
import { useEffect, useState } from "react";
import { Link, Navigate, useParams } from "react-router";
import { ArrowLeft, ArrowRight, Clock } from "lucide-react";
import { POSTS, fmtPostDate, postBySlug, type BlogPost } from "../content/blog.tsx";
import { SOCIALS, SiteFooter, SiteHeader, XIcon } from "../components/Site.tsx";
import { cx } from "../components/ui.tsx";

const TAGS = ["All", ...new Set(POSTS.map((p) => p.tag))] as const;

export function BlogPage() {
  const [tag, setTag] = useState<string>("All");
  useEffect(() => {
    document.title = "Blog · Optara";
    return () => {
      document.title = "Optara";
    };
  }, []);
  const [featured, ...rest] = POSTS;
  const list = tag === "All" ? rest : POSTS.filter((p) => p.tag === tag);

  return (
    <div className="home-page min-h-screen bg-bg text-ink">
      <SiteHeader />
      <main className="home-column pb-20 pt-8">
        <div className="max-w-2xl">
          <div className="text-sm font-bold text-primary">Optara blog</div>
          <h1 className="font-display mt-2 text-4xl font-bold tracking-tight sm:text-5xl">News, product updates and deep dives</h1>
          <p className="mt-3 text-base leading-7 text-muted">How Optara works, what we are shipping, and why it is built the way it is.</p>
        </div>

        {tag === "All" && featured && <FeaturedPost post={featured} />}

        <div className="mt-10 flex flex-wrap gap-2" role="tablist" aria-label="Filter posts">
          {TAGS.map((t) => (
            <button
              key={t}
              type="button"
              role="tab"
              aria-selected={tag === t}
              onClick={() => setTag(t)}
              className={cx(
                "cursor-pointer rounded-full border px-3.5 py-1.5 text-sm font-semibold transition",
                tag === t ? "border-primary bg-primary text-white" : "border-line text-muted hover:border-primary/40 hover:text-ink",
              )}
            >
              {t}
            </button>
          ))}
        </div>

        <div className="mt-6 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {list.map((p) => (
            <PostCard key={p.slug} post={p} />
          ))}
        </div>

        <FollowBanner />
      </main>
      <SiteFooter />
    </div>
  );
}

function FeaturedPost({ post }: { post: BlogPost }) {
  return (
    <Link
      to={`/blog/${post.slug}`}
      className="group mt-10 grid overflow-hidden rounded-3xl border border-line bg-surface shadow-ticket transition hover:border-primary/40 md:grid-cols-[1.1fr_1fr]"
    >
      <div className="blog-cover min-h-[220px] md:min-h-[320px]" style={{ background: post.cover }}>
        <CoverMark />
      </div>
      <div className="flex flex-col justify-center p-6 sm:p-8">
        <PostMeta post={post} />
        <h2 className="font-display mt-3 text-2xl font-bold leading-tight tracking-tight transition group-hover:text-primary sm:text-3xl">{post.title}</h2>
        <p className="mt-3 text-[15px] leading-7 text-muted">{post.excerpt}</p>
        <span className="mt-5 inline-flex items-center gap-1.5 text-sm font-semibold text-primary">
          Read the post <ArrowRight className="h-4 w-4 transition group-hover:translate-x-0.5" />
        </span>
      </div>
    </Link>
  );
}

function PostCard({ post }: { post: BlogPost }) {
  return (
    <Link to={`/blog/${post.slug}`} className="group flex flex-col overflow-hidden rounded-3xl border border-line bg-surface transition hover:-translate-y-0.5 hover:border-primary/40">
      <div className="blog-cover h-40" style={{ background: post.cover }}>
        <CoverMark small />
      </div>
      <div className="flex flex-1 flex-col p-5">
        <PostMeta post={post} />
        <h3 className="font-display mt-2.5 text-lg font-bold leading-snug transition group-hover:text-primary">{post.title}</h3>
        <p className="mt-2 line-clamp-3 text-sm leading-6 text-muted">{post.excerpt}</p>
      </div>
    </Link>
  );
}

function CoverMark({ small }: { small?: boolean }) {
  return (
    <div className="flex h-full items-end p-5">
      <img src="/brand/logo/optara-lockup-dark.svg" alt="" className={cx("w-auto opacity-90 drop-shadow", small ? "h-6" : "h-8")} />
    </div>
  );
}

function PostMeta({ post }: { post: BlogPost }) {
  return (
    <div className="flex flex-wrap items-center gap-2 text-xs font-semibold text-faint">
      <span className="rounded-full bg-primary-soft px-2.5 py-0.5 text-primary">{post.tag}</span>
      <span>{fmtPostDate(post.date)}</span>
      <span className="inline-flex items-center gap-1">
        <Clock className="h-3 w-3" /> {post.readMins} min read
      </span>
    </div>
  );
}

function FollowBanner() {
  return (
    <div className="mt-16 flex flex-col items-start justify-between gap-4 rounded-3xl border border-primary/25 bg-primary-soft p-6 sm:flex-row sm:items-center sm:p-8">
      <div>
        <div className="font-display text-xl font-bold">Never miss an update</div>
        <p className="mt-1 text-sm text-muted">New markets, product releases and posts are announced on X first.</p>
      </div>
      <a href={SOCIALS.x.href} target="_blank" rel="noreferrer" className="btn-primary whitespace-nowrap">
        <XIcon className="h-4 w-4" /> Follow {SOCIALS.x.handle}
      </a>
    </div>
  );
}

export function BlogPostPage() {
  const { slug } = useParams();
  const post = postBySlug(slug);
  useEffect(() => {
    if (!post) return;
    document.title = `${post.title} · Optara`;
    window.scrollTo({ top: 0 });
    return () => {
      document.title = "Optara";
    };
  }, [post]);
  if (!post) return <Navigate to="/blog" replace />;
  const more = POSTS.filter((p) => p.slug !== post.slug).slice(0, 2);
  const shareUrl = `https://x.com/intent/tweet?text=${encodeURIComponent(`${post.title} by ${SOCIALS.x.handle}`)}&url=${encodeURIComponent(location.href)}`;

  return (
    <div className="home-page min-h-screen bg-bg text-ink">
      <SiteHeader />
      <main className="home-column pb-20 pt-6">
        <article className="mx-auto max-w-[720px]">
          <Link to="/blog" className="inline-flex items-center gap-1.5 text-sm font-semibold text-muted hover:text-ink">
            <ArrowLeft className="h-4 w-4" /> All posts
          </Link>
          <div className="mt-6">
            <PostMeta post={post} />
          </div>
          <h1 className="font-display mt-4 text-4xl font-bold leading-[1.1] tracking-tight sm:text-5xl">{post.title}</h1>
          <p className="mt-4 text-lg leading-8 text-muted">{post.excerpt}</p>
          <div className="blog-cover mt-8 h-56 rounded-3xl sm:h-72" style={{ background: post.cover }}>
            <CoverMark />
          </div>
          <div className="mt-8">{post.body()}</div>

          <div className="mt-12 flex flex-wrap items-center justify-between gap-3 border-t border-line pt-6">
            <span className="text-sm text-muted">Enjoyed this? Share it.</span>
            <a href={shareUrl} target="_blank" rel="noreferrer" className="btn-ghost text-sm">
              <XIcon className="h-3.5 w-3.5" /> Share on X
            </a>
          </div>
        </article>

        {more.length > 0 && (
          <section className="mx-auto mt-16 max-w-[1000px]">
            <h2 className="font-display text-2xl font-bold">Keep reading</h2>
            <div className="mt-5 grid gap-5 sm:grid-cols-2">
              {more.map((p) => (
                <PostCard key={p.slug} post={p} />
              ))}
            </div>
          </section>
        )}
      </main>
      <SiteFooter />
    </div>
  );
}
