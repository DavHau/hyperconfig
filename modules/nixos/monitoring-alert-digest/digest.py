"""fleet-alert-digest: one daily Telegram message with the fleet's warnings.

Only critical alerts page in real time (../monitoring-alerts.nix mutes
the severity=warning route); this collects the warnings from Grafana
instead: every warning series that is firing now, plus every one that
fired during the last N hours (default 24) and has resolved since.

Sources, both read-only on the local Grafana:
  - /api/prometheus/grafana/api/v1/alerts: current state of every alert
    instance (firing = "Alerting" or "Recovering", i.e. keep_firing_for;
    also "Error"/"NoData": a warning rule whose query fails carries the
    rule's labels, so its DatasourceError is muted like the warning and
    shows up here instead).
  - /api/annotations?type=alert: the state history, for warnings that
    fired and resolved within the window.

Modes:
  (default)   send the digest; nothing is sent when there are no warnings
  --dry-run   print the message it would send, send nothing
  --json      print the entries as JSON (alert, host, since, state, ...),
              send nothing; for other reports (a morning brief)
  --notify-failure
              send only "alert digest failed" (the units' OnFailure=),
              naming the failed unit from $MONITOR_UNIT

Credentials come from systemd credentials ($CREDENTIALS_DIRECTORY):
grafana-token (a Viewer service account's, from ./provision_token.py),
telegram-bot-token, telegram-chat-id. Neither token is ever printed, not
even in errors.

Sending: an error before the request went out (DNS, connect, TLS) exits
1 so systemd retries; a 4xx (refused, not delivered) too. Once the
request is out, a timeout, a broken answer or a 5xx exits
EXIT_MAYBE_SENT (3), listed in the unit's RestartPreventExitStatus=: no
retry (it would send the message twice), but the unit fails and
--notify-failure says the digest may not have arrived.
"""

import argparse
import html
import http.client
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone, timedelta

GRAFANA = os.environ.get("DIGEST_GRAFANA_URL", "http://127.0.0.1:3000")
SEVERITY = "warning"
# Telegram caps a message at 4096 characters.
MAX_LEN = 4000
# Labels that say *which* series of a rule it is, in display order.
DETAIL_LABELS = ("name", "mountpoint", "pool", "dataset", "zpool", "device")
# Labels that only describe the rule or the scrape, not the series.
IGNORED_LABELS = {"grafana_folder", "job", "__alert_rule_uid__",
                  "__name__", "ref_id", "datasource_uid"}
TZ = timezone(timedelta(hours=7), "+07")


def credential(name):
    d = os.environ.get("CREDENTIALS_DIRECTORY")
    if not d:
        sys.exit(f"fleet-alert-digest: no credential {name} "
                 "(run under systemd with LoadCredential)")
    with open(os.path.join(d, name)) as f:
        return f.read().strip()


def grafana_get(path, params=None):
    url = GRAFANA + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {credential('grafana-token')}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def series_key(labels):
    """Identity of an alert instance: its labels minus the rule's own."""
    return tuple(sorted((k, v) for k, v in labels.items()
                        if k not in IGNORED_LABELS))


def tags_to_labels(tags):
    labels = {}
    for t in tags or []:
        k, sep, v = t.partition(":")
        if sep:
            labels[k] = v
    return labels


# "Alerting (Error)" etc. count by their first word. Error/NoData are
# the rule's exec-error/no-data states: a broken query is worth a line.
FIRING = ("Alerting", "Recovering", "Error", "NoData")


def is_firing(state):
    s = (state or "").split(" ")[0]
    return s in FIRING


def is_error(state):
    # "Error", "NoData", "Alerting (Error)"; never a Normal one, those
    # are not firing in the first place.
    s = state or ""
    return s.split(" ")[0] in ("Error", "NoData") or "(Error)" in s


def iso(ts):
    return ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(s):
    # Grafana: "2026-11-12T17:01:20Z" or with fractional seconds/offset.
    s = s.replace("Z", "+00:00")
    if "." in s:
        head, rest = s.split(".", 1)
        n = 0
        while n < len(rest) and rest[n].isdigit():
            n += 1
        frac, off = rest[:n], rest[n:]
        s = head + "." + frac[:6] + off
    return datetime.fromisoformat(s)


def collect(alerts, annotations, now, hours=24):
    """Warnings firing now or fired within `hours` before `now`.

    alerts: the `data.alerts` list of Grafana's prometheus-style alerts
    API; annotations: the list from /api/annotations?type=alert; now: an
    aware datetime. Returns a list of dicts sorted by host, alert, since.
    """
    start = now - timedelta(hours=hours)
    entries = {}

    for a in alerts:
        labels = a.get("labels") or {}
        if labels.get("severity") != SEVERITY or not is_firing(a.get("state")):
            continue
        key = series_key(labels)
        since = parse_time(a["activeAt"]) if a.get("activeAt") else None
        summary = (a.get("annotations") or {}).get("summary", "")
        if is_error(a.get("state")):
            summary = f"rule query failed ({a.get('state')}), check the rule in Grafana"
        entries[key] = {
            "labels": labels,
            "state": "firing",
            "since": since,
            "fired": 0,
            "summary": summary,
        }

    start_ms = start.timestamp() * 1000
    for ann in sorted(annotations, key=lambda x: x.get("time", 0)):
        labels = tags_to_labels(ann.get("tags"))
        if labels.get("severity") != SEVERITY:
            continue
        if ann.get("time", 0) < start_ms:
            continue
        # A transition *into* firing; Alerting -> Recovering is not new.
        if not is_firing(ann.get("newState")) or is_firing(ann.get("prevState")):
            continue
        labels.setdefault("alertname", ann.get("alertName", ""))
        key = series_key(labels)
        at = datetime.fromtimestamp(ann["time"] / 1000, timezone.utc)
        e = entries.get(key)
        if e is None:
            e = entries[key] = {
                "labels": labels,
                "state": "resolved",
                "since": at,
                "fired": 0,
                "summary": "",
            }
        e["fired"] += 1
        if e["since"] is None or (e["state"] == "resolved" and at < e["since"]):
            e["since"] = at

    out = []
    for e in entries.values():
        labels = e["labels"]
        detail = ", ".join(f"{k}={labels[k]}" for k in DETAIL_LABELS
                           if labels.get(k))
        out.append({
            "alert": labels.get("alertname", ""),
            "host": labels.get("instance", ""),
            "detail": detail,
            "state": e["state"],
            "since": iso(e["since"]) if e["since"] else None,
            "fired": e["fired"],
            "summary": e["summary"],
        })
    out.sort(key=lambda x: (x["host"], x["alert"], x["detail"], x["since"] or ""))
    return out


def local(since):
    if not since:
        return "?"
    return parse_time(since).astimezone(TZ).strftime("%m-%d %H:%M")


def render(entries, hours=24):
    """The Telegram message (HTML parse mode), or None without warnings."""
    if not entries:
        return None
    firing = [e for e in entries if e["state"] == "firing"]
    resolved = [e for e in entries if e["state"] == "resolved"]
    lines = [f"<b>Fleet warnings, last {hours} h</b>: "
             f"{len(firing)} firing, {len(resolved)} resolved"]

    def line(e):
        what = html.escape(e["alert"])
        where = html.escape(e["host"] or "-")
        detail = f" ({html.escape(e['detail'])})" if e["detail"] else ""
        times = f", fired {e['fired']}×" if e["fired"] > 1 else ""
        text = f"• {where}: {what}{detail}, since {local(e['since'])}{times}"
        if e["summary"]:
            text += f"\n  {html.escape(e['summary'])}"
        return text

    for title, group in (("Firing", firing), ("Fired and resolved", resolved)):
        if group:
            lines.append("")
            lines.append(f"<b>{title}</b>")
            lines.extend(line(e) for e in group)

    msg = "\n".join(lines)
    if len(msg) <= MAX_LEN:
        return msg
    # Cut at a line boundary and say how much is missing.
    kept, size = [], 0
    for ln in lines:
        if size + len(ln) + 1 > MAX_LEN - 60:
            break
        kept.append(ln)
        size += len(ln) + 1
    rest = sum(1 for ln in lines[len(kept):] if ln.startswith("•"))
    # No section header (or blank line) left dangling above the cut.
    while len(kept) > 1 and (not kept[-1] or kept[-1].startswith("<b>")):
        kept.pop()
    kept.append(f"… and {rest} more (Grafana: Alerting > Alert rules)")
    return "\n".join(kept)


TELEGRAM_HOST = "api.telegram.org"
# Sent, but no good answer: no retry (RestartPreventExitStatus=), but page.
EXIT_MAYBE_SENT = 3


def maybe_sent(why):
    print(f"fleet-alert-digest: sent, but {why}; not retrying, it may "
          "have arrived", file=sys.stderr)
    sys.exit(EXIT_MAYBE_SENT)


def send(text):
    """POST one message. Exits 1 when it surely was not sent (retry is
    safe), EXIT_MAYBE_SENT when it went out without a good answer."""
    token = credential("telegram-bot-token")
    chat = credential("telegram-chat-id")
    body = urllib.parse.urlencode({
        "chat_id": chat,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": "true",
    }).encode()
    conn = http.client.HTTPSConnection(TELEGRAM_HOST, timeout=30)
    # Errors are reported by type and errno only: the URL holds the token.
    try:
        conn.connect()
        conn.request("POST", f"/bot{token}/sendMessage", body=body, headers={
            "Content-Type": "application/x-www-form-urlencoded"})
    except (OSError, http.client.HTTPException) as e:
        conn.close()
        sys.exit(f"fleet-alert-digest: Telegram unreachable, not sent: "
                 f"{type(e).__name__} {getattr(e, 'errno', '') or ''}".rstrip())
    # The request is out: from here on no retry (it would send the
    # message a second time), only EXIT_MAYBE_SENT.
    try:
        r = conn.getresponse()
        status = r.status
        detail = r.read().decode(errors="replace")[:300]
    except (OSError, http.client.HTTPException) as e:
        maybe_sent(f"no answer from Telegram ({type(e).__name__})")
    finally:
        conn.close()
    if status == 200:
        return True
    if 400 <= status < 500 and status != 408:
        # Telegram refused it (bad chat, bad HTML, flood limit): not sent.
        sys.exit(f"fleet-alert-digest: Telegram refused: HTTP {status} {detail}")
    maybe_sent(f"Telegram answered HTTP {status} {detail}")


def failure_message(env=None):
    """The --notify-failure line, from systemd's OnFailure= environment."""
    env = os.environ if env is None else env
    unit = env.get("MONITOR_UNIT") or "fleet-alert-digest.service"
    u = html.escape(unit)
    maybe = (env.get("MONITOR_EXIT_CODE"), env.get("MONITOR_EXIT_STATUS")) \
        == ("exited", str(EXIT_MAYBE_SENT))
    if unit == "fleet-alert-digest.service" and maybe:
        return ("<b>Fleet alert digest may not have arrived</b> on edi "
                "(Telegram error after sending). "
                f"journalctl -u {u}")
    return (f"<b>Fleet alert digest failed</b> on edi: {u} failed; "
            f"today's warnings may not be sent. journalctl -u {u}")


def main(argv=None):
    p = argparse.ArgumentParser(
        description="One daily Telegram message with the fleet's warnings.")
    p.add_argument("--hours", type=int, default=24)
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true",
                      help="print the message instead of sending it")
    mode.add_argument("--json", action="store_true",
                      help="print the entries as JSON, send nothing")
    mode.add_argument("--notify-failure", action="store_true",
                      help="send only a short 'alert digest failed' message")
    args = p.parse_args(argv)

    if args.notify_failure:
        send(failure_message())
        return

    now = datetime.now(timezone.utc)
    alerts = grafana_get("/api/prometheus/grafana/api/v1/alerts")
    alerts = (alerts.get("data") or {}).get("alerts") or []
    annotations = grafana_get("/api/annotations", {
        "type": "alert",
        "from": int((now - timedelta(hours=args.hours)).timestamp() * 1000),
        "to": int(time.time() * 1000),
        "limit": 10000,
    })
    entries = collect(alerts, annotations, now, args.hours)

    if args.json:
        json.dump(entries, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return
    msg = render(entries, args.hours)
    if msg is None:
        print("fleet-alert-digest: no warnings, nothing to send")
        return
    if args.dry_run:
        print(msg)
        return
    send(msg)
    print(f"fleet-alert-digest: sent {len(entries)} warnings")


if __name__ == "__main__":
    main()
