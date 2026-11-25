/**
 * The vault mask: fields a vault fill wrote never show in what this server hands out.
 *
 * Every vault script runs through this plugin's routes (./index.js). Around each one the
 * plugin lists the frame's form controls with their values (document and open shadow roots,
 * in the same isolated world as the script), runs the script, and records every control whose
 * value changed: those are the fields the vault filled (a card number, CVC, expiry, password).
 * They are kept per page (one tab of one context) with the frame they live in, a cross-origin
 * processor frame included, together with the values written (in this process's memory only,
 * for the tab's life, the last 64: the browser holds them anyway, and a document restored by
 * back/forward brings them back without a vault script).
 *
 * A capture guard (server.js registerCaptureGuard, pkgs/camofox-browser/capture-guard.patch)
 * then covers, in every screenshot and snapshot the server returns:
 *   - the filled controls, for as long as they are attached and not empty;
 *   - any control of the page, in any frame, whose value is a written value (3+ characters: a
 *     re-created CVC field too), and any element whose own text or attributes (a small
 *     element's whole text too: a number in group spans) hold a written card number (by its
 *     digits, whatever the grouping) or another written value of 8+ characters: a field the
 *     page re-created or re-grouped, a "card preview" that mirrors the number into a div, an
 *     aria-label echoing it, a field back/forward restored.
 * Screenshot (one at a time per page): the controls get `-webkit-text-security: disc` and a
 * transparent colour for the capture (mirrors the colour), the boxes of every covered element
 * are painted over in the image (./png.js) at the scale of a viewport probe, and the capture is
 * refused if, after it, an element lost the style, a box moved, or a vault script started.
 * Text (snapshot, page structure): a card number (separator-tolerant, also with its digits
 * split over lines) and every written value of 8+ characters wherever it appears, shorter ones
 * (and a selected option's text) where a line ends in them, become the mask.
 * Fail closed: a fill whose control list or diff failed taints its document, and every capture
 * of the page is refused until that document is gone; a capture while a vault script runs, an
 * element that cannot be read, a page too large to scan, or an image whose scale cannot be
 * told, refuses the capture. The route then answers 409 (capture_refused) and nothing is sent.
 *
 * Not covered (a page actively hostile to its own user, which could also read the values
 * itself): values a page draws into a canvas or an image, a value under 8 characters (a CVC,
 * a short password) mirrored as text outside a form control.
 */

import { paintRects } from './png.js';

const MASK = '••••';
const MAX_ENTRIES = 256;
const MAX_SCAN = 50000;
const MAX_VALUES = 64;
// Shorter values are matched only as a control's whole value (and at a snapshot line's end).
const MIN_EXACT = 3;
const MIN_SEARCH = 8;

// page -> [{ frame, handle } | { frame, doc, url, tainted: true }]
const filled = new WeakMap();
// page -> Set of the values the vault wrote (raw strings).
const written = new WeakMap();
// pages with a vault script running: no capture until it is recorded.
const filling = new WeakSet();
// page -> count of vault scripts started: a capture that saw it change refuses itself.
const generation = new WeakMap();

// Errors that mean the control (or its document) is gone: nothing left to mask.
const GONE = /Execution context was destroyed|Target (page, context or browser )?(has been )?closed|frame (was|got) detached|Frame was detached|JSHandle is disposed|not attached|has been closed|Cannot find context/i;
const gone = (err) => GONE.test(String(err?.message || err));

// In the isolated world: every form control of the document and its open shadow roots, with its value.
const LIST_CONTROLS = `(() => {
  "use strict";
  const out = new Map();
  const walk = (root) => {
    for (const e of root.querySelectorAll("input, textarea, select")) out.set(e, String(e.value));
    for (const e of root.querySelectorAll("*")) if (e.shadowRoot) walk(e.shadowRoot);
  };
  walk(document);
  return out;
})()`;

function entriesOf(page) {
  let list = filled.get(page);
  if (!list) {
    list = [];
    filled.set(page, list);
  }
  return list;
}

function remember(page, v) {
  let set = written.get(page);
  if (!set) written.set(page, (set = new Set()));
  set.delete(v);
  set.add(v);
  while (set.size > MAX_VALUES) set.delete(set.values().next().value);
}

// One screenshot at a time per page: two overlapping ones would save each other's mask as the style.
const queues = new WeakMap();
function serial(page, fn) {
  const run = (queues.get(page) || Promise.resolve()).then(fn, fn);
  queues.set(page, run.catch(() => {}));
  return run;
}

const cardDigits = (v) => {
  const d = String(v).replace(/[\s-]/g, '');
  return /^\d{12,19}$/.test(d) ? d : null;
};

async function taint(page, frame) {
  // The document handle tells this document from the next one the frame loads.
  const doc = await frame.evaluateHandle('document').catch(() => null);
  entriesOf(page).push({ frame, doc, url: frame.url(), tainted: true });
}

/**
 * Run `run()` (a vault script in `frame` of `page`) and record the controls it changed. The
 * listing before it must succeed or the script does not run; a failure after it taints the
 * frame's document. No capture of the page is served while it runs.
 */
export async function trackFill(page, frame, run) {
  const before = await frame.evaluateHandle(LIST_CONTROLS);
  filling.add(page);
  generation.set(page, (generation.get(page) || 0) + 1);
  try {
    let result;
    try {
      result = await run();
    } catch (err) {
      // A script that threw may still have written: record what changed, else count the document as filled.
      await recordChanged(page, frame, before).catch(() => taint(page, frame));
      throw err;
    }
    try {
      await recordChanged(page, frame, before);
    } catch {
      await taint(page, frame);
    }
    return result;
  } finally {
    filling.delete(page);
  }
}

async function recordChanged(page, frame, before) {
  try {
    const changed = await frame.evaluateHandle((b) => {
      const now = [];
      const walk = (root) => {
        for (const e of root.querySelectorAll('input, textarea, select')) {
          if (!b.has(e) ? String(e.value) !== '' : b.get(e) !== String(e.value)) now.push(e);
        }
        for (const e of root.querySelectorAll('*')) if (e.shadowRoot) walk(e.shadowRoot);
      };
      walk(document);
      return now;
    }, before);
    const props = await changed.getProperties();
    const list = entriesOf(page);
    for (const [, value] of props) {
      const handle = value.asElement();
      if (!handle) continue;
      list.push({ frame, handle });
      // A select's value and the text of its chosen option (what the snapshot prints).
      const [v, shown] = await handle.evaluate((e) => [String(e.value),
        e.tagName === 'SELECT' && e.selectedOptions[0] ? String(e.selectedOptions[0].textContent).trim() : '']);
      if (v) remember(page, v);
      if (shown) remember(page, shown);
    }
    await changed.dispose().catch(() => {});
    if (list.length > MAX_ENTRIES) await prune(page);
    if (list.length > MAX_ENTRIES) throw new Error('too many filled controls on one page');
  } finally {
    await before.dispose().catch(() => {});
  }
}

// Drops the entries whose control or document is gone; throws when one cannot be checked.
async function prune(page) {
  const list = filled.get(page);
  if (!list || !list.length) return [];
  const alive = [];
  for (const entry of list) {
    if (entry.frame.isDetached()) continue;
    try {
      if (entry.tainted) {
        if (entry.doc ? await entry.doc.evaluate((d) => d === document) : entry.frame.url() === entry.url) alive.push(entry);
        continue;
      }
      // Kept while attached, empty too: a re-render may clear and restore it.
      if (await entry.handle.evaluate((e) => e.isConnected)) alive.push(entry);
    } catch (err) {
      if (gone(err)) continue;
      throw err;
    }
  }
  filled.set(page, alive);
  return alive;
}

// The elements anywhere on the page (every frame, open shadow roots) whose own text, attributes or
// value hold a written value, beyond the controls the vault wrote. Throws when a frame cannot be read.
async function matches(page) {
  const values = written.get(page);
  if (!values || !values.size) return [];
  const cards = [...new Set([...values].map(cardDigits).filter(Boolean))];
  const texts = [...values].filter((v) => !cardDigits(v) && v.trim().length >= MIN_SEARCH).map((v) => v.trim().toLowerCase());
  const exact = [...values].map((v) => v.trim()).filter((v) => v.length >= MIN_EXACT);
  if (!cards.length && !texts.length && !exact.length) return [];
  const out = [];
  for (const frame of page.frames()) {
    if (frame.isDetached()) continue;
    let list;
    try {
      list = await frame.evaluateHandle(([cardList, textList, exactList, max]) => {
        const now = [];
        let seen = 0;
        const hit = (s) => {
          if (!s) return false;
          const d = s.replace(/\D/g, '');
          if (d.length >= 12 && cardList.some((c) => d.includes(c))) return true;
          const l = s.toLowerCase();
          return textList.some((t) => l.includes(t));
        };
        const walk = (root) => {
          for (const e of root.querySelectorAll('*')) {
            if (++seen > max) throw new Error('page too large to scan for filled values');
            let own = '';
            for (const n of e.childNodes) if (n.nodeType === 3) own += n.data;
            const control = e.tagName === 'INPUT' || e.tagName === 'TEXTAREA';
            // The whole text of a small element too: a number split into group spans (<span>4242</span>...).
            // Only the smallest such element: not a wrapper whose child already holds it.
            const all = own.length < 160 && e.childElementCount ? e.textContent || '' : '';
            let found = hit(own) || (all.length <= 160 && hit(all) && ![...e.children].some((c) => hit(c.textContent || '')))
              || (control && (hit(String(e.value)) || exactList.includes(String(e.value).trim())));
            for (let i = 0; !found && i < e.attributes.length; i++) found = hit(e.attributes[i].value);
            if (found) now.push(e);
            if (e.shadowRoot) walk(e.shadowRoot);
          }
        };
        walk(document);
        return now;
      }, [cards, texts, exact, MAX_SCAN]);
    } catch (err) {
      if (gone(err)) continue;
      throw err;
    }
    for (const [, value] of await list.getProperties()) {
      const handle = value.asElement();
      if (handle) out.push({ frame, handle, mirror: true });
    }
    await list.dispose().catch(() => {});
  }
  return out;
}

async function tracked(page) {
  if (filling.has(page)) throw new Error('a vault fill is running on this page; try again in a moment');
  const alive = await prune(page);
  if (alive.some((e) => e.tainted)) {
    throw new Error('a vault fill on this page could not be tracked, so no capture is sent until the page navigates');
  }
  return alive;
}

async function boxes(alive) {
  const out = [];
  // null: not rendered (display: none, or no layout box), nothing to paint.
  for (const { handle } of alive) out.push(await handle.boundingBox());
  return out;
}

const STYLE = [['-webkit-text-security', 'disc'], ['color', 'transparent'], ['-webkit-text-fill-color', 'transparent'],
  ['text-shadow', 'none'], ['caret-color', 'transparent']];

async function styleOn(controls) {
  for (const { handle } of controls) {
    await handle.evaluate((e, style) => {
      // Listed twice (filled twice, or filled and found again): masked once, restored once.
      if (e.hasAttribute('data-hermes-vault-mask')) return;
      const saved = style.map(([k]) => [k, e.style.getPropertyValue(k), e.style.getPropertyPriority(k)]);
      e.setAttribute('data-hermes-vault-mask', JSON.stringify(saved));
      for (const [k, v] of style) e.style.setProperty(k, v, 'important');
    }, STYLE);
  }
}

// After the capture: did every element keep the style? (A page could strip it in between.) Form
// controls must show discs, every element transparent text.
async function styleHeld(controls) {
  for (const { handle, mirror } of controls) {
    const ok = await handle.evaluate((e, mirrored) => {
      const c = getComputedStyle(e);
      const clear = (v) => v === 'transparent' || /^rgba\(.*,\s*0\)$/.test(v);
      const field = !mirrored || e.tagName === 'INPUT' || e.tagName === 'TEXTAREA';
      return e.hasAttribute('data-hermes-vault-mask') && clear(c.color)
        && clear(c.getPropertyValue('-webkit-text-fill-color') || 'transparent')
        && (!field || (c.webkitTextSecurity || c.getPropertyValue('-webkit-text-security')) === 'disc');
    }, !!mirror);
    if (!ok) throw new Error('a filled field lost its mask during the capture');
  }
}

async function styleOff(controls) {
  for (const { handle } of controls) {
    await handle.evaluate((e) => {
      const raw = e.getAttribute('data-hermes-vault-mask');
      e.removeAttribute('data-hermes-vault-mask');
      if (!raw) return;
      for (const [k, v, p] of JSON.parse(raw)) {
        if (v) e.style.setProperty(k, v, p); else e.style.removeProperty(k);
      }
    }).catch(() => {});
  }
}

const same = (a, b) => (!a && !b) || (a && b && ['x', 'y', 'width', 'height'].every((k) => Math.abs(a[k] - b[k]) <= 1));

// The viewport in CSS px (less scrollbars), measured with a fixed probe the isolated world adds
// and removes in one go: the page's CSS cannot size it (inline !important), as it can size the
// root's box (html { max-width }). A root that is transformed, zoomed or contains its fixed
// children would move the probe with it: refused.
const VIEWPORT = `(() => {
  "use strict";
  const r = document.documentElement;
  const c = getComputedStyle(r);
  const plain = (v) => !v || ['none', 'normal', 'auto', '1'].includes(String(v).trim());
  const bad = !['transform', 'translate', 'scale', 'rotate', 'filter', 'backdrop-filter', 'perspective',
    'contain', 'container-type', 'zoom'].every((k) => plain(c.getPropertyValue(k)))
    || /transform|translate|scale|rotate|filter|perspective|contain/.test(c.getPropertyValue('will-change'));
  const d = document.createElement('div');
  d.style.cssText = 'all: initial !important; position: fixed !important; left: 0 !important; top: 0 !important; '
    + 'right: 0 !important; bottom: 0 !important; visibility: hidden !important; pointer-events: none !important';
  r.appendChild(d);
  const b = d.getBoundingClientRect();
  d.remove();
  return [b.left, b.top, b.width, b.height, bad, r.scrollWidth];
})()`;

async function cssScale(page, options, buf) {
  const [w, h] = buf.length > 24 ? [buf.readUInt32BE(16), buf.readUInt32BE(20)] : [0, 0];
  if (options?.clip) return w / options.clip.width;
  const [left, top, vw, vh, bad, scrollWidth] = await page.mainFrame().evaluate(VIEWPORT);
  if (bad) throw new Error('the page\'s root is transformed or zoomed: the screenshot\'s scale cannot be told');
  if (Math.abs(left) > 1 || Math.abs(top) > 1 || !(vw > 0) || !(vh > 0)) throw new Error('the page has no viewport to measure');
  if (options?.fullPage) return w / Math.max(vw, Number(scrollWidth) || 0);
  // Both ways the same scale, give or take the scrollbars the probe leaves out and the image shows.
  const sx = w / vw;
  const sy = h / vh;
  if (!(Math.abs(sx - sy) <= 0.05 * Math.min(sx, sy))) throw new Error('the screenshot\'s scale cannot be told');
  return sx;
}

function screenshot(page, options, take) {
  return serial(page, () => maskedScreenshot(page, options, take));
}

async function maskedScreenshot(page, options, take) {
  const gen = generation.get(page) || 0;
  const buf = await maskedTake(page, options, take);
  // A vault script that started meanwhile (the screenshot route holds no tab lock) may have written
  // into the image.
  if (filling.has(page) || (generation.get(page) || 0) !== gen) throw new Error('a vault fill ran during the capture; try again');
  return buf;
}

async function maskedTake(page, options, take) {
  const alive = (await tracked(page)).concat(await matches(page));
  if (!alive.length) return take(options);
  if (options && options.type && options.type !== 'png') throw new Error('only PNG screenshots can be masked');
  if (options?.clip && options?.fullPage) throw new Error('a clipped full-page screenshot cannot be masked');
  // Mirrors (a card preview, the number in group spans) get the colour mask too: hidden whatever
  // the painting below hits.
  const controls = alive;
  let buf;
  let first;
  let second;
  try {
    await styleOn(controls);
    first = await boxes(alive);
    buf = await take({ ...options, type: 'png' });
    second = await boxes(alive);
    await styleHeld(controls);
  } finally {
    await styleOff(controls);
  }
  if (first.some((b, i) => !same(b, second[i]))) throw new Error('a filled field moved during the capture');
  // Boxes are the layout's CSS pixels of the viewport; the image may be device pixels, a full page or
  // a clip. The scale is read off the image against the viewport (Camoufox spoofs devicePixelRatio
  // and innerWidth to the page's scripts; Playwright's boxes are the real layout's).
  // (Camoufox's fingerprint picks a device scale like 1.0345: no snapping.) A scrollbar the probe
  // leaves out but the image shows makes it at most a few percent too big: the padding below grows
  // with x and y to cover that.
  const scale = await cssScale(page, options, buf);
  if (!Number.isFinite(scale) || scale < 0.5 || scale > 5) throw new Error('the screenshot\'s scale cannot be told');
  const scroll = options?.fullPage ? await page.evaluate('[window.scrollX, window.scrollY]') : [0, 0];
  const dx = (Number(scroll[0]) || 0) - (options?.clip?.x || 0);
  const dy = (Number(scroll[1]) || 0) - (options?.clip?.y || 0);
  // A margin covers anti-aliasing and the focus ring, and in both directions the scale's possible
  // error (the x scale serves y too).
  const pad = 2;
  return paintRects(buf, first.filter(Boolean).map((r) => {
    const slack = pad + 0.03 * (r.x + r.width + dx);
    const vslack = pad + 0.03 * (r.y + r.height + dy);
    return {
      x: (r.x + dx - slack) * scale, y: (r.y + dy - vslack) * scale,
      width: (r.width + 2 * slack) * scale, height: (r.height + 2 * vslack) * scale,
    };
  }));
}

const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// A card number whose digits follow one another in the text, whatever lies between them (a
// number split over lines, `- text: 4242` per group span; bracket tokens like [e12] or [level=2]
// and /url: lines left out): masked digit by digit.
function maskSplitCard(text, card) {
  const pos = [];
  const refs = /\[[a-z][a-z0-9-]*(?:=[^\]\n]{0,20})?\]|\/url: [^\n]*/g;
  let skip = refs.exec(text);
  for (let i = 0; i < text.length; i++) {
    while (skip && i >= skip.index + skip[0].length) skip = refs.exec(text);
    if (skip && i >= skip.index) continue;
    const ch = text.charCodeAt(i);
    if (ch >= 48 && ch <= 57) pos.push(i);
  }
  const ds = pos.map((i) => text[i]).join('');
  const chars = text.split(''); // UTF-16 units, as the indices above
  let found = false;
  for (let at = ds.indexOf(card); at !== -1; at = ds.indexOf(card, at + card.length)) {
    found = true;
    for (let k = at; k < at + card.length; k++) chars[pos[k]] = '•';
  }
  return found ? chars.join('') : text;
}

async function text(page, input) {
  // Mirrors in text are found by the values themselves; no element scan.
  const alive = await tracked(page);
  const values = new Set(written.get(page) || []);
  if (!alive.length && !values.size) return input;
  for (const { handle } of alive) {
    const v = await handle.evaluate((e) => String(e.value));
    if (v) values.add(v);
  }
  let out = input;
  for (const v of [...values].sort((a, b) => b.length - a.length)) {
    const e = escape(v);
    // A snapshot line ends in the control's value (`- textbox "Card number": 4242 ...`), the page
    // structure has it as "value"; YAML quotes a value that would read as a number (`: "123"`).
    out = out.replace(new RegExp(`(: )(?:${e}|${escape(JSON.stringify(v))})$`, 'gm'), `$1${MASK}`)
      .replace(new RegExp(`("value":)${escape(JSON.stringify(v))}`, 'g'), `$1${JSON.stringify(MASK)}`);
    const card = cardDigits(v);
    if (card) {
      // Wherever it appears, whatever the grouping.
      out = maskSplitCard(out.replace(new RegExp(card.split('').join('[\\s-]*'), 'g'), MASK), card);
    } else if (v.trim().length >= MIN_SEARCH) {
      out = out.split(v).join(MASK);
    }
  }
  return out;
}

export const guard = { screenshot, text };
