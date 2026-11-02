// The site's pages and the parts they share. Every page carries the same header and footer
// between <!-- site:header --> / <!-- site:footer --> markers; `sync()` writes them (with
// the current page marked) plus the release blocks from ../releases.json. Run `node pages.mjs`
// after editing either; the build ships render() output and the tests fail if the committed
// pages differ from it, so a stale page cannot ship.
import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { BLOCKS, JSON_URL, fill, load, stamp, validate } from './releases.mjs';

export const PAGES = ['index.html', 'features.html', 'download.html', 'versions.html', 'help.html', 'about.html', 'legal.html'];
const NAV = [['features.html', 'Features'], ['versions.html', 'Versions'], ['help.html', 'Help'], ['about.html', 'About']];
// The footer lists every page the header does, plus home and download.
const FOOTER_PAGES = [['index.html', 'Home'], NAV[0], ['download.html', 'Download'], ...NAV.slice(1)];
const current = (page, href) => (page === href ? ' aria-current="page"' : '');

export function header(page) {
  const links = NAV.map(([href, label]) => `    <a href="${href}"${current(page, href)}>${label}</a>`).join('\n');
  return `<header class="site-header">
  <a class="brand" href="index.html" aria-label="Cadence home"${current(page, 'index.html')}><img src="art/mark.svg" alt="" width="40" height="40"><span>Cadence</span></a>
  <nav aria-label="Main navigation">
${links}
    <a class="nav-cta" href="download.html"${current(page, 'download.html')}>Download</a>
  </nav>
</header>`;
}

export function footer() {
  return `<footer class="site-footer">
  <div class="footer-brand"><img src="art/mark.svg" alt="" width="40" height="40"><p><strong>Cadence</strong><br><span class="footer-tagline">Your words. Your rhythm.</span><br>Built by DC Labs, a Daniel J. Cuesta company.</p></div>
  <nav aria-label="Footer">
${FOOTER_PAGES.map(([href, label]) => `    <a href="${href}">${label}</a>`).join('\n')}
    <a href="legal.html#privacy">Privacy</a>
    <a href="legal.html#license">License</a>
    <a href="legal.html#credits">Credits</a>
    <a href="https://github.com/danielcuesta007/cadence" rel="noopener">Source</a>
  </nav>
  <p class="fineprint">© 2026 Daniel Cuesta. MIT licensed. Speech recognition by Whisper (OpenAI) via whisper.cpp, both MIT. Wispr Flow, Superwhisper, Apple and macOS belong to their owners. Cadence is not affiliated with or endorsed by them.</p>
</footer>`;
}

export async function render(data) {
  const list = validate(data);
  const out = {};
  for (const page of PAGES) {
    let html = await readFile(new URL(page, import.meta.url), 'utf8');
    html = fill(html, 'header', header(page), page, 'site');
    html = fill(html, 'footer', footer(), page, 'site');
    for (const [name, make] of Object.entries(BLOCKS[page] || {})) html = fill(html, name, make(list), page);
    out[page] = html;
  }
  return out;
}

export async function sync() {
  const pages = await render(await load());
  for (const [file, html] of Object.entries(pages)) await writeFile(new URL(file, import.meta.url), html);
}

//   node pages.mjs                             rewrite every page's shared and release blocks
//   node pages.mjs stamp <ver> <sha> [day]      record a built release in releases.json first
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [cmd, version, sha, day] = process.argv.slice(2);
  if (cmd === 'stamp') {
    const t = new Date();
    const d = day || `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, '0')}-${String(t.getDate()).padStart(2, '0')}`;
    await writeFile(JSON_URL, JSON.stringify(stamp(await load(), version, sha, d), null, 2) + '\n');
  } else if (cmd) {
    console.error('usage: node pages.mjs [stamp <version> <sha256> [YYYY-MM-DD]]');
    process.exit(2);
  }
  await sync();
}
