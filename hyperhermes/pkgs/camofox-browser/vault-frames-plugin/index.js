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
 *
 * Deciding which frame may take a card is hermes' job: it reads the frame's
 * own origin and ancestry from inside it and re-checks both in the same
 * script as the write. This plugin only guarantees that a frameId names a
 * direct child of the caller's tab. The caller owns the tab (core's userId
 * lookup); both routes hold the tab's lock like core's evaluate. The
 * expression (which carries a card on a fill) is never logged.
 */

import crypto from 'node:crypto';

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

function directChildren(page) {
  const main = page.mainFrame();
  return main.childFrames().filter((f) => !f.isDetached() && f.parentFrame() === main);
}

export async function register(app, ctx) {
  const {
    sessions, log, normalizeUserId, withUserLimit,
    findTab, withTabLock, destroyTimedOutTab, tabNotFoundResponse, handleRouteError,
  } = ctx;
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
          return { value: await frame.evaluate(expression) };
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
      // Not err.message: a page exception's text could quote the expression.
      log('error', 'vault frame evaluate failed', { reqId: req.reqId, tabId });
      res.status(500).json({ error: 'frame evaluate failed' });
    }
  });
}
