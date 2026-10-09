// Rasterizes the SVGs from build.mjs (PNG for logos and icons, JPEG for full-bleed art, whose grain makes PNG
// heavy) and screenshots guidelines.html to guidelines.png.
//   node render.mjs        (CHROMIUM=/path/to/chrome to use a preinstalled browser)
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { chromium } from "playwright";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "..");

// [svg, output, width]: height follows the SVG's aspect.
const JOBS = [
  ["logo/optara-mark.svg", "logo/optara-mark-1024.png", 1024],
  ["logo/optara-mark-on-light.svg", "logo/optara-mark-on-light-1024.png", 1024],
  ["logo/optara-mark-white.svg", "logo/optara-mark-white-1024.png", 1024],
  ["logo/optara-mark-black.svg", "logo/optara-mark-black-1024.png", 1024],
  ["logo/optara-app-icon.svg", "logo/optara-app-icon-1024.png", 1024],
  ["logo/optara-lockup-dark.svg", "logo/optara-lockup-dark-2000.png", 2000],
  ["logo/optara-lockup-light.svg", "logo/optara-lockup-light-2000.png", 2000],
  ["logo/optara-lockup-white.svg", "logo/optara-lockup-white-2000.png", 2000],
  ["logo/optara-lockup-black.svg", "logo/optara-lockup-black-2000.png", 2000],
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
  ["social/community-banner.svg", "social/community-banner-960x540.jpg", 960],
  ["social/community-banner.svg", "social/community-banner-1920x1080.jpg", 1920],
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

await page.setViewportSize({ width: 1440, height: 1000 });
await page.goto(pathToFileURL(join(OUT, "guidelines.html")).href);
await page.evaluate(() => document.fonts.ready);
await page.waitForTimeout(300);
await page.screenshot({ path: join(OUT, "guidelines.png"), fullPage: true });
await browser.close();
console.log(`rendered ${JOBS.length} files and guidelines.png`);
