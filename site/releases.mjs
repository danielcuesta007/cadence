// Renders the site's version details from ../releases.json, the one list of Cadence versions.
// Recording a built release is `node pages.mjs stamp <ver> <sha> [day]` (qa/make-dmg.sh).
// Generated blocks sit between <!-- releases:NAME --> and <!-- /releases:NAME --> markers, so
// the pages stay plain static HTML (the site's CSP allows no runtime fetches) and a stale
// page is a test failure, not a silent drift.
import { readFile, writeFile } from 'node:fs/promises';

export const JSON_URL = new URL('../releases.json', import.meta.url);
const REPO = 'https://github.com/danielcuesta007/cadence';

export async function load() { return JSON.parse(await readFile(JSON_URL, 'utf8')); }

const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
export function humanDate(day) {
  const [y, m, d] = day.split('-').map(Number);
  return `${MONTHS[m - 1]} ${d}, ${y}`;
}
const anchor = v => 'v' + v.replace(/\./g, '-');
export const isReleased = r => Boolean(r.date && r.sha256);

const cmp = (a, b) => { const x = a.split('.').map(Number), y = b.split('.').map(Number); return x[0] - y[0] || x[1] - y[1] || x[2] - y[2]; };

export function validate(data) {
  const list = data.releases;
  if (!Array.isArray(list) || !list.length) throw new Error('releases.json has no releases');
  const seen = new Set();
  list.forEach((r, i) => {
    if (!/^\d+\.\d+\.\d+$/.test(r.version)) throw new Error(`bad version ${r.version}`);
    if (seen.has(r.version)) throw new Error(`duplicate version ${r.version}`);
    seen.add(r.version);
    if (!Number.isInteger(r.build) || r.build < 1) throw new Error(`${r.version}: build must be a positive integer`);
    if (!r.title || !Array.isArray(r.highlights) || !r.highlights.length) throw new Error(`${r.version}: needs a title and highlights`);
    if (r.date !== null && !/^\d{4}-\d{2}-\d{2}$/.test(r.date)) throw new Error(`${r.version}: date must be YYYY-MM-DD or null`);
    if (r.sha256 !== null && !/^[0-9a-f]{64}$/.test(r.sha256)) throw new Error(`${r.version}: sha256 must be 64 hex or null`);
    if ((r.date === null) !== (r.sha256 === null)) throw new Error(`${r.version}: date and sha256 are set together`);
    if (i > 0) {
      const prev = list[i - 1];
      if (cmp(prev.version, r.version) <= 0) throw new Error(`${prev.version} must be newer than ${r.version} (newest first)`);
      if (prev.build <= r.build) throw new Error(`${prev.version}: build ${prev.build} must be above ${r.build}`);
      if (!isReleased(r)) throw new Error(`${r.version}: only the newest entry may be unreleased`);
    }
  });
  return list;
}

export function latest(list) { return list.find(isReleased); }

export function timeline(list) {
  const newest = latest(list);
  const items = list.map(r => {
    const released = isReleased(r);
    const tag = !released ? '<span class="release-tag next">In testing</span>' : r === newest ? '<span class="release-tag">Latest</span>' : '';
    const when = released ? `<time datetime="${r.date}">${humanDate(r.date)}</time>` : '<span class="release-when">Not released yet</span>';
    const links = released
      ? `<p class="release-links"><a href="${REPO}/releases/tag/v${r.version}" rel="noopener">Release page and download</a><span class="release-sha">SHA-256 <code>${r.sha256}</code></span></p>`
      : '';
    return `<li class="release${released ? '' : ' upcoming'}" id="${anchor(r.version)}">
  <div class="release-meta"><p class="release-version">${esc(r.version)}</p>${when}${tag}</div>
  <div class="release-body"><h2>${esc(r.title)}</h2>
  <ul>${r.highlights.map(h => `<li>${esc(h)}</li>`).join('')}</ul>${links}</div>
</li>`;
  });
  return `<ol class="timeline">\n${items.join('\n')}\n</ol>`;
}

export function latestLine(list) {
  const r = latest(list);
  return `<p class="version-line">Latest: <b>Cadence ${esc(r.version)}</b>, released ${humanDate(r.date)}. <a href="versions.html#${anchor(r.version)}">What’s new</a></p>`;
}

export function checksum(list) { return `<pre><code data-sha>${latest(list).sha256}</code></pre>`; }

export const BLOCKS = {
  'versions.html': { timeline },
  'download.html': { latest: latestLine, checksum },
};

export function fill(html, name, inner, file = 'page', prefix = 'releases') {
  const re = new RegExp(`(<!-- ${prefix}:${name} -->)[\\s\\S]*?(<!-- /${prefix}:${name} -->)`);
  if (!re.test(html)) throw new Error(`${file} has no ${prefix}:${name} block`);
  return html.replace(re, (_, a, b) => `${a}\n${inner}\n${b}`);
}

export function stamp(data, version, sha, day) {
  const top = data.releases[0];
  if (top.version !== version) throw new Error(`releases.json starts with ${top.version}, not ${version}; add ${version} at the top first`);
  if (!/^[0-9a-f]{64}$/.test(sha)) throw new Error('sha256 must be 64 hex characters');
  // A published version's checksum is what every installer verifies against; a rebuild must
  // never silently replace it. Bump to a new version (or restore releases.json) instead.
  if (top.sha256 && top.sha256 !== sha) throw new Error(`${version} is already recorded with sha256 ${top.sha256}; add a new version instead of rebuilding a released one`);
  top.sha256 = sha;
  top.date = day;
  validate(data);
  return data;
}
