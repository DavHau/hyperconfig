# TeamClaude subscription OAuth recovery (som)

**Trigger:** The 09:00 Bangkok fleet digest shows “TeamClaude OAuth needs
attention.” The gateway either reports a refresh-token deadline
within 48 hours (including overdue) or has confirmed that Claude rejected the
credential. Only enabled, normal Claude subscription OAuth accounts qualify;
this is not an alert on `fallback`, an API key, Codex, or long-lived tokens.
There is no fleet login timer: an unknown deadline does not trigger a date
warning. The recorded deadline is what TeamClaude knows; TeamClaude 1.1.30
can record its own sign-in estimate when the provider does not give a date.

A failed quota poll alone (including a timeout, 429, or generic error) is not
proof that a re-login is needed. Conversely, a confirmed rejection remains
valid while fresh gateway status still reports it, even if dead-token skips
have stopped the account's quota probes. The warning is held for 15 minutes
and goes to the normal digest, not a real-time page.

## 1. Check the named account

The digest omits account names. In signed-in Grafana on `stats.davhau.com`, go
to **Alerting → Alert rules → TeamClaude OAuth needs attention** and inspect
the warning instance's `account` label (or its alert history if resolved).
Use a private, unrecorded interactive SSH terminal on `som` as an authorized
root operator. Use one account per session and replace the example with the
**exact** label, including any org suffix:

```sh
ssh -t som.d
teamclaude-oauth status 'name@example.com'
```

Note the UTC `lastProbedAt`, `refreshDeadline`, and `weeklyUtilization` /
`weeklyReset` returned before recovery. If `reloginRequired` is false and the
recorded deadline is no longer due within 48 hours, stop. The digest can
include issues that fired and resolved. If `disabled` is true, stop. If the
status command fails or the alert says “TeamClaude OAuth monitoring blind,”
follow the telemetry section below, not the sign-in steps.

If `status` is `error` but `reloginRequired` is false, ask the gateway owner
to check for a non-authentication refusal (for example an account hold).
Re-login does not lift a provider hold.

## 2. Re-login manually, without adding or rebinding an account

Run this only in an approved gateway maintenance window, after the operator
has approved this specific account and the owner is ready to authenticate.
There is a brief gateway stop/start **after** browser sign-in and identity
verification, not while waiting for the browser. Do not run another TeamClaude
config writer (including native CLI edits), deploy, or manage the unit in
parallel. An agent can surface the alert and check status afterwards; it must
not do an unattended login.

```sh
teamclaude-oauth re-login 'name@example.com'
```

1. Open the authorization URL printed locally by the command. The sign-in
   is the normal TeamClaude browser OAuth paste flow (`claude.ai`); use a
   fresh/private browser profile, and select the exact Claude email and the
   existing subscription organization. If the browser shows another account
   or organization, or you cannot tell which one it shows, cancel with Ctrl-C.
2. Complete any provider sign-in or verification in the browser. Paste the
   authorization code from the success page **directly into the hidden terminal
   prompt**, not a shell command, chat, ticket, or recorded terminal. Do not
   share the authorization URL, callback URL, OTPs, cookies or tokens.
3. The helper verifies the upstream profile's email, account UUID and
   organization UUID against the one existing enrolled row. It then stops
   the gateway, takes TeamClaude's config lock, checks that the gateway is
   stopped and compares the row again before committing. A busy lock or a
   refresh that saved after the browser flow began prevents the write. It
   refuses missing, ambiguous, changed or mismatched identity and never
   creates a row. Do **not** substitute upstream `teamclaude login --name`, import a token, or
   override the check. Escalate mismatches, unsupported enrollment types, or
   unavailable profile lookup to the gateway owner. This local-only helper
   does not operate on a gateway configured to sync credentials off-host.
   Do not edit credentials, caps, providers or `fallback` to clear the alert.
4. The helper attempts to start the gateway even if the write fails or is
   interrupted. Expect “Updated credentials; gateway start returned at …”.
   If startup failed, or the session died during the stop/start, don't sign
   in again. Check `systemctl is-active teamclaude.service`; once the helper
   has exited, restore the unit if needed with `systemctl start
   teamclaude.service` in the same window. If it still fails, escalate to
   the gateway owner; don't force-unlock or roll back credentials. Note the
   UTC time reported by the helper (or after the successful manual start).
   If the helper refused a changed row, re-check whether recovery is still
   needed before starting another session.

The account owner can receive their own provider sign-in email. This runbook
sets up no forwarding or mail access. If Dave separately chooses forwarding,
limit it to the provider's sign-in messages for the intended account and the
specific recovery; require his explicit approval before an agent assists and
remove temporary forwarding afterwards. Do not give an agent standing mailbox
access or put OTPs, links or tokens in chat or logs.

## 3. Verify recovery without a test prompt

Allow up to two of som's usual five-minute quota-poll cycles. Repeat the same
`teamclaude-oauth status '<exact name>'`. Require all of the following for the
**same** account:

- `reloginRequired: false`; no current account authentication error.
- `quotaProbe: "ok"`, `probeStartedAt` is after the restart, and
  `lastProbedAt` is newer than the pre-login reading (if there was one). A
  cached weekly bar is not verification.
- `weeklyUtilization` and `weeklyReset` are both non-null (zero utilization
  is valid). The helper exposes them only as a complete observation from
  that same probe; successful empty or partial reads are not recovery.
  The new refresh deadline, if known, must no longer be inside the
  48-hour window.

The exporter should publish the new state within its next five-minute run,
plus the Alloy scrape and Grafana evaluation. Check that the account warning
clears there; a recent resolution may still appear once in the digest. If the
probe does not move or the weekly reading is missing, recovery is not verified:
check service and probe health with the gateway owner. Do not reduce caps, send
an inference request, or repeatedly re-login to force a green check.

## Monitoring blind, rollout, and local checks

“TeamClaude OAuth monitoring blind” means edi lacks a fresh successful status
snapshot from som (20-minute maximum age, then 30-minute hold). It says
nothing about credentials. On som, check `teamclaude.service`,
`teamclaude-metrics.timer`, `teamclaude-metrics.service`, `alloy.service` and
whether `teamclaude-oauth status '<exact name>'` succeeds. On edi, check Mimir
and Grafana for `teamclaude_oauth_status_collected_timestamp_seconds{instance="som"}`.
Use the gauge's **value**, not its scrape timestamp; Alloy can re-scrape an
old file. Check host clock skew if the value is in the future. Do not dump
raw status/config, API headers or OAuth logs to a ticket/chat. Recover telemetry
before diagnosing account auth.

Roll out edi's rules first and som's exporter/helper last in the same change
window (within the 30-minute missing-telemetry hold). If rollout has to pause,
existing usage metrics are independent of the new account rules. Verify a
fresh som snapshot and the two digest-level rules in Grafana, then compare
any firing account(s) with read-only `teamclaude-oauth status`; no test message
or re-login is needed to prove alert wiring. Confirm warning routing in the
normal digest (or a Viewer-only dry run on edi, which sends nothing):

```sh
systemd-run --pipe --wait -p DynamicUser=yes \
  -p LoadCredential=grafana-token:/var/lib/fleet-alert-digest-token/grafana-token \
  /run/current-system/sw/bin/fleet-alert-digest --dry-run
```

From the repository, offline fixtures use fake identities and loopback HTTP;
there is no OAuth or inference call:

```sh
nix build -L --no-link --max-jobs 2 --cores 8 'path:.#checks.x86_64-linux.monitoring-teamclaude'
nix eval --raw 'path:.#nixosConfigurations.som.config.system.build.toplevel.drvPath'
nix eval --raw 'path:.#nixosConfigurations.edi.config.system.build.toplevel.drvPath'
```
