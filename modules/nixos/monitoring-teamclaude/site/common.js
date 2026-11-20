// Shared by the usage pages: loads data.json (written by ../ledger.py),
// buckets its hourly ledger into days / weeks / months (Dave's time zone),
// and draws small SVG bits. No external code.
"use strict";

const TZ = "Asia/Bangkok";
const PERIODS = { day: "Day", week: "Week", month: "Month" };
const COLORS = [
  "#4e79a7", "#f28e2b", "#59a14f", "#e15759", "#76b7b2", "#edc948",
  "#b07aa1", "#ff9da7", "#9c755f", "#86bcb6", "#d4a6c8", "#8cd17d",
  "#f1ce63", "#a0cbe8", "#ffbe7d", "#79706e",
];
const SPECIAL = {};

async function loadData() {
  const r = await fetch("data.json", { cache: "no-store", credentials: "same-origin" });
  if (!r.ok) throw new Error(`data.json: HTTP ${r.status}`);
  const d = await r.json();
  SPECIAL[d.outside] = "#6b6b6b";
  SPECIAL[d.unsplit] = "#3d4b5c";
  return d;
}

// Calendar parts of an epoch second in TZ.
const fmtParts = new Intl.DateTimeFormat("en-CA", {
  timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", hourCycle: "h23", weekday: "short",
});
function parts(t) {
  const o = {};
  for (const p of fmtParts.formatToParts(new Date(t * 1000))) o[p.type] = p.value;
  return o;
}
const WD = { Mon: 0, Tue: 1, Wed: 2, Thu: 3, Fri: 4, Sat: 5, Sun: 6 };

// The key and label of the period an hour falls into.
function periodOf(t, period) {
  const p = parts(t);
  if (period === "day") return { key: `${p.year}-${p.month}-${p.day}`, label: `${p.day}.${p.month}.` };
  if (period === "month") return { key: `${p.year}-${p.month}`, label: new Date(t * 1000).toLocaleString("en", { timeZone: TZ, month: "short", year: "numeric" }) };
  // Weeks start Monday 00:00 in TZ: step back to that day.
  const back = WD[p.weekday] * 86400 + Number(p.hour) * 3600;
  const m = parts(t - back);
  return { key: `W${m.year}-${m.month}-${m.day}`, label: `wk ${m.day}.${m.month}.` };
}

// Bucket the ledger. Each bucket: hours covered, used (client -> account-weeks),
// fallback, estimated hours. `accounts` = account-weeks / weeks covered: the
// average number of whole accounts busy over the bucket, so 1.0 = 100% of
// one account, and the pool's capacity is d.capacity in every period.
function buckets(d, period) {
  const out = [];
  const idx = new Map();
  const clients = Object.keys(d.used);
  for (let i = 0; i < d.hours; i++) {
    const t = d.start + i * d.step;
    const { key, label } = periodOf(t, period);
    let b = idx.get(key);
    if (!b) {
      b = { key, label, t0: t, hours: 0, used: {}, fallback: {}, estimated: 0, expiredW: 0 };
      idx.set(key, b);
      out.push(b);
    }
    b.hours++;
    if (!d.method[i]) b.estimated++;
    b.expiredW += (d.expired || [])[i] || 0;
    for (const c of clients) {
      const v = d.used[c][i];
      if (v) b.used[c] = (b.used[c] || 0) + v;
    }
    for (const c of Object.keys(d.fallback)) {
      const v = d.fallback[c][i];
      if (v) b.fallback[c] = (b.fallback[c] || 0) + v;
    }
  }
  for (const b of out) {
    const weeks = b.hours / 168;
    b.weeks = weeks;
    b.acc = {};
    for (const [c, v] of Object.entries(b.used)) b.acc[c] = v / weeks;
    b.total = Object.values(b.acc).reduce((a, x) => a + x, 0);
    b.free = Math.max(0, d.capacity - b.total);
    // Measured: quota left on accounts whose week reset inside this period
    // (whole account-weeks, not prorated).
    b.expired = b.expiredW;
    b.full = period === "day" ? b.hours === 24 : period === "week" ? b.hours === 168 : b.hours >= 28 * 24;
  }
  return out;
}

// Clients ordered by total use (biggest first), specials last.
function clientOrder(d) {
  const tot = Object.entries(d.used).map(([c, a]) => [c, a.reduce((x, y) => x + y, 0)]);
  const sp = (c) => c === d.outside || c === d.unsplit;
  tot.sort((a, b) => (sp(a[0]) - sp(b[0])) || b[1] - a[1]);
  return tot.map((x) => x[0]);
}

function colorMap(d) {
  const m = {};
  let i = 0;
  for (const c of clientOrder(d)) m[c] = SPECIAL[c] || COLORS[i++ % COLORS.length];
  return m;
}

// Labels come from the gateway's books; never let one become markup.
function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function pct(x, digits = 0) {
  if (x == null || !isFinite(x)) return "–";
  const v = x * 100;
  if (v > 0 && v < 1 && digits === 0) return "<1%";
  return `${v.toFixed(digits)}%`;
}

function el(tag, attrs = {}, ...kids) {
  const ns = ["svg", "rect", "path", "line", "text", "g", "title", "circle", "polyline"].includes(tag);
  const e = ns ? document.createElementNS("http://www.w3.org/2000/svg", tag) : document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") e.setAttribute("class", v);
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else e.setAttribute(k, v);
  }
  for (const k of kids) if (k != null) e.append(k.nodeType ? k : document.createTextNode(String(k)));
  return e;
}

// The day / week / month switch, remembered in the URL hash.
function periodSwitch(container, onChange) {
  let cur = (location.hash.match(/p=(day|week|month)/) || [])[1] || "week";
  const btns = {};
  const set = (p) => {
    cur = p;
    for (const [k, b] of Object.entries(btns)) b.setAttribute("aria-pressed", k === p);
    history.replaceState(null, "", `#p=${p}`);
    onChange(p);
  };
  for (const [k, label] of Object.entries(PERIODS)) {
    btns[k] = el("button", { type: "button", onclick: () => set(k) }, label);
    container.append(btns[k]);
  }
  set(cur);
}

function footer(d, showsFallback) {
  const gen = new Date(d.generated * 1000).toLocaleString("en-GB", { timeZone: TZ });
  const est = d.method.filter((m) => !m).length;
  return el("p", { class: "foot" },
    `Data as of ${gen} (Bangkok). 100% = one Claude Max 20x account's weekly quota; the pool holds ${d.capacity}. `,
    est ? `${est} of ${d.hours} hours predate the per-account usage history and are estimated (hatched). ` : "",
    !showsFallback && Object.keys(d.fallback).length ? "Use served outside this pool (the fallback gateway, an owner-capped account) is not shown here; see the cake page. " : "",
    el("a", { href: "./#method" }, "How this is computed"));
}

function legend(order, colors, values) {
  const ul = el("ul", { class: "legend" });
  for (const c of order) {
    if (values && !values[c]) continue;
    ul.append(el("li", {}, el("span", { class: "sw", style: `background:${colors[c]}` }), c,
      values ? el("b", {}, " ", pct(values[c], values[c] < 0.1 ? 1 : 0)) : null));
  }
  return ul;
}
