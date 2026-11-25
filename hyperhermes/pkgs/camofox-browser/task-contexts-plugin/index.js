/**
 * Task-contexts plugin: bounds the browser contexts hermes opens per task.
 *
 * hermes' camofox plugin (pkgs/hermes-camofox-plugin, task-contexts.patch)
 * gives each delegate_task child and cron run a context of its own, userId
 * `<profile userId>-task-<digest>`, and each task's residential context
 * `...-residential-<cc>`. The task deletes them, persisted state included,
 * when it ends (DELETE /sessions/:userId/storage_state). A task that dies
 * first (a restart, a crash) leaves them behind: the server closes the live
 * context after SESSION_TIMEOUT_MS idle like any other, and the persistence
 * plugin saves its storage on close. This plugin removes such saved state of
 * task and residential contexts once untouched for TASK_CONTEXT_TTL_MS
 * (default a day), at start and every hour. The profile's own persistent
 * context (its logins) is never touched.
 */

import fs from 'node:fs/promises';
import path from 'node:path';

// hermes' own shapes only (pkgs/hermes-camofox-plugin task-contexts.patch).
const OWNED = /^hermes_[0-9a-f]{10}-task-[0-9a-f]{12}(-residential-[a-z]{2})?$|^hermes_[0-9a-f]{10}-residential-[a-z]{2}$/;
const HOUR = 60 * 60 * 1000;

export async function register(app, ctx) {
  const { log, sessions } = ctx;
  const profileDir = process.env.CAMOFOX_PROFILE_DIR;
  const ttl = parseInt(process.env.TASK_CONTEXT_TTL_MS, 10) || 24 * HOUR;
  if (!profileDir) return;

  async function sweep() {
    let entries = [];
    try {
      entries = await fs.readdir(profileDir, { withFileTypes: true });
    } catch (err) {
      if (err?.code !== 'ENOENT') log('warn', 'task-contexts: cannot list profiles', { error: err.message });
      return;
    }
    let removed = 0;
    for (const e of entries) {
      if (!e.isDirectory()) continue;
      const dir = path.join(profileDir, e.name);
      try {
        const meta = JSON.parse(await fs.readFile(path.join(dir, 'meta.json'), 'utf8'));
        const userId = String(meta?.userId || '');
        if (!OWNED.test(userId) || sessions.has(userId)) continue;
        const { mtimeMs } = await fs.stat(path.join(dir, 'meta.json'));
        if (Date.now() - mtimeMs < ttl) continue;
        await fs.rm(dir, { recursive: true, force: true });
        removed++;
      } catch {
        // no meta.json (being written, or not a profile): leave it
      }
    }
    if (removed) log('info', 'task-contexts: removed stale task profiles', { removed });
  }

  await sweep();
  setInterval(() => { sweep().catch(() => {}); }, HOUR).unref();
}
