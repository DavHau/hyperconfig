# Hermes dashboard download links — deferred fixes

Status: root-caused 2026-07-21, fixes deliberately deferred.

## Symptom

Agent generates a file (e.g. `/var/lib/hermes/workspace/wildland_ch2.pdf`);
dashboard/desktop renders a broken "[Open wildland_ch2.pdf)" link with
"Couldn't fetch wildland_ch2.pdf) from the gateway (missing, unreadable, or
too large)." — or an earlier variant resolving to
`file:///nix/store/…-hermes-desktop-…/dist/index.html`.

## Root cause (two faults, backend is innocent)

The delivery contract is a bare `MEDIA:/absolute/path` token on its own line
(system prompt, `agent/prompt_builder.py:753-761`). The SPA rewrites it into a
download chip that fetches `GET /api/fs/read-data-url?path=…`
(`hermes_cli/web_server.py:2209`, 16 MiB cap — the 3.9 KB file was fine).

1. **Model behavior:** the agent emitted markdown-link syntax
   `[Open …](MEDIA:/path)` instead of the bare token.
2. **Desktop frontend bug:** `MEDIA_TAG_RE` in
   `apps/desktop/src/lib/chat-messages.ts` (~L105) uses a greedy `\S+` with no
   trailing-delimiter guard, so the markdown link's closing `)` is swallowed
   INTO the path → backend correctly 404s on `…/wildland_ch2.pdf)`. The
   backend's own extractor has exactly the right lookahead
   (`gateway/platforms/base.py:1468`,
   `(?=[\s`"',;:)\]}]|$)`) — never ported to the desktop SPA.

Not involved: session cwd, size caps, permissions, our virtiofs/WAL changes.

## Fixes, ranked

1. **Prompt/skill guidance** (minutes, zero risk): teach the agent — "to offer
   a download in the dashboard, emit `MEDIA:/absolute/path` on its own line;
   never wrap it in markdown link syntax." Fixes the incident outright.
2. **Frontend regex patch** (~1 h): port the backend lookahead into
   `MEDIA_TAG_RE`/`MEDIA_LINE_RE` (or strip trailing `)].,;:` in
   `unquoteMediaPath()`). Lives in the minified hermes-desktop SPA — requires
   rebuilding the desktop package, not the Python wheel.
3. **Upstream PR** (best long-term): same regex fix + test in
   `chat-messages.test.ts`. No existing upstream issue as of 2026-07-21
   (nearest: #34632, #35474 — both backend-extractor bugs).

Full investigation: DashboardFetchScout report, 2026-07-21 session.
