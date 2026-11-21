import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { accountStatus, commitRecovery, replaceCredentials, requireLocalCredentials, targetAccount } from './oauth-relogin.mjs';

const [upstreamSrc, scratch] = process.argv.slice(2);
const upstream = file => import(pathToFileURL(join(upstreamSrc, file)).href);
const exporter = fileURLToPath(new URL('./oauth-status.mjs', import.meta.url));
const tool = fileURLToPath(new URL('./oauth-relogin.mjs', import.meta.url));
const fakeKey = 'fixture-operator-key-should-not-export';
const now = 1795250000000;
const base = { type: 'oauth', provider: 'anthropic', status: 'active', disabled: false };
const row = (name, fields) => ({ ...base, name, ...fields });
const metric = (name, k, val) => `teamclaude_account_oauth_${k}{account="${name}"} ${val}`;
const expiry = (name, val) => metric(name, 'refresh_expiry_timestamp_seconds', val);
const rejected = (name, val) => metric(name, 'relogin_required', val);
const cli = (script, args = [], env = process.env) => new Promise((resolve, reject) => {
  const child = spawn(process.execPath, [script, ...args], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '', err = '';
  child.stdout.on('data', data => { out += data; });
  child.stderr.on('data', data => { err += data; });
  child.on('error', reject);
  child.on('close', code => resolve({ code, out, err }));
});
const accountLines = text => text.split('\n').filter(line => line.startsWith('teamclaude_account_')).sort();

// Real authenticated loopback HTTP and CLI, with old/new server-shaped JSON.
async function withStatus(fn) {
  const dir = await mkdtemp(join(scratch, 'oauth-status-'));
  const config = join(dir, 'teamclaude.json');
  let response;
  const requests = [];
  const server = createServer((req, res) => {
    requests.push([req.method, req.url, req.headers['x-api-key'] === fakeKey]);
    if (req.url !== '/teamclaude/status' || req.headers['x-api-key'] !== fakeKey) {
      res.writeHead(401).end('unauthorized');
      return;
    }
    if (response === 'redirect') {
      res.writeHead(302, { location: '/not-status' }).end();
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(response));
  });
  try {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    await writeFile(config, JSON.stringify({ proxy: { port: server.address().port, apiKey: fakeKey } }), { mode: 0o600 });
    await fn(config, value => { response = value; }, requests);
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
  }
}

await test('old status: unknown expiry is not manufactured; explicit rejection still works', async () => {
  await withStatus(async (config, reply, requests) => {
    reply({ accounts: [row('unknown@example.test'), row('legacy-rejected@example.test', {
      status: 'error', errorReason: { code: 'refresh_rejected', detail: 'fixture-sensitive-detail' },
    })] });
    const { code, out, err } = await cli(exporter, [config]);
    assert.equal(code, 0);
    assert.equal(err, '');
    assert.match(out, /teamclaude_oauth_status_collected_timestamp_seconds [0-9]+/);
    assert.deepEqual(accountLines(out), [rejected('legacy-rejected@example.test', 1), rejected('unknown@example.test', 0)]);
    assert.doesNotMatch(out, /fixture-sensitive-detail|fixture-operator-key/);
    assert.deepEqual(requests, [['GET', '/teamclaude/status', true]]);
  });
});

await test('new status: exact dates and confirmed rejections only; safe recovery readback', async () => {
  await withStatus(async (config, reply) => {
    const name = 'expiry@example.test';
    const lastProbedAt = new Date(now - 120000).toISOString();
    const probeStartedAt = new Date(now - 121000).toISOString();
    const weeklyReset = now + 7 * 86400000;
    reply({ accounts: [
      row(name, { refreshTokenExpiresAt: now + 12345, quota: { unified7d: 0, unified7dReset: weeklyReset } }),
      row('rejected@example.test', { status: 'error', errorReason: { code: 'credential_rejected' }, refreshTokenExpiresAt: now - 1200 }),
      row('transient@example.test', { status: 'cooldown', errorReason: { code: 'refresh_rejected' }, refreshTokenExpiresAt: '1795250000000' }),
      row('generic@example.test', { status: 'error', refreshTokenExpiresAt: 0 }),
      row('hold@example.test', { status: 'error', errorReason: { code: 'account_on_hold', detail: 'fixture-provider-error' } }),
      row('disabled@example.test', { disabled: true, refreshTokenExpiresAt: now }),
      row('codex@example.test', { provider: 'codex', refreshTokenExpiresAt: now }),
      row('long-lived@example.test', { longLived: true, refreshTokenExpiresAt: now }),
      row('fallback', { type: 'apikey', refreshTokenExpiresAt: now }),
      row('duplicate'), row('duplicate'), row('label\\"@example.test'),
    ], probe: { accounts: [
      { name, lastProbedAt, startedAt: probeStartedAt, status: 'ok', weekly: { utilization: 0, resetAt: weeklyReset } },
      { name: 'generic@example.test', status: 'error', error: 'HTTP 401 fixture-provider-error' },
      { name: 'rejected@example.test', status: 'error', lastProbedAt: new Date(now - 86400000).toISOString() },
    ] } });
    const { code, out, err } = await cli(exporter, [config]);
    assert.equal(code, 0);
    assert.equal(err, '');
    assert.deepEqual(accountLines(out), [
      expiry(name, 1795250012), expiry('rejected@example.test', 1795249998),
      rejected(name, 0), rejected('rejected@example.test', 1), rejected('transient@example.test', 0),
      rejected('generic@example.test', 0), rejected('hold@example.test', 0), rejected('label\\\\\\"@example.test', 0),
    ].sort());
    assert.doesNotMatch(out, /fixture-provider-error/);
    assert.deepEqual(await accountStatus(name, config), {
      account: name, disabled: false, status: 'active', reloginRequired: false,
      refreshDeadline: new Date(now + 12345).toISOString(), quotaProbe: 'ok',
      probeStartedAt, lastProbedAt, weeklyUtilization: 0, weeklyReset: new Date(weeklyReset).toISOString(),
    });
    const stopped = await cli(tool, [upstreamSrc, '/no-systemctl-in-fixtures', '/no-tty-in-fixtures', 're-login', name], { ...process.env, TEAMCLAUDE_CONFIG: config });
    assert.deepEqual(stopped, { code: 1, out: '', err: 'teamclaude-oauth: Use an interactive, unrecorded terminal for re-login.\n' });
  });
});

await test('a fresh probe without both weekly fields cannot borrow cached quota', async () => {
  await withStatus(async (config, reply) => {
    const name = 'owner@example.test';
    const weeklyReset = now + 86400000;
    for (const weekly of [undefined, {}, { utilization: 0 }, { resetAt: weeklyReset },
      { utilization: -1, resetAt: weeklyReset }, { utilization: 0, resetAt: null }]) {
      reply({ accounts: [row(name, { quota: { unified7d: 0.8, unified7dReset: weeklyReset } })],
        probe: { accounts: [{ name, status: 'ok', startedAt: new Date(now - 1).toISOString(),
          lastProbedAt: new Date(now).toISOString(), weekly }] } });
      const status = await accountStatus(name, config);
      assert.equal(status.weeklyUtilization, null);
      assert.equal(status.weeklyReset, null);
    }
  });
});

await test('the packaged prober reports only the current normalized weekly observation', async () => {
  const { AccountManager } = await upstream('account-manager.js');
  const { Prober } = await upstream('prober.js');
  const { normalizeUsageBucket } = await upstream('oauth.js');
  const name = 'owner@example.test';
  const weeklyReset = Date.now() + 86400000;
  const am = new AccountManager([row(name, { id: 'owner', accessToken: 'fixture-access', expiresAt: weeklyReset })]);
  let payload;
  const prober = new Prober(am, { probeFn: async () => ({ sevenDay: normalizeUsageBucket(payload) }), timeoutMs: 50 });
  await withStatus(async (config, reply) => {
    const observe = async next => {
      payload = next;
      await prober.probeAccount(am.accounts[0]);
      reply({ accounts: [row(name, { quota: am.accounts[0].quota })], probe: prober.getStatus() });
      const status = await accountStatus(name, config);
      assert.equal(status.quotaProbe, 'ok');
      return [status.weeklyUtilization, status.weeklyReset];
    };
    const resets_at = new Date(weeklyReset).toISOString();
    assert.deepEqual(await observe({ utilization: 50, resets_at }), [0.5, resets_at]);
    assert.deepEqual(await observe({}), [null, null]);
    assert.equal(am.accounts[0].quota.unified7d, 0.5);
    assert.deepEqual(await observe({ utilization: 0 }), [null, null]);
    assert.equal(am.accounts[0].quota.unified7dReset, weeklyReset);
    assert.deepEqual(await observe({ resets_at }), [null, null]);
    assert.deepEqual(await observe({ utilization: 0, resets_at }), [0, resets_at]);
  });
});

await test('broken schema, redirect and authentication fail closed without output', async () => {
  await withStatus(async (config, reply, requests) => {
    for (const body of [{ accounts: [{ name: 'wrong' }] }, { wrong: [] }, 'redirect']) {
      reply(body);
      const { code, out, err } = await cli(exporter, [config]);
      assert.equal(code, 1);
      assert.equal(out, '');
      assert.equal(err, 'teamclaude-metrics: could not collect authenticated OAuth status\n');
    }
    const settings = JSON.parse(await readFile(config, 'utf8'));
    settings.proxy.apiKey = 'wrong-fixture-key';
    await writeFile(config, JSON.stringify(settings));
    assert.equal((await cli(exporter, [config])).code, 1);
    assert.deepEqual(requests, Array.from({ length: 3 }, () => ['GET', '/teamclaude/status', true]).concat([['GET', '/teamclaude/status', false]]));
  });
});

await test('recovery refuses wrong identity, busy lock, unconfirmed stop or stale credential snapshot', async () => {
  const directory = await mkdtemp(join(scratch, 'oauth-relogin-'));
  const path = join(directory, 'teamclaude.json');
  const name = 'owner@example.test';
  const baseline = {
    upstream: 'https://api.anthropic.com', proxy: { port: 3456 }, accounts: [
      { id: 'test-id', name, type: 'oauth', accountUuid: 'test-owner', orgUuid: 'test-org',
        accessToken: 'fixture-old-access', refreshToken: 'fixture-old-refresh', expiresAt: now - 5000,
        refreshTokenExpiresAt: now - 1000, maxUsage: { unified7d: 0.8 }, priority: 2 },
      { id: 'other-id', name: 'fallback', type: 'apikey', apiKey: 'fixture-fallback', priority: 10 },
    ],
  };
  const profile = { email: name, accountUuid: 'test-owner', orgUuid: 'test-org' };
  const creds = { accessToken: 'fixture-new-access', refreshToken: 'fixture-new-refresh', expiresAt: now + 120000 };
  const { atomicConfigUpdate, loadConfig, withConfigLock } = await upstream('config.js');
  process.env.TEAMCLAUDE_CONFIG = path;
  try {
    const callbackPath = join(directory, 'teamclaude.callback.json');
    await requireLocalCredentials(callbackPath);
    await writeFile(callbackPath, '{}', { mode: 0o600 });
    await assert.rejects(requireLocalCredentials(callbackPath), /local-only helper/);
    await writeFile(path, JSON.stringify(baseline), { mode: 0o600 });
    const before = await readFile(path, 'utf8');
    const loaded = await loadConfig();
    const expected = targetAccount(loaded, name);
    for (const wrong of [{ email: 'other@example.test' }, { accountUuid: 'other-owner' }, { orgUuid: 'other-org' },
      { orgUuid: null }, { error: 'fixture network error' }]) {
      await assert.rejects(atomicConfigUpdate(config => replaceCredentials(config, name, expected, { ...profile, ...wrong }, creds, now)), /did not verify/);
      assert.equal(await readFile(path, 'utf8'), before);
    }
    assert.throws(() => targetAccount(loaded, 'fallback'), /exactly one enabled/);
    assert.throws(() => targetAccount(loaded, 'missing@example.test'), /exactly one enabled/);
    assert.throws(() => targetAccount({ ...loaded, accounts: [expected.a, structuredClone(expected.a)] }, name), /exactly one enabled/);
    assert.throws(() => targetAccount({ ...loaded, accounts: [{ ...expected.a, orgUuid: undefined }] }, name), /missing or ambiguous/);
    await assert.rejects(atomicConfigUpdate(config => replaceCredentials(config, name,
      { ...expected, a: { ...expected.a, refreshToken: 'fixture-raced' } }, profile, creds, now)), /changed during/);
    assert.equal(await readFile(path, 'utf8'), before);
    let state = 'active', finalStopState = 'inactive', duringStop, cannotStart = false;
    const actions = [];
    const service = async action => {
      actions.push(action);
      if (action === 'state') return state;
      if (action === 'stop') {
        await duringStop?.();
        state = finalStopState;
      }
      if (action === 'start') {
        if (cannotStart) throw new Error('fixture start error');
        state = 'active';
      }
    };
    // Expiry is checked at the real commit boundary, not at fixture time.
    creds.expiresAt = Date.now() + 120000;
    await rm(callbackPath);
    const commit = () => commitRecovery({ service, withConfigLock, configPath: path, callbackPath, name, expected, profile, creds });

    const lockPath = `${path}.lock`;
    const lock = JSON.stringify({ pid: process.pid, at: Date.now() - 60000 });
    await writeFile(lockPath, lock, { mode: 0o600 });
    process.env.TEAMCLAUDE_CONFIG_LOCK_WAIT_MS = '30';
    // An independent lock owner (not an entry on this process's promise queue).
    await assert.rejects(atomicConfigUpdate(() => assert.fail('upstream wrote without lock')), /lock is busy/);
    await assert.rejects(commit(), /lock is busy/);
    assert.deepEqual(actions.splice(0), ['state', 'stop', 'start']);
    assert.equal(await readFile(lockPath, 'utf8'), lock);
    assert.equal(await readFile(path, 'utf8'), before);
    await rm(lockPath);

    state = 'inactive';
    await assert.rejects(commit(), /Gateway not active/);
    assert.deepEqual(actions.splice(0), ['state']);
    state = 'active';

    finalStopState = 'activating';
    await assert.rejects(commit(), /Gateway is not stopped/);
    assert.deepEqual(actions.splice(0), ['state', 'stop', 'state', 'start']);
    assert.equal(await readFile(path, 'utf8'), before);
    finalStopState = 'inactive';

    // A signal while stop is pending still requires start, but no save.
    let interrupted = false;
    duringStop = () => { interrupted = true; };
    await assert.rejects(commitRecovery({ service, withConfigLock, configPath: path, callbackPath,
      name, expected, profile, creds, interrupted: () => interrupted }), /interrupted/);
    assert.deepEqual(actions.splice(0), ['state', 'stop', 'start']);
    assert.equal(await readFile(path, 'utf8'), before);

    // Cancellation while staging the replacement must not publish it.
    duringStop = undefined;
    const staged = () => readdirSync(directory).some(name => name.startsWith('teamclaude.json.relogin-'));
    await assert.rejects(commitRecovery({ service, withConfigLock, configPath: path, callbackPath,
      name, expected, profile, creds, interrupted: staged }), /interrupted/);
    assert.deepEqual(actions.splice(0), ['state', 'stop', 'state', 'start']);
    assert.equal(await readFile(path, 'utf8'), before);
    assert.equal(staged(), false);

    // A queued old-process refresh completing before stop returns. The only
    // safe outcome is refuse the browser pair, then restart on the saved row.
    const refresh = 'fixture-queued-refresh';
    duringStop = () => atomicConfigUpdate(config => { config.accounts[0].refreshToken = refresh; });
    await assert.rejects(commit(), /changed during/);
    assert.equal((await loadConfig()).accounts[0].refreshToken, refresh);
    assert.deepEqual(actions.splice(0), ['state', 'stop', 'state', 'start']);
    await writeFile(path, before);
    duringStop = undefined;

    // A dead holder must not strand subsequent preStart/recovery on a lock.
    const deadOwner = 2147483647;
    assert.throws(() => process.kill(deadOwner, 0), { code: 'ESRCH' });
    await writeFile(lockPath, JSON.stringify({ pid: deadOwner, at: Date.now() }), { mode: 0o600 });
    await withConfigLock(path, async () => {
      assert.equal(JSON.parse(await readFile(lockPath, 'utf8')).pid, process.pid);
    });
    await assert.rejects(stat(lockPath), { code: 'ENOENT' });

    // Restart failure after a committed write is distinguishable from a
    // refusal. Leave the new pair on disk, private, for the operator to start.
    cannotStart = true;
    await assert.rejects(commit(), /Credentials saved, but the gateway did not confirm start/);
    assert.deepEqual(actions, ['state', 'stop', 'state', 'start']);
    const after = await loadConfig();
    assert.deepEqual(after.accounts[1], loaded.accounts[1]);
    const { refreshTokenExpiresAt: oldDate, ...other } = loaded.accounts[0];
    assert.deepEqual(after.accounts[0], { ...other, ...creds });
    assert.equal((await stat(path)).mode & 0o777, 0o600);
  } finally {
    delete process.env.TEAMCLAUDE_CONFIG;
    delete process.env.TEAMCLAUDE_CONFIG_LOCK_WAIT_MS;
    await rm(directory, { recursive: true, force: true });
  }
});
