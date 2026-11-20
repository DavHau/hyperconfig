// Per client and account: the API-list-price cost and the tokens by kind
// that TeamClaude's usage history (proxy.usageHistory, teamclaude.usage.db)
// booked, as Prometheus counters on stdout. ./metrics.nix runs it as the
// teamclaude user, so the database (0600 teamclaude, WAL) is only ever
// opened by its owner and read-only.
//
// The history's rollup (usage_hourly) is pruned after 400 days, so a plain
// SUM over it would fall one day and read as a counter reset. Instead the
// closed hours are folded into a running total kept in <state>: every run
// adds the hours before the current one that it has not added yet, and the
// counter is that total plus the still-open hours. Hours never change once
// closed (a request is booked when it ends, stamped just before its
// transaction commits, so an hour is folded only once the next one has also
// passed). Losing the state file restarts the counters, which increase()
// reads as a reset. Cost is summed in whole micro-dollars: float sums in a
// different order (open hours vs folded totals) would differ in the last
// bit and make the counter dip, which a reader takes for a reset.
//
// argv: <teamclaude src dir> <usage db> <state file>
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const [srcDir, dbPath, statePath] = process.argv.slice(2);
const { priceUsage } = await import(pathToFileURL(join(srcDir, 'anthropic-pricing.js')).href);

const HOUR_MS = 3_600_000;
const KINDS = ['input', 'cache_read', 'cache_write', 'output'];

// A model the price table lacks (a new snapshot name) is priced as its
// family's current model, rather than as free; the counter
// teamclaude_client_unpriced_tokens_total says how much that was.
const FAMILY = [
  ['fable', 'claude-fable-5-1'],
  ['mythos', 'claude-mythos-5-1'],
  ['opus', 'claude-opus-5-5'],
  ['sonnet', 'claude-sonnet-5-5'],
  ['haiku', 'claude-haiku-5-5'],
];

/** cost in USD and whether it was priced by family, for one rollup row. */
export function rowCost(model, row) {
  const usage = {
    input_tokens: row.input,
    output_tokens: row.output,
    cache_read_input_tokens: row.cache_read,
    // The rollup keeps no 5m/1h split; TeamClaude prices an unsplit write
    // at the 5-minute rate, the default TTL.
    cache_creation_input_tokens: row.cache_write,
  };
  let p = priceUsage(model, usage);
  let byFamily = false;
  if (!p.ok) {
    const m = String(model || '').toLowerCase();
    const fam = FAMILY.find(([k]) => m.includes(k));
    if (fam) {
      p = priceUsage(fam[1], usage);
      byFamily = true;
    }
  }
  return { usd: p.ok ? p.costMinor / 100 : 0, byFamily, priced: p.ok };
}

function esc(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, ' ');
}

function load(path) {
  try {
    const s = JSON.parse(readFileSync(path, 'utf8'));
    if (s && s.version === 2 && Number.isInteger(s.closedBefore) && s.totals) return s;
  } catch { /* missing or unreadable: start over */ }
  return { version: 2, closedBefore: 0, totals: {} };
}

/**
 * Fold rows into the state and return the counters. Pure, for the test.
 * rows: { caller, model, account, hour, input, cache_read, cache_write, output }[]
 */
export function accumulate(state, rows, nowMs) {
  // Hours before this one are folded; the last one stays open for an hour.
  const closeTo = Math.floor(nowMs / HOUR_MS) - 1;
  const totals = structuredClone(state.totals);
  const open = {};
  const add = (into, r) => {
    const key = JSON.stringify([r.caller, r.account]);
    const t = into[key] || (into[key] = { usd: 0, unpriced: 0, input: 0, cache_read: 0, cache_write: 0, output: 0 });
    const c = rowCost(r.model, r);
    t.usd += Math.round(c.usd * 1e6);
    if (!c.priced || c.byFamily) t.unpriced += r.input + r.cache_read + r.cache_write + r.output;
    for (const k of KINDS) t[k] += r[k];
  };
  for (const r of rows) {
    if (r.hour < state.closedBefore) continue;
    add(r.hour < closeTo ? totals : open, r);
  }
  const counters = structuredClone(totals);
  for (const [key, t] of Object.entries(open)) {
    const c = counters[key] || (counters[key] = { usd: 0, unpriced: 0, input: 0, cache_read: 0, cache_write: 0, output: 0 });
    for (const k of Object.keys(t)) c[k] += t[k];
  }
  return { state: { version: 2, closedBefore: Math.max(state.closedBefore, closeTo), totals }, counters };
}

export function render(counters) {
  const lines = [];
  // usd is in micro-dollars here.
  const fam = (name, help, type, fn) => {
    lines.push(`# HELP ${name} ${help}`, `# TYPE ${name} ${type}`);
    for (const [key, t] of Object.entries(counters)) {
      const [client, account] = JSON.parse(key);
      fn(t).forEach(([extra, v]) => lines.push(`${name}{client="${esc(client)}",account="${esc(account)}"${extra}} ${v}`));
    }
  };
  fam('teamclaude_client_cost_usd_total', 'API list price of what the client used on the account (TeamClaude usage history)', 'counter', t => [['', t.usd / 1e6]]);
  fam('teamclaude_client_tokens_total', 'Tokens the client used on the account, by kind', 'counter', t => KINDS.map(k => [`,kind="${k}"`, t[k]]));
  fam('teamclaude_client_unpriced_tokens_total', 'Tokens priced by model family because the price table lacks the model', 'counter', t => [['', t.unpriced]]);
  return lines.join('\n') + '\n';
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (!existsSync(dbPath)) process.exit(0);
  const db = new DatabaseSync(dbPath, { readOnly: true });
  const state = load(statePath);
  const rows = db.prepare(`SELECT c.label AS caller, m.label AS model, a.label AS account, h.hour,
      h.input, h.cache_read, h.cache_write, h.output
    FROM usage_hourly h
    JOIN dim c ON c.id = h.caller_id
    JOIN dim m ON m.id = h.model_id
    JOIN dim a ON a.id = h.account_id
    WHERE h.hour >= ?`).all(state.closedBefore);
  db.close();
  const { state: next, counters } = accumulate(state, rows, Date.now());
  process.stdout.write(render(counters));
  writeFileSync(statePath + '.tmp', JSON.stringify(next), { mode: 0o600 });
  renameSync(statePath + '.tmp', statePath);
}
