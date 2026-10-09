/**
 * Renders the README screenshots in the style of the house's store pictures: the
 * captured web interface in a browser window on a dark ground with Securo's mark
 * as a relief, a heading and a line of text beside it. 1920x1000 each.
 *
 * The captures in captures/ are 1440x700 at twice the pixel density, taken from a
 * test instance with made-up accounts and transactions, in Securo's dark mode.
 *
 * Needs playwright-core installed globally and Chrome.
 * Run: node .github/assets/screenshots/render.mjs
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";

const require = createRequire(import.meta.url);
const { chromium } = require(`${execSync("npm root -g").toString().trim()}/playwright-core`);

const here = dirname(fileURLToPath(import.meta.url));

const SHOTS = [
  { file: "securo-1.png", capture: "dashboard.png", caption: "Your finances,<br><em>your server</em>", sub: "Securo on Unraid, installed from a single template" },
  { file: "securo-2.png", capture: "transactions.png", caption: "Every cent,<br><em>in its place</em>", sub: "Categories, rules, imports and bank sync, all kept at home" },
];

async function cached(file, url) {
  const path = join(tmpdir(), `securo-${file}`);
  if (!existsSync(path)) {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`${file}: fetch ${res.status}`);
    writeFileSync(path, Buffer.from(await res.arrayBuffer()));
  }
  return readFileSync(path);
}

const dataUrl = (buf, type) => `data:${type};base64,${buf.toString("base64")}`;
const fonts = "https://github.com/google/fonts/raw/main/ofl";
const bree = dataUrl(await cached("BreeSerif-Regular.ttf", `${fonts}/breeserif/BreeSerif-Regular.ttf`), "font/ttf");
const lato = dataUrl(await cached("Lato-Regular.ttf", `${fonts}/lato/Lato-Regular.ttf`), "font/ttf");
const logo = dataUrl(readFileSync(join(here, "..", "icon.svg")), "image/svg+xml");

const STYLE = `
@font-face { font-family: "Bree Serif"; src: url(${bree}); }
@font-face { font-family: Lato; src: url(${lato}); }
* { box-sizing: border-box; margin: 0; }
body { position: relative; width: 1920px; height: 1000px; overflow: hidden; font-family: Lato, sans-serif; background: #0c0c0b; }
.wall { position: absolute; inset: 0; background: radial-gradient(55% 60% at 62% 35%, #26231d, #0f0e0c 72%); }
.relief { position: absolute; width: 56%; left: -12%; top: 4%; transform: rotate(-10deg); opacity: .32;
  filter: grayscale(1) brightness(.36) contrast(1.2) drop-shadow(-2px -2px 0 rgba(255,255,255,.16)) drop-shadow(12px 18px 26px rgba(0,0,0,.85)); }
.vignette { position: absolute; inset: 0; box-shadow: inset 0 0 200px rgba(0,0,0,.6); }
.copy { position: absolute; left: 84px; top: 0; bottom: 0; width: 470px; display: flex; flex-direction: column; justify-content: center; gap: 28px; }
.copy img { width: 132px; }
h1 { font: 400 64px/1.12 "Bree Serif", serif; color: #f4f4f4; }
h1 em { font-style: normal; color: #FCC419; }
.sub { font-size: 28px; line-height: 1.35; color: #9d9481; }
.stage { position: absolute; left: 600px; top: 148px; width: 1270px; perspective: 2400px; }
.floor { position: absolute; left: 12%; right: 12%; bottom: -4%; height: 8%; border-radius: 50%; background: rgba(0,0,0,.8); filter: blur(30px); }
.win { position: relative; transform: rotateY(-8deg) rotateX(2deg); border-radius: 14px; overflow: hidden; background: #161616;
  box-shadow: 0 0 0 1px #3c3c3c, 0 2px 4px rgba(0,0,0,.35), 0 18px 36px rgba(0,0,0,.45), 0 52px 100px rgba(0,0,0,.55); }
.win > img { display: block; width: 1270px; height: 617px; }
.bar { position: relative; display: flex; align-items: center; color: #d6d6d6; font: 400 17px/1 Lato, sans-serif; }
.tabs { height: 42px; padding: 7px 0 0 12px; background: #1c1c1c; align-items: flex-end; }
.tab { display: flex; align-items: center; gap: 10px; height: 35px; padding: 0 70px 0 14px; border-radius: 10px 10px 0 0; background: #2c2c2c; font-size: 15px; }
.tab img { width: 20px; height: 20px; object-fit: contain; }
.address { height: 46px; gap: 14px; padding: 0 14px; background: #2c2c2c; border-bottom: 1px solid #111; }
.nav { width: 10px; height: 10px; border-left: 2px solid #9a9a9a; border-bottom: 2px solid #9a9a9a; transform: rotate(45deg); margin: 0 4px; }
.nav.fwd { transform: rotate(-135deg); border-color: #5a5a5a; }
.url { flex: 1; height: 32px; border-radius: 16px; background: #1a1a1a; padding-left: 18px; display: flex; align-items: center; font-size: 15px; color: #c9c9c9; }
.glare { position: absolute; inset: 0; pointer-events: none;
  background: linear-gradient(118deg, rgba(255,255,255,.09) 0%, rgba(255,255,255,.03) 28%, rgba(255,255,255,0) 42%); }
`;

const page = ({ capture, caption, sub }) => `<!doctype html><html><head><meta charset="utf-8"><style>${STYLE}</style></head><body>
<div class="wall"></div><img class="relief" src="${logo}"><div class="vignette"></div>
<div class="copy"><img src="${logo}"><h1>${caption}</h1><p class="sub">${sub}</p></div>
<div class="stage"><div class="floor"></div><div class="win">
  <div class="bar tabs"><div class="tab"><img src="${logo}"><span>Securo</span></div></div>
  <div class="bar address"><i class="nav"></i><i class="nav fwd"></i><div class="url">nas.local:3000</div></div>
  <img src="${dataUrl(readFileSync(join(here, "captures", capture)), "image/png")}"><div class="glare"></div>
</div></div>
</body></html>`;

// Rendered at twice the size and scaled down, which keeps the type crisp.
const browser = await chromium.launch({ channel: "chrome" });
for (const shot of SHOTS) {
  const big = await browser.newPage({ viewport: { width: 1920, height: 1000 }, deviceScaleFactor: 2 });
  await big.setContent(page(shot));
  await big.evaluate(() => document.fonts.ready);
  const png = await big.screenshot();
  await big.close();
  const small = await browser.newPage({ viewport: { width: 1920, height: 1000 } });
  await small.setContent(`<body style="margin:0"><img src="${dataUrl(png, "image/png")}" style="display:block;width:1920px;height:1000px">`);
  await small.locator("img").evaluate((img) => img.decode());
  await small.screenshot({ path: join(here, shot.file) });
  await small.close();
  console.log(`${shot.file} written`);
}
await browser.close();
