/**
 * Residential plugin: browser sessions through the host's residential proxy.
 *
 * A camofox userId ending in `-residential-<cc>` (cc: two lowercase letters)
 * gets its browser context created with RESIDENTIAL_PROXY_URL as its proxy,
 * the proxy username `<cc>` picking the exit country (the proxy holds the
 * provider's credentials; hyperhermes modules/browser/residential-proxy.nix).
 * Every other userId is untouched: the direct egress stays the default.
 *
 * hermes' browser_residential tool (pkgs/hermes-camofox-plugin) switches an
 * agent's session to such a userId and back. A separate userId is a separate
 * context and persistence profile (the persistence plugin keys by userId), so
 * the direct session's cookies and logins never travel through the proxy.
 *
 * Without RESIDENTIAL_PROXY_URL such a userId is refused at context creation
 * (the context would silently go direct otherwise).
 */

const SUFFIX = /-residential-([a-z]{2})$/;

export async function register(app, ctx) {
  const { events, log } = ctx;
  const url = process.env.RESIDENTIAL_PROXY_URL || '';
  const valid = /^http:\/\/127\.0\.0\.1:[0-9]+$/.test(url);

  events.on('session:creating', ({ userId, contextOptions }) => {
    const m = SUFFIX.exec(String(userId));
    if (!m) return;
    if (!valid) {
      throw Object.assign(new Error('No residential proxy on this browser server'), { statusCode: 400 });
    }
    contextOptions.proxy = { server: url, username: m[1], password: 'x' };
    log('info', 'residential session', { userId, country: m[1].toUpperCase() });
  });
}
