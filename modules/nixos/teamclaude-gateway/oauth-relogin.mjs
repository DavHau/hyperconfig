// Human-only re-login for an already enrolled Claude subscription. Upstream
// `login --token --name` can add a row or skip profile detection. This uses
// the same browser flow but commits only while the gateway is stopped.
import { execFile, execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { constants, renameSync } from 'node:fs';
import { lstat, open, unlink } from 'node:fs/promises';
import { constants as osConstants } from 'node:os';
import { createInterface } from 'node:readline/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { authRejection, epochMs, readStatus, subscriptionOAuth } from './oauth-status.mjs';

class OperatorError extends Error {}
const refuse = message => { throw new OperatorError(message); };
const normalEmail = /^[^\s@()]+@[^\s@()]+$/;
const present = field => typeof field === 'string' && field.length > 0;

export async function requireLocalCredentials(callbackPath) {
  try {
    await lstat(callbackPath);
  } catch (err) {
    if (err.code === 'ENOENT') return;
    throw err;
  }
  refuse('This gateway has a callback credential-store sidecar. This local-only helper will not update it.');
}

export function targetAccount(config, name) {
  const rows = config?.accounts?.filter(a => a.name === name) ?? [];
  const a = rows[0];
  // No route/provider changes. This narrow tool is for the fleet's directly
  // authenticated subscription rows, not imported, routed or long-lived ones.
  if (rows.length !== 1 || config.upstream !== 'https://api.anthropic.com' ||
      !subscriptionOAuth({ ...a, provider: a.provider ?? 'anthropic' }) ||
      a.disabled || a.upstream || a.importFrom || a.routing) {
    refuse('Expected exactly one enabled, directly enrolled Claude subscription at that name. No credentials saved.');
  }
  const email = name.replace(/ \([^()]+\)$/, '');
  if (!normalEmail.test(email) || ![a.id, a.accountUuid, a.orgUuid].every(present) ||
      config.accounts.filter(row => row.provider !== 'codex' &&
        row.accountUuid === a.accountUuid && row.orgUuid === a.orgUuid).length !== 1) {
    refuse('The enrolled name, row ID, Claude account or organization is missing or ambiguous. No credentials saved.');
  }
  return { a, email };
}

export function requireIdentity(profile, { a, email }) {
  if (profile?.error || profile?.email !== email || profile?.accountUuid !== a.accountUuid ||
      profile?.orgUuid !== a.orgUuid) {
    refuse('Claude did not verify the enrolled email, account and organization. No credentials saved.');
  }
}

export function replaceCredentials(config, name, expected, profile, creds, now = Date.now()) {
  const current = targetAccount(config, name);
  requireIdentity(profile, current);
  const { a } = current;
  if (a.id !== expected.a.id || a.accountUuid !== expected.a.accountUuid || a.orgUuid !== expected.a.orgUuid ||
      a.refreshToken !== expected.a.refreshToken || a.accessToken !== expected.a.accessToken) {
    refuse('The enrolled row or its credentials changed during the browser flow. No credentials saved; re-check status.');
  }
  if (!present(creds?.accessToken) || !present(creds?.refreshToken) || !epochMs(creds?.expiresAt) || creds.expiresAt <= now) {
    refuse('Claude did not return a usable subscription credential pair. No credentials saved.');
  }
  a.accessToken = creds.accessToken;
  a.refreshToken = creds.refreshToken;
  a.expiresAt = creds.expiresAt;
  // The previous date belonged to the old refresh token. Don't start a timer
  // ourselves; keep only the date supplied by TeamClaude's sign-in flow.
  if (epochMs(creds.refreshTokenExpiresAt)) a.refreshTokenExpiresAt = creds.refreshTokenExpiresAt;
  else delete a.refreshTokenExpiresAt;
}

const iso = n => epochMs(n) ? new Date(n).toISOString() : null;
const probeTime = s => iso(typeof s === 'string' ? Date.parse(s) : null);
const safeState = s => typeof s === 'string' && /^[a-z][a-z-]{0,31}$/.test(s) ? s : null;
const fraction = n => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1 ? n : null;

export async function accountStatus(name, configPath) {
  const s = await readStatus(configPath);
  const rows = s.accounts.filter(a => a.name === name);
  if (rows.length !== 1 || !subscriptionOAuth(rows[0])) refuse('No unique live Claude subscription OAuth row with that exact name.');
  const a = rows[0];
  const probes = Array.isArray(s.probe?.accounts) ? s.probe.accounts.filter(p => p?.name === name) : [];
  const p = probes.length === 1 ? probes[0] : null;
  const started = probeTime(p?.startedAt), finished = probeTime(p?.lastProbedAt);
  const utilization = fraction(p?.weekly?.utilization), reset = iso(p?.weekly?.resetAt);
  const complete = p?.status === 'ok' && started && finished && started <= finished &&
    utilization !== null && reset && reset > finished;
  return {
    account: name, disabled: a.disabled, status: safeState(a.status),
    reloginRequired: authRejection(a), refreshDeadline: iso(a.refreshTokenExpiresAt),
    quotaProbe: safeState(p?.status), probeStartedAt: started, lastProbedAt: finished,
    weeklyUtilization: complete ? utilization : null, weeklyReset: complete ? reset : null,
  };
}

async function readConfig(path) {
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const file = await handle.stat();
    if (!file.isFile() || (file.mode & 0o777) !== 0o600) refuse('Expected a regular private TeamClaude config. No credentials saved.');
    return { file, config: JSON.parse(await handle.readFile('utf8')) };
  } finally {
    await handle.close();
  }
}

async function saveConfig(path, config, { uid, gid }, interrupted) {
  const tmp = `${path}.relogin-${randomUUID()}`;
  const handle = await open(tmp, 'wx', 0o600);
  try {
    try {
      await handle.writeFile(JSON.stringify(config, null, 2) + '\n');
      await handle.chown(uid, gid);
      await handle.sync();
    } finally {
      await handle.close();
    }
    if (interrupted()) refuse('Recovery interrupted. No credentials saved.');
    renameSync(tmp, path);
  } catch (err) {
    await unlink(tmp).catch(() => {});
    throw err;
  }
}

// Wait for the old cgroup to exit before writing. preStart takes the same
// strict config lock, so a start racing the inactive check cannot load the
// old config. A refresh that finished during stop is detected by the CAS.
export async function commitRecovery({ service, withConfigLock, configPath, callbackPath, name,
  expected, profile, creds, interrupted = () => false }) {
  if (interrupted()) refuse('Recovery interrupted. No credentials saved.');
  if (await service('state') !== 'active' || interrupted()) refuse('Gateway not active or interrupted. No credentials saved.');
  let saved = false;
  try {
    await service('stop');
    await withConfigLock(configPath, async () => {
      if (interrupted() || await service('state') !== 'inactive') refuse('Gateway is not stopped or recovery was interrupted. No credentials saved.');
      await requireLocalCredentials(callbackPath);
      const { file, config } = await readConfig(configPath);
      replaceCredentials(config, name, expected, profile, creds);
      if (interrupted()) refuse('Recovery interrupted. No credentials saved.');
      await saveConfig(configPath, config, file, interrupted);
      saved = true;
    });
  } finally {
    try {
      await service('start');
    } catch {
      refuse(`${saved ? 'Credentials saved' : 'No credentials saved'}, but the gateway did not confirm start. Restore the service before retrying.`);
    }
  }
  return new Date().toISOString();
}

async function browserCredentials(startOAuthLogin, stty, cancelled) {
  const controller = new AbortController();
  const signal = AbortSignal.any([cancelled, controller.signal, AbortSignal.timeout(600000)]);
  const flow = await startOAuthLogin({ loopback: false, timeoutMs: 600000, signal });
  try {
    signal.throwIfAborted();
    const tty = (...args) => execFileSync(stty, args, { encoding: 'utf8', stdio: ['inherit', 'pipe', 'ignore'] }).trim();
    const saved = tty('-g');
    const onClose = () => controller.abort();
    let terminal;
    let code;
    try {
      // Keep canonical mode (including Ctrl-C), but never echo the code.
      tty('-echo');
      console.log(`Open this TeamClaude authorization URL in your own browser:\n${flow.url}`);
      terminal = createInterface({ input: process.stdin, output: process.stderr, terminal: false });
      terminal.once('close', onClose);
      code = await terminal.question('Paste the authorization code here (input hidden): ', { signal });
    } finally {
      // Closing readline aborts an unanswered prompt on EOF, but must not
      // abort the OAuth exchange after a successful paste.
      terminal?.off('close', onClose);
      terminal?.close();
      tty(saved);
    }
    signal.throwIfAborted();
    if (!flow.submit(code)) refuse('No usable authorization code received. No credentials saved.');
    process.stderr.write('\n');
    return await flow.tokens;
  } catch (err) {
    cancelled.throwIfAborted();
    throw err;
  } finally {
    controller.abort();
  }
}

async function relogin(src, systemctl, stty, name, configPath, signal) {
  const { withConfigLock } = await import(pathToFileURL(join(src, 'config.js')).href);
  const { fetchProfile, startOAuthLogin } = await import(pathToFileURL(join(src, 'oauth.js')).href);
  const { getCallbackAuthPath } = await import(pathToFileURL(join(src, 'callback-auth.js')).href);
  const callbackPath = getCallbackAuthPath();
  await requireLocalCredentials(callbackPath);
  const expected = targetAccount((await readConfig(configPath)).config, name);
  const live = await accountStatus(name, configPath);
  if (live.disabled) refuse('The live account is disabled. No credentials saved.');
  console.log(`Re-login only for ${name}; the Claude account and organization must match the existing row.`);
  signal.throwIfAborted();
  const creds = await browserCredentials(startOAuthLogin, stty, signal);
  signal.throwIfAborted();
  const profile = await fetchProfile(creds.accessToken);
  requireIdentity(profile, expected);
  const runSystemctl = promisify(execFile);
  const service = async action => (await runSystemctl(systemctl, action === 'state'
    ? ['show', '--property=ActiveState', '--value', 'teamclaude.service']
    : [action, 'teamclaude.service'], { timeout: action === 'state' ? 5000 : 95000 })).stdout.trim();
  const restarted = await commitRecovery({ service, withConfigLock, configPath, callbackPath,
    name, expected, profile, creds, interrupted: () => signal.aborted });
  console.log(`Updated credentials; gateway start returned at ${restarted}. Wait for a new complete quota probe.`);
}

async function run() {
  const [src, systemctl, stty, command, name, extra] = process.argv.slice(2);
  const configPath = process.env.TEAMCLAUDE_CONFIG;
  if (!configPath || !name || extra !== undefined || !['status', 're-login'].includes(command)) {
    refuse('Usage: teamclaude-oauth status|re-login <exact TeamClaude account name>');
  }
  if (command === 'status') {
    console.log(JSON.stringify(await accountStatus(name, configPath), null, 2));
    return;
  }
  if (!process.stdin.isTTY || !process.stdout.isTTY) refuse('Use an interactive, unrecorded terminal for re-login.');
  const cancellation = new AbortController();
  // The launcher execs us. Keep this process alive through terminal and
  // service cleanup even if a signal was sent only to the launch PID.
  const cancel = signal => {
    if (cancellation.signal.aborted) return;
    process.exitCode = 128 + osConstants.signals[signal];
    cancellation.abort(new OperatorError('Recovery interrupted. No credentials saved.'));
  };
  const signals = ['SIGINT', 'SIGHUP', 'SIGTERM'];
  for (const signal of signals) process.on(signal, cancel);
  try {
    await relogin(src, systemctl, stty, name, configPath, cancellation.signal);
  } finally {
    for (const signal of signals) process.off(signal, cancel);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    await run();
  } catch (err) {
    console.error(`teamclaude-oauth: ${err instanceof OperatorError ? err.message : 'operation failed; check status before retrying'}`);
    process.exitCode ??= 1;
  }
}
