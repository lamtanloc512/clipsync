// Renders assets/AppIcon.svg into every icon ClipSync ships:
//   assets/AppIcon.icns        macOS app icon (16–1024 px, PNG-based icns)
//   web/icon.svg               favicon
//   web/icon-180.png           apple-touch-icon (full bleed; iOS rounds the corners itself)
//   web/icon-192.png, -512.png PWA icons
//   web/icon-maskable-512.png  Android adaptive icon (full bleed)
//
// Dev-only; needs Playwright with Chromium (`npm i -g playwright && npx playwright install chromium`).
//   node assets/make-icons.mjs
// Then run `cd web && npm run build` to embed the web icons.

import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const assets = dirname(fileURLToPath(import.meta.url));
const web = join(assets, '../web');
const source = readFileSync(join(assets, 'AppIcon.svg'), 'utf8');

// macOS icon: rounded body with margins and shadow, as drawn in AppIcon.svg.
const rounded = source;
// Full-bleed square for platforms that apply their own mask: crop to the body, drop shadow and corners.
const fullBleed = source
  .replace('viewBox="0 0 1024 1024"', 'viewBox="100 100 824 824"')
  .replace('<g filter="url(#shadow)">', '<g>')
  .replaceAll('rx="186"', 'rx="0"')
  .replace(/<rect x="101\.5"[^>]*\/>/, '');

const browser = await chromium.launch();
const page = await browser.newPage();
async function render(svg, size) {
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(`<html><body style="margin:0;background:transparent">${
    svg.replace('<svg ', `<svg width="${size}" height="${size}" `)}</body></html>`);
  return page.locator('svg').screenshot({ omitBackground: true });
}

// --- icns: header + (type, length, PNG) entries --------------------------------
const icnsTypes = [
  ['icp4', 16], ['icp5', 32], ['ic11', 32], ['ic12', 64], ['ic07', 128],
  ['ic13', 256], ['ic08', 256], ['ic14', 512], ['ic09', 512], ['ic10', 1024],
];
const entries = [];
for (const [type, size] of icnsTypes) {
  const png = await render(rounded, size);
  const header = Buffer.alloc(8);
  header.write(type, 0, 'ascii');
  header.writeUInt32BE(png.length + 8, 4);
  entries.push(header, png);
}
const body = Buffer.concat(entries);
const icnsHeader = Buffer.alloc(8);
icnsHeader.write('icns', 0, 'ascii');
icnsHeader.writeUInt32BE(body.length + 8, 4);
writeFileSync(join(assets, 'AppIcon.icns'), Buffer.concat([icnsHeader, body]));

// --- web -----------------------------------------------------------------------
writeFileSync(join(web, 'icon.svg'), rounded);
writeFileSync(join(web, 'icon-180.png'), await render(fullBleed, 180));
writeFileSync(join(web, 'icon-192.png'), await render(rounded, 192));
writeFileSync(join(web, 'icon-512.png'), await render(rounded, 512));
writeFileSync(join(web, 'icon-maskable-512.png'), await render(fullBleed, 512));

await browser.close();
console.log('icons written');
