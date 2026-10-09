# Optara brand kit

Logo, icons, social images and backgrounds for the website, the app, X/Twitter and anything else that carries the
Optara name. Every file is generated from [`source/build.mjs`](source/build.mjs); edit that, not the outputs.

## The mark

A ring broken open by a call payoff: flat below the strike, a kink, then a ray that leaves the circle.

- **Ring:** the O of Optara and the book that clears: one account, one margin, positions that offset.
- **Payoff:** `max(S − K, 0)`, the standard European call that Optara pays in full. The flat leg cuts through the ring
  and the ray escapes it: **uncapped**, the thing that sets Optara PM apart from the capped V2.
- **Colour:** the ray goes from ink to call-green, the app's own "good" colour, as the payoff moves into the money.

The backgrounds use the same idea at scale: real Black-76 call-value curves for a fan of times to expiry, hardening
into the payoff kink as expiry approaches.

## Files

| Use | File |
|---|---|
| Mark, dark backgrounds | `logo/optara-mark.svg` · `-1024.png` |
| Mark, light backgrounds | `logo/optara-mark-on-light.svg` · `-1024.png` |
| One-colour mark (print, overlays, on purple) | `logo/optara-mark-white.svg`, `logo/optara-mark-black.svg` |
| App icon (rounded tile) | `logo/optara-app-icon.svg` · `-1024.png` |
| Horizontal logo | `logo/optara-lockup-{dark,light}.svg` · `-2000.png` |
| Horizontal logo + "Options on Monad" | `logo/optara-lockup-tagline-{dark,light}.svg` · `-2000.png` |
| Stacked logo | `logo/optara-stacked-{dark,light}.svg` · `-1200.png` |
| Favicon | `favicon/favicon.svg`, `favicon-16/32/48.png` |
| Apple touch / PWA icons | `favicon/apple-touch-icon.png` (180), `icon-192.png`, `icon-512.png` |
| X/Twitter profile picture | `social/avatar-400.png` (`-1024.png` for other platforms) |
| X/Twitter header | `social/twitter-header-1500x500.jpg` (`3000x1000` for retina) |
| Link preview (Open Graph / Twitter card) | `social/og-image-1200x630.jpg` |
| Website hero background | `backgrounds/hero-1920x1080.jpg`, `hero-2560x1440.jpg`, `hero-mobile-1080x1920.jpg` |
| Quiet section background (repeat) | `backgrounds/pattern-tile.svg` · `-240.png` |

"dark" files have light ink for dark backgrounds; "light" files have dark ink for light backgrounds. All text in the
SVGs is outlined, so they render the same without the font installed.

### Website

```html
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<meta property="og:image" content="https://<domain>/og-image-1200x630.jpg">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="https://<domain>/og-image-1200x630.jpg">
```

Hero background: `background: #08080f url(hero-1920x1080.jpg) center / cover no-repeat;` (mobile file under
`max-aspect-ratio: 3/4`). The artwork is quietest top-left, so put headlines there.

### X/Twitter

The profile picture is full-bleed: X crops it to a circle. The header keeps the logo and line clear of the lower-left
corner, where the profile picture overlaps it.

## Colour

The app's tokens (`frontend/src/index.css`), so the brand and the product match.

| Token | Hex | Use |
|---|---|---|
| Void | `#08080f` | Backgrounds |
| Panel | `#101019` | Cards, surfaces |
| Optara purple | `#7c6cff` | The ring, primary actions |
| Purple light | `#a99dff` | Ring highlight, links on dark |
| Ink | `#f4f3ff` | Text and the mark on dark |
| Muted | `#a09bb8` | Secondary text, taglines |
| Call green | `#00e5a0` | The payoff ray, calls, gains |
| Put berry | `#ff4d6d` | Puts, losses (accent only) |
| Amber | `#ffb224` | Warnings, highlights (sparingly) |

## Type

**Space Grotesk** Bold for the wordmark and headlines (lowercase "optara", tracking −2.5%); Medium for taglines.
**Inter** for body text and UI. Both are free (OFL).

## Rules

- Clear space around the mark: at least the ring's stroke width × 2 on every side. Minimum size: 16 px for the
  mark (favicon), 96 px wide for the horizontal logo.
- Don't recolour the ray red (it is a call, and red means loss in the app), rotate the mark, add effects, or set
  "optara" in another font. Use the one-colour marks where colour isn't possible.
- The name is lowercase in the logo and "Optara" in running text.

## Regenerating

```bash
cd brand/source
npm install                                   # opentype.js, Space Grotesk, Playwright
node build.mjs                                # SVGs
CHROMIUM=/path/to/chrome node render.mjs      # PNG/JPEG (omit CHROMIUM to use Playwright's browser)
```
