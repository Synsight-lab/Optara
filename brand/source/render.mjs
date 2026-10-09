// Rasterizes the SVGs from build.mjs to PNG with Playwright's Chromium, and writes a contact sheet.
//   node render.mjs            (needs `playwright`; set CHROMIUM=/path/to/chrome to use a preinstalled browser)
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "..");

// [svg, output, width]: height follows the SVG's aspect. Full-bleed art is JPEG (the grain makes PNG heavy).
const JOBS = [
  ["logo/optara-mark.svg", "logo/optara-mark-1024.png", 1024],
  ["logo/optara-mark-on-light.svg", "logo/optara-mark-on-light-1024.png", 1024],
  ["logo/optara-mark-white.svg", "logo/optara-mark-white-1024.png", 1024],
  ["logo/optara-mark-black.svg", "logo/optara-mark-black-1024.png", 1024],
  ["logo/optara-app-icon.svg", "logo/optara-app-icon-1024.png", 1024],
  ["logo/optara-lockup-dark.svg", "logo/optara-lockup-dark-2000.png", 2000],
  ["logo/optara-lockup-light.svg", "logo/optara-lockup-light-2000.png", 2000],
  ["logo/optara-lockup-tagline-dark.svg", "logo/optara-lockup-tagline-dark-2000.png", 2000],
  ["logo/optara-lockup-tagline-light.svg", "logo/optara-lockup-tagline-light-2000.png", 2000],
  ["logo/optara-stacked-dark.svg", "logo/optara-stacked-dark-1200.png", 1200],
  ["logo/optara-stacked-light.svg", "logo/optara-stacked-light-1200.png", 1200],
  ["favicon/favicon.svg", "favicon/favicon-16.png", 16],
  ["favicon/favicon.svg", "favicon/favicon-32.png", 32],
  ["favicon/favicon.svg", "favicon/favicon-48.png", 48],
  ["logo/optara-app-icon.svg", "favicon/apple-touch-icon.png", 180],
  ["logo/optara-app-icon.svg", "favicon/icon-192.png", 192],
  ["logo/optara-app-icon.svg", "favicon/icon-512.png", 512],
  ["social/avatar.svg", "social/avatar-400.png", 400],
  ["social/avatar.svg", "social/avatar-1024.png", 1024],
  ["social/twitter-header.svg", "social/twitter-header-1500x500.jpg", 1500],
  ["social/twitter-header.svg", "social/twitter-header-3000x1000.jpg", 3000],
  ["social/og-image.svg", "social/og-image-1200x630.jpg", 1200],
  ["backgrounds/hero.svg", "backgrounds/hero-2560x1440.jpg", 2560],
  ["backgrounds/hero.svg", "backgrounds/hero-1920x1080.jpg", 1920],
  ["backgrounds/hero-mobile.svg", "backgrounds/hero-mobile-1080x1920.jpg", 1080],
  ["backgrounds/pattern-tile.svg", "backgrounds/pattern-tile-240.png", 240],
];

const dims = (s) => {
  const m = s.match(/viewBox="0 0 ([\d.]+) ([\d.]+)"/);
  return [Number(m[1]), Number(m[2])];
};

const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
const page = await browser.newPage();
for (const [src, dst, w] of JOBS) {
  const s = readFileSync(join(OUT, src), "utf8");
  const [vw, vh] = dims(s);
  const h = Math.round((w * vh) / vw);
  await page.setViewportSize({ width: w, height: h });
  const sized = s.replace(/width="[\d.]+" height="[\d.]+"/, `width="${w}" height="${h}"`);
  await page.setContent(`<html><body style="margin:0;background:transparent">${sized}</body></html>`);
    const clip = { x: 0, y: 0, width: w, height: h };
  if (dst.endsWith(".jpg")) await page.screenshot({ path: join(OUT, dst), type: "jpeg", quality: 90, clip });
  else await page.screenshot({ path: join(OUT, dst), omitBackground: true, clip });
}

// Contact sheet (review only; not part of the kit).
const img = (p, style = "") => `<img src="data:image/svg+xml;base64,${readFileSync(join(OUT, p)).toString("base64")}" style="${style}">`;
const sheet = `<html><body style="margin:0;padding:48px;background:#050509;font:14px Inter,sans-serif;color:#a09bb8;width:1904px">
<div style="display:flex;gap:40px;align-items:center;margin-bottom:40px">
  <div style="background:#08080f;padding:32px;border-radius:16px">${img("logo/optara-mark.svg", "width:160px")}</div>
  <div style="background:#f4f3ff;padding:32px;border-radius:16px">${img("logo/optara-mark-on-light.svg", "width:160px")}</div>
  ${img("logo/optara-app-icon.svg", "width:224px")}
  <div style="background:#08080f;padding:24px;border-radius:16px">${img("favicon/favicon.svg", "width:32px")} ${img("favicon/favicon.svg", "width:16px")}</div>
  ${img("social/avatar.svg", "width:224px;border-radius:50%")}
  <div style="background:#7c6cff;padding:32px;border-radius:16px">${img("logo/optara-mark-white.svg", "width:120px")}</div>
</div>
<div style="display:flex;gap:40px;margin-bottom:40px">
  <div style="background:#08080f;padding:40px;border-radius:16px">${img("logo/optara-lockup-tagline-dark.svg", "height:96px")}</div>
  <div style="background:#f4f3ff;padding:40px;border-radius:16px">${img("logo/optara-lockup-tagline-light.svg", "height:96px")}</div>
  <div style="background:#08080f;padding:24px 40px;border-radius:16px">${img("logo/optara-stacked-dark.svg", "height:130px")}</div>
</div>
${img("social/twitter-header.svg", "width:1500px;display:block;margin-bottom:40px;border-radius:12px")}
<div style="display:flex;gap:40px;align-items:flex-start">
  ${img("social/og-image.svg", "width:900px;border-radius:12px")}
  ${img("backgrounds/hero.svg", "width:900px;border-radius:12px")}
</div></body></html>`;
writeFileSync(join(OUT, "source/.sheet.html"), sheet);
await page.setViewportSize({ width: 2000, height: 1200 });
await page.setContent(sheet);
await page.waitForTimeout(300);
await page.screenshot({ path: process.env.SHEET ?? join(OUT, "source/.sheet.png"), fullPage: true });
await browser.close();
console.log(`rendered ${JOBS.length} files`);
