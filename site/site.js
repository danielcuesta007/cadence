// Cadence site: staggered words in the hero demo and copy buttons.
// No network, no storage. Without this script the page still reads fully.

// The site used to be one page; links shared before 2 Nov 2026 point at its sections
// (cadence-dictation.pages.dev/#download). Send those to the page that now holds them.
const MOVED = { download: 'download.html', 'why-warning': 'download.html#why-warning', 'no-open-anyway': 'download.html#no-open-anyway',
  features: 'features.html', compare: 'features.html#compare', creator: 'about.html', faq: 'help.html' };
function movedSection(path, hash) {
  if (!/(^|\/)(index\.html)?$/.test(path)) return null;
  return MOVED[(hash || '').replace(/^#/, '')] || null;
}
if (typeof location !== 'undefined' && location.replace) {
  const target = movedSection(location.pathname, location.hash);
  if (target) location.replace(target);
}

function staggerWords(words, stepMs) {
  words.forEach((w, i) => { w.style.animationDelay = (0.6 + i * stepMs / 1000).toFixed(2) + 's'; });
}

// Every click copies the same text, so one success is enough. A failure is shown
// only when no copy has succeeded since that click began and none is still in
// flight; then the command is selected if possible so the visitor can copy it manually.
// Results are announced once through the page's status line.
const copyTurn = { n: 0 }; // shared by every copy button: who spoke last
function initCopy(button, clipboard, status, select) {
  const label = button.textContent;
  let timer, successes = 0, pending = 0;
  const show = (text, message) => {
    button.textContent = text;
    // One status line for every button; a changed string is re-announced.
    status.textContent = status.textContent === message ? message + '\u00a0' : message; // a repeat is re-announced
    const turn = ++copyTurn.n;
    clearTimeout(timer);
    timer = setTimeout(() => {
      button.textContent = label;
      if (copyTurn.n === turn) status.textContent = ''; // nobody has spoken since: clear our own message only
    }, 1600);
  };
  button.addEventListener('click', async () => {
    const before = successes;
    pending++;
    try {
      await clipboard.writeText(button.dataset.copy);
      successes++;
      show('Copied', 'Copied to clipboard');
    } catch {
      if (successes > before || pending > 1) return; // another copy landed, or still may
      const code = button.previousElementSibling;
      const selected = code && code.tagName === 'PRE' && select(code);
      show('Copy failed', selected ? 'Copy failed. The command is selected so you can copy it yourself.' : 'Copy failed. Please copy the command manually.');
    } finally { pending--; }
  });
}

if (typeof document !== 'undefined' && document.querySelectorAll) {
  staggerWords([...document.querySelectorAll('.typed .w')], 170);
  const clipboard = typeof navigator !== 'undefined' && navigator.clipboard;
  const status = document.querySelector('[data-copy-status]');
  const select = el => { try { const sel = getSelection(); sel.selectAllChildren(el); return true; } catch { return false; } };
  const silent = { textContent: '' }; // no status line: no announcement, buttons still work
  document.querySelectorAll('[data-copy]').forEach(b => clipboard ? initCopy(b, clipboard, status || silent, select) : b.remove());
}
