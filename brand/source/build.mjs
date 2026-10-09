// Generates every Optara brand asset as SVG (brand/README.md). Rasterize with render.mjs.
//   cd brand/source && npm i --no-save opentype.js@1.3.4 @fontsource/space-grotesk@5.1.0 && node build.mjs
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import opentype from "opentype.js";

const require = createRequire(import.meta.url);
const OUT = join(dirname(fileURLToPath(import.meta.url)), "..");
const font = (w) =>
  opentype.parse(
    readFileSync(require.resolve(`@fontsource/space-grotesk/files/space-grotesk-latin-${w}-normal.woff`)).buffer,
  );
const BOLD = font(700);
const MEDIUM = font(500);

// Palette: the app's tokens (frontend/src/index.css).
export const C = {
  void: "#08080f",
  panel: "#101019",
  deep: "#1c1440",
  purple: "#7c6cff",
  purpleLight: "#a99dff",
  green: "#00e5a0",
  berry: "#ff4d6d",
  amber: "#ffb224",
  ink: "#f4f3ff",
  muted: "#a09bb8",
};

const write = (rel, svg) => {
  const p = join(OUT, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, svg.trim() + "\n");
};
const svg = (w, h, body, extra = "") =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}"${extra}>${body}</svg>`;

// ---------------------------------------------------------------------------------------------- the mark
// A ring (the O, the bounded book that clears) broken open by a call payoff: flat, a kink at the strike, then a
// ray that leaves the ring. Uncapped upside: the line is never stopped by the circle.
// Geometry in a 64-unit box; ring centre (32,32), r 19.
const R = 19;
const CX = 32;
const CY = 32;
const KINK = [32, 40];
const RAY_END = [55, 17];
const FLAT_START = 8;
// The ring is open where the ray exits, from −18° to −62° (SVG angles, y down); where the flat leg crosses the ring,
// the ring is cut by a mask (so the mark stays transparent on any background).
const arcPt = (deg) => [CX + R * Math.cos((deg * Math.PI) / 180), CY + R * Math.sin((deg * Math.PI) / 180)];
const [gx1, gy1] = arcPt(-18);
const [gx2, gy2] = arcPt(-62);
const ringPath = `M${gx1.toFixed(2)} ${gy1.toFixed(2)} A${R} ${R} 0 1 1 ${gx2.toFixed(2)} ${gy2.toFixed(2)}`;
const payoffPath = `M${FLAT_START} ${KINK[1]} L${KINK[0]} ${KINK[1]} L${RAY_END[0]} ${RAY_END[1]}`;

const cutMask = (id, stroke) => `<mask id="${id}-cut" maskUnits="userSpaceOnUse" x="0" y="0" width="64" height="64">
    <rect width="64" height="64" fill="#fff"/><path d="${payoffPath}" fill="none" stroke="#000" stroke-width="${stroke * 1.9}" stroke-linecap="round" stroke-linejoin="round"/></mask>`;

/** The mark as a group drawn in a 64 box. variant: color | white | black | gradient ids prefixed by `id`. */
function markBody({ variant = "color", id = "m", stroke = 6 } = {}) {
  if (variant === "white" || variant === "black") {
    const c = variant === "white" ? C.ink : C.void;
    return `<defs>${cutMask(id, stroke)}</defs><g fill="none" stroke="${c}" stroke-width="${stroke}" stroke-linecap="round" stroke-linejoin="round">
      <path d="${ringPath}" mask="url(#${id}-cut)"/><path d="${payoffPath}"/></g>`;
  }
  return `<defs>${cutMask(id, stroke)}
    <linearGradient id="${id}-ring" x1="12" y1="52" x2="52" y2="12" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="${C.purple}"/><stop offset="1" stop-color="${C.purpleLight}"/></linearGradient>
    <linearGradient id="${id}-ray" x1="${FLAT_START}" y1="${KINK[1]}" x2="${RAY_END[0]}" y2="${RAY_END[1]}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="${C.ink}"/><stop offset="0.45" stop-color="${C.ink}"/><stop offset="1" stop-color="${C.green}"/></linearGradient>
  </defs>
  <g fill="none" stroke-width="${stroke}" stroke-linecap="round" stroke-linejoin="round">
    <path d="${ringPath}" stroke="url(#${id}-ring)" mask="url(#${id}-cut)"/>
    <path d="${payoffPath}" stroke="url(#${id}-ray)"/>
  </g>`;
}
/** Light-background colour variant: deep ring, purple-to-green ray. */
function markBodyOnLight(id = "ml", stroke = 6) {
  return `<defs>${cutMask(id, stroke)}
    <linearGradient id="${id}-ray" x1="${FLAT_START}" y1="${KINK[1]}" x2="${RAY_END[0]}" y2="${RAY_END[1]}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="${C.void}"/><stop offset="0.45" stop-color="${C.void}"/><stop offset="1" stop-color="#00b37d"/></linearGradient>
  </defs>
  <g fill="none" stroke-width="${stroke}" stroke-linecap="round" stroke-linejoin="round">
    <path d="${ringPath}" stroke="${C.purple}" mask="url(#${id}-cut)"/>
    <path d="${payoffPath}" stroke="url(#${id}-ray)"/>
  </g>`;
}

/** App-icon tile: the mark on a rounded void square with a soft purple glow. */
function tile(size, { radius = 0.25, id = "t" } = {}) {
  const s = size / 64;
  const rx = 64 * radius;
  return svg(
    size,
    size,
    `<g transform="scale(${s})">
    <defs>
      <radialGradient id="${id}-bg" cx="0.5" cy="0.38" r="0.75">
        <stop offset="0" stop-color="#1d1648"/><stop offset="0.6" stop-color="#0e0c1d"/><stop offset="1" stop-color="${C.void}"/></radialGradient>
      <clipPath id="${id}-clip"><rect width="64" height="64" rx="${rx}"/></clipPath>
    </defs>
    <g clip-path="url(#${id}-clip)">
      <rect width="64" height="64" fill="url(#${id}-bg)"/>
      <rect x="0.5" y="0.5" width="63" height="63" rx="${rx - 0.5}" fill="none" stroke="#ffffff" stroke-opacity="0.08"/>
      <g transform="translate(5.12 5.12) scale(0.84)">${markBody({ id: `${id}-m` })}</g>
    </g></g>`,
  );
}
/** Full-bleed square (no rounding) for avatars: platforms crop to a circle themselves. */
function avatar(size, id = "a") {
  const s = size / 64;
  return svg(
    size,
    size,
    `<g transform="scale(${s})">
    <defs><radialGradient id="${id}-bg" cx="0.5" cy="0.42" r="0.7">
      <stop offset="0" stop-color="#231a5a"/><stop offset="0.55" stop-color="#0f0c22"/><stop offset="1" stop-color="${C.void}"/></radialGradient></defs>
    <rect width="64" height="64" fill="url(#${id}-bg)"/>
    <g transform="translate(9.6 9.6) scale(0.7)">${markBody({ id: `${id}-m` })}</g></g>`,
  );
}

// ---------------------------------------------------------------------------------------------- wordmark
/** Text as outlined paths (no font needed by consumers). Returns {d, width} at the given size, baseline at y. */
function textPath(f, text, size, x, y, letterSpacing = 0) {
  let d = "";
  let cx = x;
  const scale = size / f.unitsPerEm;
  const glyphs = f.stringToGlyphs(text);
  glyphs.forEach((g, i) => {
    d += g.getPath(cx, y, size).toPathData(2);
    cx += g.advanceWidth * scale;
    if (i < glyphs.length - 1) cx += f.getKerningValue(g, glyphs[i + 1]) * scale + letterSpacing;
  });
  return { d, width: cx - x };
}

/** Horizontal lockup: mark + "optara". theme dark (light ink) or light (void ink). */
function lockup({ theme = "dark", withTag = false, id = "l" } = {}) {
  const H = 64;
  const ink = theme === "dark" ? C.ink : C.void;
  const word = textPath(BOLD, "optara", 46, 80, 47, -1.2);
  let width = 80 + word.width + 4;
  let tag = "";
  if (withTag) {
    const t = textPath(MEDIUM, "OPTIONS ON MONAD", 10.5, 82, 74, 1.6);
    tag = `<path d="${t.d}" fill="${theme === "dark" ? C.muted : "#5d5874"}"/>`;
  }
  const mark = theme === "dark" ? markBody({ id: `${id}-m` }) : markBodyOnLight(`${id}-m`);
  return svg(
    Math.ceil(width),
    withTag ? 78 : H,
    `${mark}<path d="${word.d}" fill="${ink}"/>${tag}`,
  );
}
/** Stacked lockup: mark above the word, centered. */
function stacked(theme = "dark", id = "s") {
  const ink = theme === "dark" ? C.ink : C.void;
  const word = textPath(BOLD, "optara", 40, 0, 0, -1);
  const W = Math.max(64, word.width) + 8;
  const w2 = textPath(BOLD, "optara", 40, (W - word.width) / 2, 108, -1);
  const mark = theme === "dark" ? markBody({ id: `${id}-m` }) : markBodyOnLight(`${id}-m`);
  return svg(Math.ceil(W), 120, `<g transform="translate(${(W - 64) / 2} 0)">${mark}</g><path d="${w2.d}" fill="${ink}"/>`);
}

// ---------------------------------------------------------------------------------------------- backgrounds
// Option-value curves: Black-76 call value (zero rates) against spot, for a fan of times to expiry. As time runs
// out the curve hardens into the payoff kink, which is the mark. Real math, not decoration.
const erf = (x) => {
  const s = Math.sign(x);
  x = Math.abs(x);
  const t = 1 / (1 + 0.3275911 * x);
  const y = 1 - ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-x * x);
  return s * y;
};
const N = (x) => 0.5 * (1 + erf(x / Math.SQRT2));
const call = (F, K, sigT) => {
  if (sigT < 1e-9) return Math.max(F - K, 0);
  const d1 = (Math.log(F / K) + 0.5 * sigT * sigT) / sigT;
  return F * N(d1) - K * N(d1 - sigT);
};

/**
 * A field of value curves. Spot runs left→right across [x0,x1]; value maps to y upward from baseY.
 * Returns path markup with per-curve opacity, newest (near-expiry) brightest.
 */
function curveField({ x0, x1, baseY, K = 1, Fmin = 0.45, Fmax = 1.9, yScale, count = 18, id, stroke = 1.4, maxSig = 1.6 }) {
  let out = "";
  for (let i = 0; i < count; i++) {
    const f = i / (count - 1); // 0 = far from expiry, 1 = at expiry
    const sigT = maxSig * (1 - f) ** 1.6;
    const pts = [];
    const steps = 160;
    for (let j = 0; j <= steps; j++) {
      const F = Fmin + ((Fmax - Fmin) * j) / steps;
      const x = x0 + ((x1 - x0) * j) / steps;
      const y = baseY - call(F, K, sigT) * yScale;
      pts.push(`${x.toFixed(1)} ${y.toFixed(1)}`);
    }
    const op = (0.14 + 0.5 * f ** 1.3).toFixed(3);
    const isLast = i === count - 1;
    out += `<path d="M${pts.join(" L")}" fill="none" stroke="${isLast ? `url(#${id}-hot)` : `url(#${id}-cool)`}" stroke-opacity="${isLast ? 1 : op}" stroke-width="${isLast ? stroke * 2.2 : stroke}" stroke-linecap="round" stroke-linejoin="round"/>`;
  }
  return out;
}

/** Shared backdrop: void, purple/berry glows, a faint grid, grain. */
function backdrop(W, H, id, { glowX = 0.72, glowY = 0.2, grid = 48 } = {}) {
  return `<defs>
    <radialGradient id="${id}-g1" cx="${glowX}" cy="${glowY}" r="0.65"><stop offset="0" stop-color="${C.purple}" stop-opacity="0.34"/><stop offset="1" stop-color="${C.purple}" stop-opacity="0"/></radialGradient>
    <radialGradient id="${id}-g2" cx="0.08" cy="1.05" r="0.6"><stop offset="0" stop-color="${C.berry}" stop-opacity="0.16"/><stop offset="1" stop-color="${C.berry}" stop-opacity="0"/></radialGradient>
    <radialGradient id="${id}-g3" cx="0.95" cy="0.95" r="0.45"><stop offset="0" stop-color="${C.green}" stop-opacity="0.08"/><stop offset="1" stop-color="${C.green}" stop-opacity="0"/></radialGradient>
    <pattern id="${id}-grid" width="${grid}" height="${grid}" patternUnits="userSpaceOnUse">
      <path d="M${grid} 0H0V${grid}" fill="none" stroke="#ffffff" stroke-opacity="0.045" stroke-width="1"/></pattern>
    <radialGradient id="${id}-gridmask-g" cx="0.6" cy="0.4" r="0.75"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></radialGradient>
    <mask id="${id}-gridmask"><rect width="${W}" height="${H}" fill="url(#${id}-gridmask-g)"/></mask>
    <filter id="${id}-grain" x="0" y="0" width="100%" height="100%">
      <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" stitchTiles="stitch"/>
      <feColorMatrix values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 0.05 0"/></filter>
    <linearGradient id="${id}-cool" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="${C.purple}"/><stop offset="1" stop-color="${C.purpleLight}"/></linearGradient>
    <linearGradient id="${id}-hot" x1="0" y1="0" x2="1" y2="0" gradientUnits="objectBoundingBox">
      <stop offset="0" stop-color="${C.ink}" stop-opacity="0.85"/><stop offset="0.5" stop-color="${C.ink}"/><stop offset="1" stop-color="${C.green}"/></linearGradient>
    <filter id="${id}-blur" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="6"/></filter>
  </defs>
  <rect width="${W}" height="${H}" fill="${C.void}"/>
  <rect width="${W}" height="${H}" fill="url(#${id}-g1)"/>
  <rect width="${W}" height="${H}" fill="url(#${id}-g2)"/>
  <rect width="${W}" height="${H}" fill="url(#${id}-g3)"/>
  <rect width="${W}" height="${H}" fill="url(#${id}-grid)" mask="url(#${id}-gridmask)"/>`;
}
const grain = (W, H, id) => `<rect width="${W}" height="${H}" filter="url(#${id}-grain)" opacity="1"/>`;

/** Curves plus a blurred copy of the expiry curve for glow. */
function curves(opts) {
  const field = curveField(opts);
  const last = field.slice(field.lastIndexOf("<path"));
  return `<g filter="url(#${opts.id}-blur)" opacity="0.55">${last}</g>${field}`;
}

function heroBackground(W = 2560, H = 1440, id = "hb") {
  return svg(
    W,
    H,
    `${backdrop(W, H, id)}
    ${curves({ id, x0: W * -0.05, x1: W * 1.05, baseY: H * 0.86, yScale: H * 0.62, count: 22, stroke: 1.6 })}
    ${grain(W, H, id)}`,
  );
}

function twitterHeader(W = 1500, H = 500, id = "th") {
  const word = textPath(BOLD, "optara", 92, 0, 0, -2.4);
  const lx = 120;
  const tagline = textPath(MEDIUM, "Uncapped options on Monad. Portfolio margin. Clears on-chain.", 25, lx, 318, 0);
  return svg(
    W,
    H,
    `${backdrop(W, H, id, { glowX: 0.78, glowY: 0.1, grid: 40 })}
    ${curves({ id, x0: W * 0.36, x1: W * 1.04, baseY: H * 0.94, yScale: H * 0.72, count: 18, stroke: 1.4 })}
    <g transform="translate(${lx} 156) scale(1.55)">${markBody({ id: `${id}-m` })}</g>
    <path d="${textPath(BOLD, "optara", 92, lx + 118, 238, -2.4).d}" fill="${C.ink}"/>
    <path d="${tagline.d}" fill="${C.muted}"/>
    ${grain(W, H, id)}`,
  );
  void word;
}

function ogImage(W = 1200, H = 630, id = "og") {
  const lx = 96;
  const t1 = textPath(BOLD, "European options,", 64, lx, 352, -1.4);
  const t2 = textPath(BOLD, "uncapped.", 64, lx, 428, -1.4);
  const sub = textPath(MEDIUM, "Portfolio margin on Monad · ERC-20 longs · trade on Kuru", 24, lx, 486, 0);
  return svg(
    W,
    H,
    `${backdrop(W, H, id, { glowX: 0.82, glowY: 0.15, grid: 44 })}
    ${curves({ id, x0: W * 0.42, x1: W * 1.06, baseY: H * 0.95, yScale: H * 0.7, count: 16, stroke: 1.4 })}
    <g transform="translate(${lx} 96) scale(1.05)">${markBody({ id: `${id}-m` })}</g>
    <path d="${textPath(BOLD, "optara", 58, lx + 80, 152, -1.4).d}" fill="${C.ink}"/>
    <path d="${t1.d}" fill="${C.ink}"/>
    <path d="${t2.d}" fill="url(#${id}-hot)"/>
    <path d="${sub.d}" fill="${C.muted}"/>
    ${grain(W, H, id)}`,
  );
}

/** Seamless tile: the payoff kink repeated on a grid, very quiet, for section backgrounds. */
function patternTile(S = 240, id = "pt") {
  const k = (x, y, s, o) =>
    `<path d="M${x} ${y} h${12 * s} l${14 * s} ${-14 * s}" fill="none" stroke="${C.purple}" stroke-opacity="${o}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`;
  return svg(
    S,
    S,
    `<rect width="${S}" height="${S}" fill="${C.void}"/>
    <path d="M${S} 0H0V${S}" fill="none" stroke="#ffffff" stroke-opacity="0.04"/>
    ${k(28, 76, 1, 0.22)}${k(148, 196, 1, 0.22)}${k(148, 76, 1, 0.1)}${k(28, 196, 1, 0.1)}`,
  );
}

// ---------------------------------------------------------------------------------------------- write
write("logo/optara-mark.svg", svg(64, 64, markBody()));
write("logo/optara-mark-on-light.svg", svg(64, 64, markBodyOnLight()));
write("logo/optara-mark-white.svg", svg(64, 64, markBody({ variant: "white" })));
write("logo/optara-mark-black.svg", svg(64, 64, markBody({ variant: "black" })));
write("logo/optara-app-icon.svg", tile(512));
write("logo/optara-lockup-dark.svg", lockup({ theme: "dark" }));
write("logo/optara-lockup-light.svg", lockup({ theme: "light" }));
write("logo/optara-lockup-tagline-dark.svg", lockup({ theme: "dark", withTag: true }));
write("logo/optara-lockup-tagline-light.svg", lockup({ theme: "light", withTag: true }));
write("logo/optara-stacked-dark.svg", stacked("dark"));
write("logo/optara-stacked-light.svg", stacked("light"));
write("favicon/favicon.svg", tile(64, { radius: 0.22 }));
write("social/avatar.svg", avatar(400));
write("social/twitter-header.svg", twitterHeader());
write("social/og-image.svg", ogImage());
write("backgrounds/hero.svg", heroBackground());
write("backgrounds/hero-mobile.svg", heroBackground(1080, 1920, "hm"));
write("backgrounds/pattern-tile.svg", patternTile());
console.log("wrote brand assets to", OUT);
