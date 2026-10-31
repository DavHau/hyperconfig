// teamclaude-accounts: runtime usage caps of the TeamClaude gateway's
// enrolled accounts.
//
//   teamclaude-accounts list                    accounts, the running server's caps and quota use
//   teamclaude-accounts cap <name> <cap>        set the account's own cap
//   teamclaude-accounts cap <name> default      back to the fleet default
//
// <cap> is a share of every quota bucket, as a ratio or a percentage
// (0.8, 80%), or per bucket (unified5h=0.8,unified7d=0.9); a bucket the
// per-bucket form leaves out is uncapped (TeamClaude's accounts[].maxUsage).
// At the cap the account gets no request at all, the revalidation probe
// included.
//
// An account's own cap lives in <caps file>, the service's preStart reads it
// on every start (./default.nix), so it survives restarts while every other
// account keeps the fleet default from the Nix config. This tool writes that
// file first, then the account's maxUsage in the live config with
// TeamClaude's own locked read-modify-write, then has the running server
// reload: the cap applies at once, no restart.
//
// argv: <teamclaude src dir> <caps file> <default cap> <command> [name] [cap].
// The wrapper (./default.nix) runs this as the teamclaude user with
// TEAMCLAUDE_CONFIG set.
import { readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [srcDir, capsFile, defaultCapArg, command, name, capArg] = process.argv.slice(2);
const defaultCap = Number(defaultCapArg);
const { atomicConfigUpdate, loadConfig } = await import(pathToFileURL(join(srcDir, 'config.js')).href);
const usage = 'usage: teamclaude-accounts list | cap <name> <0.8|80%|unified5h=0.8,unified7d=0.9|default>';
const BUCKETS = ['unified5h', 'unified7d', 'unified7dFable', 'unified7dSonnet', 'tokens', 'requests', 'default'];
class AccountError extends Error {}
// Thrown, not exited: inside atomicConfigUpdate the lock must be released.
const fail = (msg) => {
  throw new AccountError(msg);
};

// A ratio in (0, 1]. 0 is refused: TeamClaude reads a falsy cap as no cap.
function ratio(text) {
  const t = text.trim();
  const value = t.endsWith('%') ? Number(t.slice(0, -1)) / 100 : Number(t);
  if (!Number.isFinite(value) || value <= 0 || value > 1) fail(`bad cap ${text}: a ratio above 0 and at most 1, or a percentage`);
  return value;
}

function parseCap(text) {
  if (!text.includes('=')) return ratio(text);
  const caps = {};
  for (const part of text.split(',')) {
    const [bucket, value, extra] = part.split('=');
    if (extra !== undefined || !BUCKETS.includes(bucket?.trim())) fail(`bad bucket in ${text}; buckets: ${BUCKETS.join(', ')}`);
    caps[bucket.trim()] = ratio(value ?? '');
  }
  return caps;
}

const accountsOf = (config) => (Array.isArray(config.accounts) ? config.accounts : []);
const show = (cap) => (cap == null ? 'none' : typeof cap === 'number' ? `${Math.round(cap * 1000) / 10}%` : JSON.stringify(cap));

async function readCaps() {
  try {
    return JSON.parse(await readFile(capsFile, 'utf8'));
  } catch (err) {
    if (err.code === 'ENOENT') return {};
    throw err;
  }
}

async function writeCaps(caps) {
  const tmp = `${capsFile}.tmp`;
  await writeFile(tmp, `${JSON.stringify(caps, null, 2)}\n`, { mode: 0o600 });
  await rename(tmp, capsFile);
}

// The server re-reads every account's maxUsage on reload. The shared operator
// key authenticates the call: trustLoopback is off, so loopback needs it too.
async function reload(config) {
  const port = config.proxy?.port ?? 3456;
  try {
    const res = await fetch(`http://127.0.0.1:${port}/teamclaude/reload`, {
      method: 'POST',
      headers: { 'x-api-key': config.proxy?.apiKey ?? '' },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
  } catch (err) {
    console.error(`teamclaude-accounts: saved, but the running server did not reload (${err.message}); it applies on its next start`);
  }
}

async function run() {
  switch (command) {
    case 'list': {
      const caps = await readCaps();
      const config = (await loadConfig()) ?? {};
      // Caps and quota as the running server holds them (quota is never on
      // disk); the config file when the server does not answer.
      let live = null;
      try {
        const res = await fetch(`http://127.0.0.1:${config.proxy?.port ?? 3456}/teamclaude/status`, {
          headers: { 'x-api-key': config.proxy?.apiKey ?? '' },
        });
        if (res.ok) live = (await res.json()).accounts ?? null;
      } catch {}
      if (!live) console.error('teamclaude-accounts: the server did not answer; caps from the config file, no quota');
      for (const a of live ?? accountsOf(config)) {
        const q = a.quota ?? {};
        const used = ['unified5h', 'unified7d'].map((b) => `${b}=${q[b] == null ? '?' : `${Math.round(q[b] * 100)}%`}`).join(' ');
        console.log(`${a.name}\tcap ${show(a.maxUsage)} (${a.name in caps ? 'own' : 'default'})\t${used}${a.disabled ? '\tdisabled' : ''}`);
      }
      return;
    }
    case 'cap': {
      if (!name || !capArg) fail(usage);
      const own = capArg === 'default' ? null : parseCap(capArg);
      const config0 = (await loadConfig()) ?? {};
      if (!accountsOf(config0).some((a) => a.name === name)) fail(`no account named ${name} (see: teamclaude-accounts list)`);
      // The file first: a service start between the two writes then already
      // stamps the new cap, instead of the old one over the live edit.
      const caps = await readCaps();
      if (own == null) delete caps[name];
      else caps[name] = own;
      await writeCaps(caps);
      const config = await atomicConfigUpdate((c) => {
        const account = accountsOf(c).find((a) => a.name === name);
        if (!account) fail(`no account named ${name}`);
        account.maxUsage = own ?? defaultCap;
      });
      await reload(config);
      console.log(`${name}: cap ${show(own ?? defaultCap)}${own == null ? ' (default)' : ''}`);
      return;
    }
    default:
      fail(usage);
  }
}

try {
  await run();
} catch (err) {
  if (!(err instanceof AccountError)) throw err;
  console.error(`teamclaude-accounts: ${err.message}`);
  process.exit(1);
}
