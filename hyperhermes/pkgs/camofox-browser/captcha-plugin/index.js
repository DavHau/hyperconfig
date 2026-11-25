/**
 * Captcha plugin: POST /tabs/:tabId/solve-captcha { userId }
 *
 * Runs CaptchaKraken's page solver (the npm `captchakraken` driver, linked
 * in by pkgs/camofox-browser) on the tab's live page: it finds the widget
 * (reCAPTCHA, hCaptcha, GeeTest, ...), clicks a checkbox when that is all
 * there is, photographs each challenge round, asks the model at
 * VLLM_BASE_URL what to do, and clicks, drags or types the answer.
 *
 * The caller owns the tab: the core's userId lookup, so another userId's tab
 * is "not found". The solve holds the tab's lock like any core action, so
 * nothing else drives the page meanwhile, and a solve that outlives
 * CAPTCHA_SOLVE_TIMEOUT_MS closes the tab: the driver has no cancel, and a
 * closed page is what stops its clicks.
 *
 * Answers 200 with { status: solved | no_captcha | failed, reason?, vendor,
 * rounds, durationMs, frame? }; 503 when no model endpoint is configured.
 *
 * Nested frames: a widget is often not in the page itself but inside another
 * cross-origin frame (Stripe's hosted card form embeds hCaptcha). The driver
 * only looks in the top document, so when it finds nothing there the solve is
 * run again for each frame that holds a widget, with the driver's element
 * lookups scoped to that frame; the mouse, keyboard and screenshots stay the
 * page's (Playwright's boxes are in the page's viewport for any frame). Every
 * screenshot the driver takes goes through the server's capture guards (the
 * vault mask), like the server's own.
 *
 * POST /tabs/:tabId/click-at { userId, x, y }: a mouse click at a point of the
 * viewport (CSS pixels), whatever frame is there: the fallback for a control
 * no ref reaches. Answers { ok, url }. It lives here because it is the same
 * need as the solve (a widget in a frame no ref reaches) and the same mouse.
 */

import fs from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

const SOLVE_TIMEOUT_MS = parseInt(process.env.CAPTCHA_SOLVE_TIMEOUT_MS, 10) || 120000;
// The driver's own budgets, inside the hard timeout: waiting for a widget is
// not charged to the solve budget, a recorded animated challenge adds up to
// 8 s, and an ask begun near the deadline gets at least 10 s.
const DETECTION_TIMEOUT_MS = 10000;
const SOLVE_BUDGET_MS = Math.max(20000, SOLVE_TIMEOUT_MS - DETECTION_TIMEOUT_MS - 30000);
const MAX_SOLVE_LOOPS = 8;

const NO_WIDGET = 'No interactive captcha widget detected';

function firstLine(err) {
  return String(err?.message || err).split('\n')[0].slice(0, 500);
}

// The vendors' widget selectors, read from the driver's own table.
function widgetSelectors() {
  const { WIDGET_PROBES } = require('captchakraken/dist/selectors.js');
  return [...new Set(WIDGET_PROBES.map((p) => p.selector))];
}

// The frames below the top document holding a visible widget, outermost first.
async function framesWithWidget(page) {
  const selectors = widgetSelectors();
  const out = [];
  for (const frame of page.frames()) {
    if (frame === page.mainFrame() || frame.isDetached()) continue;
    for (const s of selectors) {
      const n = await frame.locator(s).filter({ visible: true }).count().catch(() => 0);
      if (n > 0) {
        out.push(frame);
        break;
      }
    }
  }
  return out;
}

// The page as the driver sees it: element lookups in `frame` (null: the page's own), the rest the page's,
// and every screenshot through the server's capture guards.
function driverView(page, frame, captureScreenshot) {
  const scoped = new Set(['locator', 'waitForSelector', '$', '$$', 'getByRole', 'getByText', 'frameLocator']);
  return new Proxy(page, {
    get(target, key) {
      // The guarded capture, and never to a file: the driver crops it in memory (guardedShot).
      if (key === 'screenshot') return ({ path, ...options } = {}) => captureScreenshot(target, options);
      const owner = frame && scoped.has(key) ? frame : target;
      const value = owner[key];
      return typeof value === 'function' ? value.bind(owner) : value;
    },
  });
}

async function solveOn(page, log, captureScreenshot) {
  const top = await solveIn(page, null, log, captureScreenshot);
  if (top.status !== 'no_captcha') return top;
  for (const frame of await framesWithWidget(page)) {
    const res = await solveIn(page, frame, log, captureScreenshot);
    if (res.status !== 'no_captcha') return { ...res, frame: frame.url().split('?')[0].slice(0, 200) };
  }
  return top;
}

async function solveIn(page, frame, log, captureScreenshot) {
  // Loaded on first use: a broken engine install fails this route, not the server.
  const { CaptchaKrakenSolver } = require('captchakraken');
  const solver = new CaptchaKrakenSolver({
    detectionTimeoutMs: DETECTION_TIMEOUT_MS,
    overallSolveTimeoutMs: SOLVE_BUDGET_MS,
    maxSolveLoops: MAX_SOLVE_LOOPS,
  });
  // A round is one pass of the driver's loop on a widget: ticking a checkbox
  // is one, each board answered is one. The driver reports them only inside
  // its error text, so the round method is counted here.
  let rounds = 0;
  // Every capture through the guarded viewport screenshot (the vault mask): the driver's element
  // screenshot (its fallback for a widget bigger than the viewport) would bypass the guards, so a
  // widget that does not fit is a failed round, never an unguarded photo.
  const { cropPng } = require('captchakraken/dist/png.js');
  solver.shot = async function guardedShot(el, p, timeout = 2500, animations = 'disabled') {
    const view = this.page.viewportSize() ?? await this.page.evaluate(() => ({ width: window.innerWidth, height: window.innerHeight }));
    const rect = await this.rectInView(el, view);
    if (!rect) throw new Error('the captcha widget does not fit the viewport: no guarded screenshot of it');
    fs.writeFileSync(p, cropPng(await this.page.screenshot({ timeout, animations }), rect, view.width));
  };
  const solveSingle = solver.solveSingle;
  solver.solveSingle = function countedRound(...args) {
    rounds += 1;
    return solveSingle.apply(this, args);
  };
  const started = Date.now();
  const outcome = (status, extra = {}) => ({
    status, vendor: solver.solveVendor || null, rounds, durationMs: Date.now() - started, ...extra,
  });
  try {
    const result = await solver.solve(driverView(page, frame, captureScreenshot));
    if (result?.isSolved) return outcome('solved');
    return outcome('failed', { reason: 'the solver ended without the widget accepting an answer' });
  } catch (err) {
    const reason = firstLine(err);
    log('info', 'captcha solve ended', { reason });
    return outcome(reason.startsWith(NO_WIDGET) ? 'no_captcha' : 'failed', { reason });
  }
}

export async function register(app, ctx) {
  const {
    sessions, log, normalizeUserId, withUserLimit,
    findTab, withTabLock, destroyTimedOutTab, tabNotFoundResponse, handleRouteError,
  } = ctx;
  // The guarded screenshot (capture-guard.patch); without it the driver gets no screenshot at all.
  const captureScreenshot = ctx.captureScreenshot || (async () => { throw new Error('no capture guard on this server'); });

  app.post('/tabs/:tabId/solve-captcha', async (req, res) => {
    const { tabId } = req.params;
    try {
      const userId = req.body?.userId;
      if (!userId) return res.status(400).json({ error: 'userId is required' });
      // Without it the engine falls back to a credentials file or the
      // hosted API; this server only ever uses its configured endpoint.
      if (!process.env.VLLM_BASE_URL) {
        return res.status(503).json({ error: 'No captcha model is configured on this browser server (VLLM_BASE_URL).' });
      }

      const session = sessions.get(normalizeUserId(userId));
      const found = session && findTab(session, tabId);
      if (!found) return tabNotFoundResponse(res, tabId);
      session.lastAccess = Date.now();
      const { tabState } = found;
      tabState.toolCalls++;

      const result = await withUserLimit(userId, () => withTabLock(
        tabId,
        () => solveOn(tabState.page, log, captureScreenshot),
        SOLVE_TIMEOUT_MS,
        () => destroyTimedOutTab(session, tabId, 'captcha_solve_timeout', userId),
      ));
      session.lastAccess = Date.now();
      log('info', 'captcha solve', { reqId: req.reqId, tabId, ...result });
      res.json({ ok: true, ...result, url: tabState.page.isClosed() ? null : tabState.page.url() });
    } catch (err) {
      log('error', 'captcha solve failed', { reqId: req.reqId, tabId, error: err.message });
      handleRouteError(err, req, res);
    }
  });

  app.post('/tabs/:tabId/click-at', async (req, res) => {
    const { tabId } = req.params;
    try {
      const { userId } = req.body || {};
      const x = Number(req.body?.x), y = Number(req.body?.y);
      if (!userId) return res.status(400).json({ error: 'userId is required' });
      if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || y < 0 || x > 20000 || y > 20000) {
        return res.status(400).json({ error: 'x and y: viewport CSS pixels' });
      }
      const session = sessions.get(normalizeUserId(userId));
      const found = session && findTab(session, tabId);
      if (!found) return tabNotFoundResponse(res, tabId);
      session.lastAccess = Date.now();
      const { tabState } = found;
      tabState.toolCalls++;
      await withUserLimit(userId, () => withTabLock(
        tabId,
        async () => {
          const page = tabState.page;
          const [w, h] = await page.evaluate('[window.innerWidth, window.innerHeight]');
          if (x >= w || y >= h) throw Object.assign(new Error(`(${x}, ${y}) is outside the ${w}x${h} viewport`), { statusCode: 400 });
          await page.mouse.move(x, y, { steps: 4 });
          await page.mouse.click(x, y, { delay: 40 });
          // The page's refs may be stale now, like after any click.
          tabState.lastSnapshot = null;
        },
        30000,
        () => destroyTimedOutTab(session, tabId, 'operation_timeout', userId),
      ));
      log('info', 'click at', { reqId: req.reqId, tabId, x: Math.round(x), y: Math.round(y) });
      res.json({ ok: true, url: tabState.page.isClosed() ? null : tabState.page.url() });
    } catch (err) {
      if (err?.statusCode === 400) return res.status(400).json({ error: err.message });
      log('error', 'click at failed', { reqId: req.reqId, tabId, error: err.message });
      handleRouteError(err, req, res);
    }
  });
}
