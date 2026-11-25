/**
 * Residential plugin: browser sessions through the host's residential proxy.
 *
 * A camofox userId ending in `-residential-<cc>` (cc: two lowercase letters)
 * gets its browser context created through RESIDENTIAL_PROXY_URL. The proxy
 * username `<cc>-session-<id>` picks the exit country and a sticky exit (the
 * provider keeps one IP per session id for ~30 minutes; the proxy holds the
 * provider's credentials; hyperhermes modules/browser/residential-proxy.nix).
 * The id is derived from the userId, which hermes' browser_residential makes
 * per task (pkgs/hermes-camofox-plugin): parallel tasks of one agent each
 * keep their own exit IP, and a page's connections all leave from the same one.
 * Every other userId is untouched: the direct egress stays the default.
 *
 * Firefox caches proxy credentials per proxy host:port for the whole browser,
 * across contexts: with the proxy username in each context's proxy settings,
 * a context's later requests went out with another context's username (its
 * exit, its country). So each residential context gets a proxy of its own: a
 * loopback shim in this server, on an ephemeral port, that adds the context's
 * Proxy-Authorization to the request head and pipes the connection to the
 * real proxy. Firefox never sees a credential. The shim serves only this
 * server's own uid (the peer's socket owner from /proc/net/tcp), so another
 * local user cannot ride the agent's proxy access; it closes with its context
 * (the context's close event: each context its own shim, never shared).
 *
 * A separate userId is a separate context and persistence profile (the
 * persistence plugin keys by userId), so the direct session's cookies and
 * logins never travel through the proxy.
 *
 * Without RESIDENTIAL_PROXY_URL such a userId is refused at context creation
 * (the context would silently go direct otherwise).
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';

const SUFFIX = /-residential-([a-z]{2})$/;
const HEAD_LIMIT = 64 * 1024;

export function exitSession(userId) {
  // 10 hex digits: the proxy accepts 6-10 letters/digits.
  return crypto.createHash('sha256').update(String(userId)).digest('hex').slice(0, 10);
}

// The uid owning the loopback TCP socket at 127.0.0.1:<port> connected to
// 127.0.0.1:<peerPort>, or null.
function socketUid(port, peerPort) {
  const hex = (p) => p.toString(16).toUpperCase().padStart(4, '0');
  const local = `0100007F:${hex(port)}`;
  const remote = `0100007F:${hex(peerPort)}`;
  let text = '';
  try {
    text = fs.readFileSync('/proc/net/tcp', 'utf8');
  } catch {
    return null;
  }
  for (const line of text.split('\n').slice(1)) {
    const f = line.trim().split(/\s+/);
    if (f[1] === local && f[2] === remote) return Number(f[7]);
  }
  return null;
}

function shim(upstreamHost, upstreamPort, auth, log) {
  const server = net.createServer({ pauseOnConnect: true }, (client) => {
    // /proc/net/tcp of this netns (camofox.nix must not set ProcSubset=pid).
    const uid = socketUid(client.remotePort, client.localPort);
    if (uid === null || uid !== process.getuid()) {
      log('warn', 'residential shim: refused a connection of another uid', { uid });
      client.destroy();
      return;
    }
    // Only the first request head gets the credential: the gateway answers
    // one request per plain-http connection (Connection: close) and a
    // CONNECT is one tunnel. A head must arrive within 30 s, as there.
    client.setTimeout(30000, () => client.destroy());
    let head = Buffer.alloc(0);
    const onData = (chunk) => {
      head = Buffer.concat([head, chunk]);
      const end = head.indexOf('\r\n\r\n');
      if (end < 0) {
        if (head.length > HEAD_LIMIT) client.destroy();
        return;
      }
      client.removeListener('data', onData);
      client.pause();
      client.setTimeout(0);
      const lines = head.subarray(0, end).toString('latin1').split('\r\n')
        .filter((l, i) => i === 0 || !/^proxy-authorization\s*:/i.test(l));
      lines.splice(1, 0, `Proxy-Authorization: ${auth}`);
      const rest = head.subarray(end + 4);
      const up = net.connect(upstreamPort, upstreamHost, () => {
        up.write(Buffer.concat([Buffer.from(lines.join('\r\n') + '\r\n\r\n', 'latin1'), rest]));
        client.pipe(up);
        up.pipe(client);
        client.resume();
      });
      const close = () => { client.destroy(); up.destroy(); };
      up.on('error', close);
      client.on('error', close);
      up.on('close', close);
      client.on('close', close);
    };
    client.on('data', onData);
    client.on('error', () => client.destroy());
    client.resume();
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

export async function register(app, ctx) {
  const { events, log } = ctx;
  const url = process.env.RESIDENTIAL_PROXY_URL || '';
  const m = /^http:\/\/(127\.0\.0\.1):([0-9]+)$/.exec(url);
  // userId -> the shim made for the context being created; handed to that
  // context in 'session:created' and closed with it.
  const pending = new Map();

  events.on('session:creating', async ({ userId, contextOptions }) => {
    const r = SUFFIX.exec(String(userId));
    if (!r) return;
    if (!m) {
      throw Object.assign(new Error('No residential proxy on this browser server'), { statusCode: 400 });
    }
    const session = exitSession(userId);
    const user = `${r[1]}-session-${session}`;
    const auth = 'Basic ' + Buffer.from(`${user}:x`).toString('base64');
    // One shim per context creation, never reused: a context being torn
    // down for the same userId keeps (and closes) its own.
    const server = await shim(m[1], Number(m[2]), auth, log);
    pending.get(userId)?.close();
    pending.set(userId, server);
    // Not created after all (newContext failed): close it after a while.
    setTimeout(() => {
      if (pending.get(userId) === server) {
        pending.delete(userId);
        server.close();
      }
    }, 120000).unref();
    contextOptions.proxy = { server: `http://127.0.0.1:${server.address().port}` };
    log('info', 'residential session', { userId, country: r[1].toUpperCase(), exitSession: session });
  });

  events.on('session:created', ({ userId, context }) => {
    const server = pending.get(userId);
    if (!server) return;
    pending.delete(userId);
    context.on('close', () => server.close());
  });
}
