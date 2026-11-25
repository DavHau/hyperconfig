/**
 * Vault frames plugin: the iframes embedded directly in a tab's page, for
 * hermes' browser_vault payment fill into hosted card fields (Stripe
 * Elements, Braintree Hosted Fields, Adyen Secured Fields, Square). Camofox
 * has no CDP, so hermes cannot reach a cross-origin iframe the way it does
 * over a CDP supervisor; these two routes are its frame seam
 * (pkgs/hermes-camofox-plugin/vault-frames.patch).
 *
 *   POST /tabs/:tabId/vault-frames { userId }
 *     -> { ok, frames: [{ frameId, url }] }: only the DIRECT children of the
 *        tab's main frame (never a grandchild, never another tab's frame).
 *        frameId is an opaque id this server keeps per page.
 *   POST /tabs/:tabId/vault-frames/:frameId/evaluate { userId, expression }
 *     -> { ok, result }: evaluates in that frame, only while it is still a
 *        direct child of the tab's main frame and attached.
 *   POST /tabs/:tabId/vault-evaluate { userId, expression }
 *     -> { ok, result }: the same for the tab's main frame (the vault's
 *        top-level password and card writes).
 *
 * Every script runs isolated from the page's own JavaScript: Camoufox's
 * page.evaluate world is a Cu.Sandbox with Xray wrappers, so page code can
 * neither replace the built-ins a fill script calls nor reach it through
 * fn.caller (the script holds the card). These routes do not trust that
 * default:
 *   - the browser's launch config (browser:launching, read here in node,
 *     out of any page's reach) must not set Camoufox's disableWorldIsolation
 *     (evaluate in the page's own world) or allowMainWorld (the "mw:"
 *     main-world escape); a browser launched with either gets no vault
 *     script at all, and none runs before a launch was seen;
 *   - a script starting with "mw:" is refused;
 *   - each evaluation first asserts, in the same world, that the DOM is
 *     seen through Xrays (document.wrappedJSObject exists only there). Page
 *     code could fake that only where isolation is already gone, so it backs
 *     the launch check against a Camoufox whose default changed.
 * A failed assertion answers 409 and the script never runs.
 *
 * Deciding which frame may take a card is hermes' job: it reads the frame's
 * own origin and ancestry from inside it and re-checks both in the same
 * script as the write. This plugin only guarantees that a frameId names a
 * direct child of the caller's tab. The caller owns the tab (core's userId
 * lookup); both routes hold the tab's lock like core's evaluate. The
 * expression (which carries a card on a fill) is never logged.
 */

import crypto from 'node:crypto';

import { guard, trackFill } from './mask.js';

// Per page: frameId -> Frame, for the frames last listed.
const frameIds = new WeakMap();

function idsFor(page) {
  let ids = frameIds.get(page);
  if (!ids) {
    ids = new Map();
    frameIds.set(page, ids);
  }
  return ids;
}

// Camoufox evaluates a script starting with this prefix in the page's main world (when allowMainWorld).
const MAIN_WORLD_PREFIX = 'mw:';

// The script runs only in an isolated world: see the header. Throws IsolationError otherwise.
class IsolationError extends Error {}

// Camoufox reads its config from the CAMOU_CONFIG_<n> env chunks (camoufox-js getEnvVars).
const UNSAFE_CAMOU_KEYS = ['disableWorldIsolation', 'allowMainWorld'];
// The options of the last launch (null: none seen yet), read at each evaluation: a listener that runs
// after this one may still change them before the browser starts.
let launchOptions = null;

export function camouConfigIsolated(env) {
  const chunks = Object.keys(env || {}).filter((k) => /^CAMOU_CONFIG_\d+$/.test(k))
    .sort((a, b) => Number(a.slice(13)) - Number(b.slice(13)));
  let config = {};
  if (chunks.length) {
    try { config = JSON.parse(chunks.map((k) => env[k]).join('')); } catch { return false; }
  }
  return !UNSAFE_CAMOU_KEYS.some((k) => config && config[k]);
}

let maskingReady = false;

async function evaluateIsolated(page, frame, expression) {
  if (!maskingReady) throw new IsolationError('filled fields cannot be masked on this server');
  if (!launchOptions || !camouConfigIsolated(launchOptions.env)) {
    throw new IsolationError('the browser was not seen launching with isolated worlds');
  }
  if (expression.trimStart().startsWith(MAIN_WORLD_PREFIX)) {
    throw new IsolationError('main-world scripts are refused');
  }
  const xray = await frame.evaluate('typeof document.wrappedJSObject === "object" && document.wrappedJSObject !== document');
  if (xray !== true) {
    throw new IsolationError('this browser evaluates in the page\'s own world');
  }
  // The controls the script changes are the vault-filled ones: masked in every capture (./mask.js).
  return trackFill(page, frame, () => frame.evaluate(expression));
}

function directChildren(page) {
  const main = page.mainFrame();
  return main.childFrames().filter((f) => !f.isDetached() && f.parentFrame() === main);
}

export async function register(app, ctx) {
  const {
    sessions, log, normalizeUserId, withUserLimit,
    findTab, withTabLock, destroyTimedOutTab, tabNotFoundResponse, handleRouteError,
    registerCaptureGuard,
  } = ctx;
  // The vault mask (./mask.js): fields a vault script filled are covered in every screenshot and
  // snapshot the server returns. Without the core's capture guard (capture-guard.patch) no vault
  // script runs at all: a fill would then show in plain text.
  const masking = typeof registerCaptureGuard === 'function';
  if (masking) {
    registerCaptureGuard(guard);
    maskingReady = true;
  }
  else log('error', 'vault scripts disabled: this server has no capture guard to mask filled fields');
  // Every (re)launch: are its evaluate worlds isolated? (See the header.)
  ctx.events.on('browser:launching', ({ options }) => {
    launchOptions = options || {};
    if (!camouConfigIsolated(launchOptions.env)) {
      log('error', 'vault scripts disabled: browser launched with main-world evaluation');
    }
  });

  // A frame list or a fill is quick; a page that blocks longer loses the tab, like core's evaluate.
  const timeoutMs = () => 30000;

  function lookup(req, res) {
    const userId = req.body?.userId;
    if (!userId) {
      res.status(400).json({ error: 'userId is required' });
      return null;
    }
    const session = sessions.get(normalizeUserId(userId));
    const found = session && findTab(session, req.params.tabId);
    if (!found) {
      tabNotFoundResponse(res, req.params.tabId);
      return null;
    }
    session.lastAccess = Date.now();
    // A traced session writes DOM snapshots and screencast frames (input values included) to disk,
    // past every capture guard: no vault script runs in one.
    if (session.tracePath) {
      res.status(409).json({ error: 'this browser session is traced: vault fills are refused' });
      return null;
    }
    return { userId, session, tabState: found.tabState };
  }

  app.post('/tabs/:tabId/vault-frames', async (req, res) => {
    const { tabId } = req.params;
    try {
      const t = lookup(req, res);
      if (!t) return;
      const frames = await withUserLimit(t.userId, () => withTabLock(
        tabId,
        async () => {
          const ids = idsFor(t.tabState.page);
          ids.clear();
          return directChildren(t.tabState.page).slice(0, 40).map((frame) => {
            const frameId = crypto.randomUUID();
            ids.set(frameId, frame);
            return { frameId, url: frame.url() };
          });
        },
        timeoutMs(),
        () => destroyTimedOutTab(t.session, tabId, 'operation_timeout', t.userId),
      ));
      log('info', 'vault frames', { reqId: req.reqId, tabId, count: frames.length });
      res.json({ ok: true, frames });
    } catch (err) {
      log('error', 'vault frames failed', { reqId: req.reqId, tabId, error: err.message });
      handleRouteError(err, req, res);
    }
  });

  // The body comes through core's global JSON parser (100 kB; a fill script is a few kB).
  app.post('/tabs/:tabId/vault-frames/:frameId/evaluate', async (req, res) => {
    const { tabId, frameId } = req.params;
    try {
      const expression = req.body?.expression;
      if (!expression || typeof expression !== 'string') {
        return res.status(400).json({ error: 'expression is required' });
      }
      const t = lookup(req, res);
      if (!t) return;
      const result = await withUserLimit(t.userId, () => withTabLock(
        tabId,
        async () => {
          const page = t.tabState.page;
          const frame = idsFor(page).get(frameId);
          if (!frame || frame.isDetached() || frame.parentFrame() !== page.mainFrame()) {
            return { gone: true };
          }
          return { value: await evaluateIsolated(page, frame, expression) };
        },
        timeoutMs(),
        () => destroyTimedOutTab(t.session, tabId, 'operation_timeout', t.userId),
      ));
      if (result.gone) {
        return res.status(404).json({ error: 'frame is no longer a direct child of the tab' });
      }
      log('info', 'vault frame evaluate', { reqId: req.reqId, tabId, resultType: typeof result.value });
      res.json({ ok: true, result: result.value });
    } catch (err) {
      if (err instanceof IsolationError) {
        log('error', 'vault frame evaluate refused: not isolated', { reqId: req.reqId, tabId });
        return res.status(409).json({ error: 'not an isolated world' });
      }
      // Not err.message: a page exception's text could quote the expression.
      log('error', 'vault frame evaluate failed', { reqId: req.reqId, tabId });
      res.status(500).json({ error: 'frame evaluate failed' });
    }
  });

  // The tab's main frame, for the vault's top-level fills: core's /evaluate would also emit the
  // expression (with the secret) on the tab:evaluate plugin event and asserts no isolation.
  app.post('/tabs/:tabId/vault-evaluate', async (req, res) => {
    const { tabId } = req.params;
    try {
      const expression = req.body?.expression;
      if (!expression || typeof expression !== 'string') {
        return res.status(400).json({ error: 'expression is required' });
      }
      const t = lookup(req, res);
      if (!t) return;
      const value = await withUserLimit(t.userId, () => withTabLock(
        tabId,
        () => evaluateIsolated(t.tabState.page, t.tabState.page.mainFrame(), expression),
        timeoutMs(),
        () => destroyTimedOutTab(t.session, tabId, 'operation_timeout', t.userId),
      ));
      log('info', 'vault evaluate', { reqId: req.reqId, tabId, resultType: typeof value });
      res.json({ ok: true, result: value });
    } catch (err) {
      if (err instanceof IsolationError) {
        log('error', 'vault evaluate refused: not isolated', { reqId: req.reqId, tabId });
        return res.status(409).json({ error: 'not an isolated world' });
      }
      log('error', 'vault evaluate failed', { reqId: req.reqId, tabId });
      res.status(500).json({ error: 'evaluate failed' });
    }
  });
}
