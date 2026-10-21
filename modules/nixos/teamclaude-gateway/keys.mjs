// teamclaude-keys: runtime client keys of the TeamClaude gateway.
//
//   teamclaude-keys add <name>      mint a key, print it once
//   teamclaude-keys list            names and key fingerprints
//   teamclaude-keys show <name>     print a key again
//   teamclaude-keys revoke <name>   drop a key
//
// Keys live in TeamClaude's own `proxy.clientKeys` list in the live config
// (/var/lib/teamclaude/teamclaude.json), written with TeamClaude's own
// locked read-modify-write, so a concurrent token refresh by the server
// survives. The running server picks the change up through its reload
// endpoint; no restart, no clan var per key. Usage is booked per name in
// `teamclaude status`.
//
// argv: <teamclaude src dir> <command> [name]. The wrapper (./default.nix)
// runs this as the teamclaude user with TEAMCLAUDE_CONFIG set.
import { createHash, randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [srcDir, command, name] = process.argv.slice(2);
const { atomicConfigUpdate, loadConfig } = await import(pathToFileURL(join(srcDir, 'config.js')).href);
const usage = 'usage: teamclaude-keys add|show|revoke <name> | list';
class KeyError extends Error {}
// Thrown, not exited: inside atomicConfigUpdate the lock must be released.
const fail = (msg) => {
  throw new KeyError(msg);
};
// The name is the usage label in `teamclaude status`; keep it a plain word.
const checkName = () => {
  if (!name || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(name)) fail(`${usage}\n(name: letters, digits, . _ -)`);
};
const fingerprint = (key) => createHash('sha256').update(key).digest('hex').slice(0, 12);
const keysOf = (config) => (Array.isArray(config.proxy?.clientKeys) ? config.proxy.clientKeys : []);

// The server re-reads proxy.clientKeys on reload. The shared operator key
// authenticates the call: trustLoopback is off, so loopback needs it too.
async function reload(config) {
  const port = config.proxy?.port ?? 3456;
  try {
    const res = await fetch(`http://127.0.0.1:${port}/teamclaude/reload`, {
      method: 'POST',
      headers: { 'x-api-key': config.proxy?.apiKey ?? '' },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
  } catch (err) {
    console.error(`teamclaude-keys: saved, but the running server did not reload (${err.message}); it applies on its next start`);
  }
}

async function run() {
  switch (command) {
    case 'add': {
      checkName();
      // Same shape as the operator key: omp and Pi present as Claude Code
      // only when their key looks like a subscription token.
      const key = `sk-ant-oat01-${randomBytes(32).toString('hex')}`;
      const config = await atomicConfigUpdate((c) => {
        c.proxy ??= {};
        const keys = keysOf(c);
        if (keys.some((e) => e.name === name)) fail(`a key named ${name} exists; revoke it first`);
        c.proxy.clientKeys = [...keys, { name, key }];
      });
      await reload(config);
      console.log(key);
      return;
    }
    case 'revoke': {
      checkName();
      const config = await atomicConfigUpdate((c) => {
        const keys = keysOf(c);
        if (!keys.some((e) => e.name === name)) fail(`no key named ${name}`);
        c.proxy.clientKeys = keys.filter((e) => e.name !== name);
      });
      await reload(config);
      console.log(`revoked ${name}`);
      return;
    }
    case 'show': {
      checkName();
      const entry = keysOf((await loadConfig()) ?? {}).find((e) => e.name === name);
      if (!entry) fail(`no key named ${name}`);
      console.log(entry.key);
      return;
    }
    case 'list':
      for (const e of keysOf((await loadConfig()) ?? {})) console.log(`${e.name}\t${fingerprint(e.key)}`);
      return;
    default:
      fail(usage);
  }
}

try {
  await run();
} catch (err) {
  if (!(err instanceof KeyError)) throw err;
  console.error(`teamclaude-keys: ${err.message}`);
  process.exit(1);
}
