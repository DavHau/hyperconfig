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
 * rounds, durationMs }; 503 when no model endpoint is configured.
 */

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

async function solveOn(page, log) {
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
    const result = await solver.solve(page);
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
        () => solveOn(tabState.page, log),
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
}
