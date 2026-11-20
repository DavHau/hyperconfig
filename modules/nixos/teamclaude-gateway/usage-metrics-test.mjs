// Test for usage-metrics.mjs against TeamClaude's own usage store: records
// requests with its recordRequest, then checks the exported counters.
// argv: <teamclaude src dir> <usage-metrics.mjs> <scratch dir>
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const [srcDir, script, tmp] = process.argv.slice(2);
const { openUsageStore, closeUsageStore } = await import(pathToFileURL(join(srcDir, 'usage/db.js')).href);
const { recordRequest } = await import(pathToFileURL(join(srcDir, 'usage/record.js')).href);
const { accumulate, render, rowCost } = await import(pathToFileURL(script).href);

const H = 3_600_000;
let now = 100 * H + 10;
const dbPath = join(tmp, 'teamclaude.usage.db');
const store = openUsageStore({ path: dbPath, now: () => now });
assert.equal(store.disabled, false, `store: ${store.reason}`);
recordRequest(store, { caller: 'alice', account: 'a@x', model: 'claude-opus-5-5', input: 1000, cacheRead: 1_000_000, output: 1_000_000, status: 200 });
now = 101 * H + 5;
recordRequest(store, { caller: 'bob', account: 'a@x', model: 'claude-opus-5-9', output: 1_000_000, status: 200 });
closeUsageStore(store);

const rows = () => {
  const db = new DatabaseSync(dbPath, { readOnly: true });
  const r = db.prepare(`SELECT c.label AS caller, m.label AS model, a.label AS account, h.hour,
      h.input, h.cache_read, h.cache_write, h.output
    FROM usage_hourly h JOIN dim c ON c.id = h.caller_id JOIN dim m ON m.id = h.model_id
    JOIN dim a ON a.id = h.account_id`).all();
  db.close();
  return r;
};

// Opus 5.5: 1000 in * $4 + 1M cache reads * $0.2 + 1M out * $20, per 1M.
assert.equal(rowCost('claude-opus-5-5', { input: 1000, cache_read: 1e6, cache_write: 0, output: 1e6 }).usd.toFixed(6), '20.204000');
// A model missing from the table is priced as its family, and flagged.
const fam = rowCost('claude-opus-5-9', { input: 0, cache_read: 0, cache_write: 0, output: 1e6 });
assert.equal(fam.usd, 20);
assert.equal(fam.byFamily, true);

// At 101h nothing is folded yet (the last hour stays open for an hour); at
// 102h hour 100 is folded into the totals, hour 101 stays open.
const s0 = { version: 2, closedBefore: 0, totals: {} };
const a0 = accumulate(s0, rows(), 101 * H + 60_000);
assert.equal(a0.state.closedBefore, 100);
assert.deepEqual(a0.state.totals, {});
const a = accumulate(a0.state, rows(), 102 * H + 60_000);
assert.equal(a.state.closedBefore, 101);
assert.deepEqual(Object.keys(a.state.totals), [JSON.stringify(['alice', 'a@x'])]);
assert.deepEqual(a.counters, a0.counters);
assert.equal(a.counters[JSON.stringify(['bob', 'a@x'])].usd, 20e6);
// Next run: the closed hour is not added again, the counters do not move,
// and they stay monotonic once hour 100 is pruned from the database.
const b = accumulate(a.state, rows().filter(r => r.hour !== 100), 102 * H + 120_000);
assert.deepEqual(b.counters, a.counters);
const c = accumulate(b.state, rows(), 103 * H + 1);
assert.equal(c.state.closedBefore, 102);
assert.deepEqual(c.counters, a.counters);

// Folding never makes the cost counter dip: two hours of rows across
// models, read while the second is open and again once it is folded, must
// render the same cost (float sums in a different order did dip).
const usdOf = r => Number(render(r.counters).match(/^teamclaude_client_cost_usd_total\{[^}]*\} (\S+)$/m)[1]);
const MODELS = ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-fable-5-1'];
for (let seed = 0; seed < 300; seed++) {
  let x = seed * 7919 + 1;
  const rnd = (m) => Math.floor(((x = (x * 48271) % 2147483647) / 2147483647) * m);
  const rows = [];
  for (const [hour, k] of [[400, 6], [500, 4]]) {
    for (let i = 0; i < k; i++) rows.push({ caller: 'z', account: 'a@x', model: MODELS[(i + hour) % 4], hour,
      input: rnd(1e5), cache_read: rnd(1e6), cache_write: rnd(1e5), output: rnd(1e4) });
  }
  const s1 = accumulate({ version: 2, closedBefore: 0, totals: {} }, rows, 450 * H).state;
  const open = accumulate(s1, rows, 501 * H);
  const folded = accumulate(open.state, rows, 502 * H);
  assert.equal(usdOf(folded), usdOf(open), `seed ${seed}`);
}

const text = render(c.counters);
assert.match(text, /^teamclaude_client_cost_usd_total\{client="alice",account="a@x"\} 20\.204$/m);
assert.match(text, /^teamclaude_client_tokens_total\{client="alice",account="a@x",kind="cache_read"\} 1000000$/m);
assert.match(text, /^teamclaude_client_unpriced_tokens_total\{client="bob",account="a@x"\} 1000000$/m);
// Label values are escaped.
assert.match(render({ [JSON.stringify(['a"b\\c', 'x'])]: { usd: 1e6, unpriced: 0, input: 0, cache_read: 0, cache_write: 0, output: 0 } }), /client="a\\"b\\\\c"/);
console.log('usage-metrics: ok');
