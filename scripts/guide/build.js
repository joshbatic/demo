// Builds the guide from scripts/guide/content.js into the web app, the iPhone app's copy and its pictures.
//   node scripts/guide/build.js            (needs Playwright for the pictures; skip them with --no-pictures)
const fs = require('fs'), path = require('path');
const ROOT = path.join(__dirname, '..', '..');
const { blocks, figs, css } = require('./content.js');

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
// the song's own text (what search, the song list, exports and an edited copy see): sections, paragraphs, Q&A
const lines = [], rich = [];
blocks.forEach((b, i) => {
  if (b[0] === 'h') { if (i) { lines.push(''); rich.push(''); } lines.push('[' + b[1] + ']'); rich.push('<span style="font-weight: bold; color: #8E8E96;">' + esc('[' + b[1] + ']') + '</span>'); }
  else if (b[0] === 'p') { lines.push(b[1]); rich.push(esc(b[1])); }
  else if (b[0] === 'q') { lines.push(b[1], b[2]); rich.push('<b>' + esc(b[1]) + '</b>', esc(b[2])); }
});
const TEXT = lines.join('\n'), RICH = rich.join('<br>');

// ---- web: between the markers in www/index.html ----
const f = path.join(ROOT, 'www', 'index.html');
let html = fs.readFileSync(f, 'utf8');
const js = '/*GUIDE-CONTENT (made by scripts/guide/build.js from scripts/guide/content.js; edit it there)*/\n' +
  'var GUIDE_BLOCKS=' + JSON.stringify(blocks) + ',\n  GUIDE_FIGS=' + JSON.stringify(figs) + ',\n  GUIDE_CSS=' + JSON.stringify(css) +
  ',\n  GUIDE_TEXT=' + JSON.stringify(TEXT) + ',\n  GUIDE_RICH=' + JSON.stringify(RICH) + ';\n/*/GUIDE-CONTENT*/';
const a = html.indexOf('/*GUIDE-CONTENT'), z = html.indexOf('/*/GUIDE-CONTENT*/');
if (a < 0 || z < 0) throw new Error('GUIDE-CONTENT markers not found in www/index.html');
html = html.slice(0, a) + js + html.slice(z + '/*/GUIDE-CONTENT*/'.length);
fs.writeFileSync(f, html);

// ---- iPhone: GuideContent.swift ----
const sw = (s) => JSON.stringify(s);   // a JSON string is a valid Swift string literal for this text
const sblocks = blocks.map((b) => b[0] === 'h' ? `.heading(${sw(b[1])})` : b[0] === 'p' ? `.text(${sw(b[1])})`
  : b[0] === 'f' ? `.picture("guide-${b[1]}", ${sw(b[2])})` : `.question(${sw(b[1])}, ${sw(b[2])})`);
fs.writeFileSync(path.join(ROOT, 'native', 'Demo', 'Services', 'GuideContent.swift'),
`// Made by scripts/guide/build.js from scripts/guide/content.js. Edit it there and run the script again.
import Foundation

enum GuideContent {
    enum Block: Hashable {
        case heading(String), text(String), picture(String, String), question(String, String)
    }
    static let blocks: [Block] = [
        ${sblocks.join(',\n        ')}
    ]
    /// The song's own text and formatting, the same as the web's GUIDE_TEXT and GUIDE_RICH.
    static let text = ${sw(TEXT)}
    static let rich = ${sw(RICH)}
}
`);

// ---- iPhone: the pictures, at 3x, on a clear background ----
if (process.argv.includes('--no-pictures')) { console.log('Guide written (no pictures).'); process.exit(0); }
(async () => {
  const { chromium } = require('playwright');
  const b = await chromium.launch(), p = await b.newPage({ deviceScaleFactor: 3, viewport: { width: 400, height: 600 } });
  const dir = path.join(ROOT, 'native', 'Demo', 'Assets.xcassets');
  for (const [k, v] of Object.entries(figs)) {
    await p.setContent(`<!doctype html><meta charset=utf8><style>${css}body{margin:0;background:transparent}.gf{width:316px;padding:3px 3px 7px;box-sizing:border-box}</style><div class="gf">${v}</div>`);
    const set = path.join(dir, `guide-${k}.imageset`); fs.mkdirSync(set, { recursive: true });
    await (await p.$('.gf')).screenshot({ path: path.join(set, `guide-${k}.png`), omitBackground: true });
    fs.writeFileSync(path.join(set, 'Contents.json'), JSON.stringify({ images: [{ filename: `guide-${k}.png`, idiom: 'universal', scale: '3x' }], info: { author: 'xcode', version: 1 } }, null, 2) + '\n');
  }
  await b.close();
  console.log('Guide written, with ' + Object.keys(figs).length + ' pictures.');
})();
