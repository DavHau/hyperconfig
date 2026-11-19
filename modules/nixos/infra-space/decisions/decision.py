"""decision: the fleet's decision registry (../decisions.nix says where it
runs and who calls it).

One JSON file per decision in <dir>/items/D<n>.json, every change also a
line in <dir>/log.jsonl, writers serialised by flock on <dir>/.lock.
Jobs that cannot run this CLI append JSON lines to <dir>/inbox.jsonl;
every command ingests that file first (bounded: see INBOX_MAX_BYTES), so
nothing waits for a timer. Writers must append each line with ONE write
on an O_APPEND descriptor (`>>` in a shell, open(..., "a") + a single
write in Python): ingest renames the file to inbox.jsonl.ingesting
before reading it, so a line appended meanwhile usually lands in a fresh
inbox.jsonl (the next ingest's) instead of being cut off by a truncate.
Best effort, not a guarantee: a writer that still holds the old file
after ingest stopped waiting for it (see ingest_work) loses its line.
A crash mid-ingest leaves the .ingesting file, taken in again first:
its decisions are refiled by title, its notices deduplicated by content
(source + text) against the unsent ones, so nothing is doubled.
<dir>/notices.jsonl holds one-off lines for the next morning brief (e.g.
a service the CVE watch took down).

Bounds: at most MAX_PENDING open+answered decisions (more are refused,
inbox lines to inbox.rejected.jsonl), log.jsonl rotated at LOG_MAX_BYTES
(one old generation, log.jsonl.1), a bad inbox line of any kind is
rejected alone and never stops the rest.

The bar (Dave): only a question that needs something only he has is
asked (his preference, money, identity, irreversible loss, another
person's access, a noticeable change, a conflict with what he said, a
physical step, a secret or access only he has; the last three name the
step and how it was verified that no agent path can do it). Work items
(a review, a rebase, a conflict, a parked or unlanded change, a vars
step) are refused by `add` (WORK_ITEM) and go to `work` / `handback`:
status work, never asked, a session dispatches and closes them. An
inbox line cannot waive that check (`not_work_item` is CLI only).
`add` requires `--needs-dave "<criterion>: <why>"`, criterion one of
NEEDS_DAVE; without it the caller decides itself and records that
with `decided` (status answered, answer.auto: visible in the brief's
"decided for you" line, never asked). An inbox line (untrusted: jobs
read CVE feeds, changelogs) without needs_dave is decided only when it
is not urgent, has a recommendation and no malformed needs_dave field;
then its recommendation is the answer, by "inbox", marked unvetted (a
session re-judges it before acting; its `chose` is ignored). Any other
such line stays open without needs_dave ("unsorted", a line in the
brief) until the curator sorts it: a missing or broken classification
falls back to asking, never to deciding. `decide-default` turns an
open question that does not clear the bar into a decided record, and
vets an unvetted answer (the curator's and /decisions' tool).

The store's path is fixed at build (@DIR@): no flag or variable points
the CLI elsewhere; the unit tests call main(argv, store_dir=...).

Run `decision --help` and `decision <command> --help`.
"""

import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import time
import unicodedata
from datetime import datetime, timedelta, timezone

DIR = "@DIR@"
URGENCIES = ["urgent", "normal", "low"]
# work: handed back to the agents (a work item filed as a question: a
# review, a rebase, a step a fleet root can run); never shown to Dave,
# closed by the session that did it
STATUSES = ["open", "answered", "work", "obsolete", "done"]
# Dave's zone (no DST): only for what he reads.
BKK = timezone(timedelta(hours=7))
ID_RE = re.compile(r"D[0-9]{1,6}")  # always .fullmatch
# Caps: a job filing junk must not fill the disk or the brief.
CAP = {"title": 160, "short": 600, "long": 4000}
INBOX_MAX_BYTES = 1 << 20
INBOX_MAX_LINE = 64 << 10
MAX_ITEMS_PER_INGEST = 50
MAX_OPTIONS = 8
MAX_LINKS = 20
MAX_PENDING = 200
LOG_MAX_BYTES = 4 << 20
# the brief: notices shown per morning (the rest wait for the next one)
BRIEF_NOTICES = 6
# dates outside this are junk (and 0001-01-01 / 9999-12-31 overflow on
# a time-zone shift)
YEARS = (2000, 2200)
# The bar for asking Dave at all: the only reasons a question reaches him.
NEEDS_DAVE = {
    "money": "spends his money or signs up in his name",
    "identity": "exposes his identity or private data to a third party",
    "irreversible": "irreversibly destroys data he may care about, no backup or undo",
    "access": "gives another person access",
    "noticeable": "a change he will notice in daily use that he did not ask for",
    "conflict": "a real conflict with something he said",
    "preference": "his personal taste on something he lives with (not which of several sane technical options)",
    "physical": "a physical step only he can do (plug in, power, be on site)",
    "secret-only-dave": "a secret only he knows (not one in clan vars or on a fleet machine)",
    "access-verified": "a step only his access can do, verified that no fleet root, clan vars or agent key path can",
}
# other spellings of a criterion
NEEDS_DAVE_ALIASES = {"secret": "secret-only-dave", "only-dave": "access-verified"}
# criteria that claim Dave must DO a step: they name the step and how it
# was verified that no agent path (root on a fleet machine, clan vars,
# the agent's own keys) can do it, or they are refused
NEEDS_STEP = {"physical", "secret-only-dave", "access-verified"}
# work items filed as questions (Dave): a review, a rebase, a conflict
# with main, a parked or unlanded change, a vars step are the agents'
# work; dispatch them, never ask him
WORK_ITEM = [
    ("a review", re.compile(
        r"\b(?:un|not\s+(?:yet\s+)?|never\s+(?:been\s+)?)reviewed\b|\b(?:to\s+be|been|being)\s+reviewed\b"
        r"|\b(?:awaiting|pending)\s+review\b|\breview\s+pending\b"
        r"|\breview(?:ed|s|ing)?\s+(?:of\s+)?(?:the\s+|this\s+|a\s+)?(?:diff|change|patch|commit|branch|stack|PR|code)s?\b"
        r"|\b(?:needs?|awaits?|waiting\s+(?:for|on)|before)\s+(?:an?\s+)?(?:independent\s+|fresh\s+|security\s+)?review\b", re.I)),
    ("a rebase", re.compile(r"\brebas(?:e|ed|es|ing)\b", re.I)),
    ("a conflict with other code", re.compile(
        r"\bconflicts?\s+(?:in\s+\d+\s+files\b|with\s+(?:the\s+)?(?:\S+\s+){0,3}(?:module|branch|commit|patch|stack)s?\b"
        r"|(?:with|on)\s+main\b)|\bmerge\s+conflicts?\b", re.I)),
    ("a parked change", re.compile(
        r"\bparked\s+(?:as|in|on|change|branch|work|patch|stack)\b"
        r"|\b(?:change|branch|work|patch|stack)\s+(?:is\s+|stays\s+)?parked\b"
        r"|\bpark(?:ing)?\s+(?:the\s+|this\s+|a\s+)?(?:\S+\s+){0,3}(?:change|branch|work|patch|stack)\b", re.I)),
    ("an unlanded change", re.compile(
        r"\bnot\s+(?:yet\s+)?(?:landed|merged)\b|\bun(?:landed|merged)\b|\b(?:behind|diverged\s+from)\s+main\b|\bland(?:ing)?\s+(?:the\s+|this\s+)?(?:change|branch|patch|stack)\b", re.I)),
    ("a vars step", re.compile(
        r"\bvars?\s+(?:step|generat\w*|regenerat\w*)\b|\bclan\s+vars\s+(?:generate|set|step)\b"
        r"|\b(?:re)?generat\w*\s+(?:the\s+|its\s+)?(?:\S+\s+){0,2}vars?\b", re.I)),
]
# an `access` reason that really claims "only Dave can run it" (the
# criterion means giving another person access; that claim is
# access-verified, with its step and verification)
ONLY_DAVE_CLAIM = re.compile(
    r"\bonly\s+(?:dave|he|him)\b\s+(?:can|could|runs?|has|does|knows)\b|\bonly\s+(?:dave|he)\s+from\b"
    r"|\bdave\s+(?:must|has\s+to|needs\s+to)\s+(?:run|do)\b|\bfrom\s+the\s+\w+\s+lan\b", re.I)
# the brief: example titles in the "decided for you" line
BRIEF_DECIDED_EXAMPLES = 2
CRITERIA = "; ".join(f"{k} ({v})" for k, v in NEEDS_DAVE.items())
DECIDE_YOURSELF = (
    "this does not clear the bar for asking Dave. Decide it yourself with common sense and record it:\n"
    "  decision decided --title '<what>' --chose '<what you chose>' --why '<one line>' --source <you>\n"
    f"Ask Dave only with --needs-dave '<criterion>: <why>', criterion one of: {CRITERIA}. "
    "physical, secret-only-dave and access-verified also need --step '<the concrete step>' and --verified '<how you checked that no "
    "fleet root, clan vars or agent key path can do it>'"
)
WORK_ITEM_HINT = (
    "this looks like a work item, not a decision for Dave ({what}: matched {match!r}). Reviews, rebases, "
    "conflicts, parked or unlanded changes and vars steps are the agents' job: dispatch it "
    "(fleet-change-delegation). An unattended job that cannot dispatch hands it back with\n"
    "  decision work --title '<what>' --step '<what an agent must do>' --source <you>\n"
    "If it really needs Dave anyway (the criterion holds on its own), add --not-work-item '<why only he can>'"
)


def work_item_match(*texts):
    """(what, matched text) of the first work-item pattern in texts, else None."""
    for t in texts:
        for what, rx in WORK_ITEM:
            m = rx.search(t or "")
            if m:
                return what, m.group(0)
    return None


class Fail(Exception):
    pass


def now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def parse_time(s):
    try:
        t = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
        if not YEARS[0] <= t.year <= YEARS[1]:
            return None
        if t.tzinfo is None:
            t = t.replace(tzinfo=BKK)
        t.astimezone(timezone.utc)
    except (ValueError, OverflowError, TypeError):
        return None
    return t


def clean(value, kind):
    if value is None:
        return ""
    if not isinstance(value, str):
        value = json.dumps(value) if isinstance(value, (dict, list)) else str(value)
    # no control characters but newlines and tabs, no format characters
    # (bidi overrides could display a title reversed)
    value = "".join(
        c for c in value if c in "\n\t" or (ord(c) >= 32 and ord(c) != 127 and unicodedata.category(c) != "Cf")
    )
    value = value.strip()
    if kind == "title":
        value = " ".join(value.split())
    limit = CAP[kind]
    return value if len(value) <= limit else value[: limit - 1] + "…"


AS_OF = re.compile(r"\s*\(as of [^()]{1,40}\)")


def undated(t):
    """t without its `(as of <date>)` stamps (a refile's day alone is no news)."""
    return AS_OF.sub("", t)


def norm_title(t):
    return re.sub(r"[^a-z0-9]+", " ", t.casefold()).strip()


def parse_options(raw):
    """Options as [{key, text}]; accepts strings ("a) x", "a: x", "x") or dicts."""
    if raw is None:
        return []
    if isinstance(raw, (str, dict)):
        raw = [raw]
    if not isinstance(raw, list):
        raise Fail("options must be a list")
    out = []
    for i, o in enumerate(raw[:MAX_OPTIONS]):
        default_key = "abcdefgh"[i]
        if isinstance(o, dict):
            key = clean(o.get("key") or o.get("id") or default_key, "title")[:12]
            text = clean(o.get("text") or o.get("label") or o.get("option") or "", "short")
        else:
            m = re.match(r"^\s*([A-Za-z0-9]{1,3})\s*[).:]\s+(.*)$", str(o), re.S)
            key, text = (m.group(1), m.group(2)) if m else (default_key, o)
            text = clean(text, "short")
        if text:
            out.append({"key": key.lower(), "text": text})
    keys = [o["key"] for o in out]
    if len(set(keys)) != len(keys):
        for i, o in enumerate(out):
            o["key"] = "abcdefgh"[i]
    return out


def parse_needs_dave(raw, why=None, step=None, verified=None):
    """{criterion, why[, step, verified]} from a criterion plus `why`,
    "<criterion>: <why>" or a dict; None when it does not name a
    criterion of NEEDS_DAVE with a reason, when a step criterion
    (NEEDS_STEP) lacks its step or verification, or when an `access`
    reason claims only Dave can run something (that is only-dave, with
    its step and verification)."""
    if isinstance(raw, dict):
        crit, why = raw.get("criterion"), raw.get("why")
        step, verified = raw.get("step", step), raw.get("verified", verified)
    elif isinstance(raw, str):
        crit = raw
        if not why and ":" in raw:
            crit, _, why = raw.partition(":")
    else:
        return None
    crit = str(crit or "").strip().lower()
    crit = NEEDS_DAVE_ALIASES.get(crit, crit)
    why = clean(why, "short")
    if crit not in NEEDS_DAVE or not why:
        return None
    if crit == "access" and ONLY_DAVE_CLAIM.search(why):
        return None
    out = {"criterion": crit, "why": why}
    if crit in NEEDS_STEP:
        step, verified = clean(step, "short"), clean(verified, "short")
        if not step or not verified:
            return None
        out.update(step=step, verified=verified)
    return out


def needs_dave_error(raw, why=None, step=None, verified=None):
    """Why parse_needs_dave refused (for the CLI's message)."""
    crit = str((raw.get("criterion") if isinstance(raw, dict) else (raw or "").partition(":")[0]) or "").strip().lower()
    crit = NEEDS_DAVE_ALIASES.get(crit, crit)
    reason = why if why else (raw.get("why") if isinstance(raw, dict) else (raw or "").partition(":")[2])
    if crit == "access" and ONLY_DAVE_CLAIM.search(reason or ""):
        return ("'access' means giving another person access. A step only Dave can run is 'access-verified' "
                "with --step '<the concrete step>' and --verified '<how you checked no fleet root, clan vars "
                "or agent key path can do it>'; most such steps turn out to be the agents' own work")
    if crit in NEEDS_STEP:
        return (f"'{crit}' needs --step '<the concrete step Dave must do>' and --verified '<how you checked "
                "that no fleet root, clan vars or agent key path can do it>'")
    return DECIDE_YOURSELF


def parse_links(raw):
    if raw is None:
        return []
    if isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, list):
        raise Fail("links must be a list")
    return [clean(x, "short") for x in raw[:MAX_LINKS] if clean(x, "short")]


class Store:
    def __init__(self, path):
        self.dir = path
        self.items = os.path.join(path, "items")
        self.lockf = None

    def __enter__(self):
        if not os.path.isdir(self.dir):
            raise Fail(f"no registry at {self.dir}")
        os.makedirs(self.items, mode=0o700, exist_ok=True)
        self.lockf = open(os.path.join(self.dir, ".lock"), "a")
        fcntl.flock(self.lockf, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        if self.lockf:
            self.lockf.close()

    def path(self, did):
        if not isinstance(did, str) or not ID_RE.fullmatch(did):
            raise Fail(f"not a decision id: {did!r}")
        return os.path.join(self.items, did + ".json")

    def get(self, did):
        did = did.upper()
        try:
            with open(self.path(did)) as f:
                return json.load(f)
        except FileNotFoundError:
            raise Fail(f"no decision {did}")

    def all(self):
        out = []
        for name in os.listdir(self.items):
            if name.endswith(".json") and ID_RE.fullmatch(name[:-5]):
                with open(os.path.join(self.items, name)) as f:
                    out.append(json.load(f))
        return out

    def write_atomic(self, path, data):
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)

    def put(self, d):
        self.write_atomic(self.path(d["id"]), json.dumps(d, indent=1, ensure_ascii=False) + "\n")

    def log(self, action, did, by, **detail):
        line = {"at": now(), "by": by, "action": action, "id": did}
        line.update(detail)
        path = os.path.join(self.dir, "log.jsonl")
        try:
            if os.path.getsize(path) > LOG_MAX_BYTES:
                os.replace(path, path + ".1")
        except FileNotFoundError:
            pass
        with open(path, "a") as f:
            f.write(json.dumps(line, ensure_ascii=False) + "\n")

    def next_id(self):
        counter = os.path.join(self.dir, "next-id")
        try:
            with open(counter) as f:
                n = int(f.read().strip())
        except (FileNotFoundError, ValueError):
            n = 1 + max([int(x["id"][1:]) for x in self.all()] or [0])
        self.write_atomic(counter, f"{n + 1}\n")
        return f"D{n}"

    def find_duplicate(self, title):
        key = norm_title(title)
        for d in self.all():
            if d["status"] in ("open", "answered", "work") and norm_title(d["title"]) == key:
                return d
        return None

    # -- creating -------------------------------------------------------

    def create(self, fields, by, force_new=False, auto=False, inbox=False):
        """fields: a loose dict (CLI or inbox). Returns (decision, created?).

        A question for Dave needs a valid needs_dave (see NEEDS_DAVE).
        Without one:
          - auto=True (`decided`, a vetted caller): recorded as decided,
            answered with fields["chose"] or its recommendation;
          - inbox=True (a job's line: untrusted): decided only when it
            is not urgent, has a recommendation and no malformed
            needs_dave field (a refile also only while the registry's
            copy is not urgent and not answered by Dave), answered with its recommendation by
            "inbox", marked unvetted (a session re-judges it before
            acting); `chose` is ignored. Anything else stays open
            without needs_dave (unsorted: the curator sorts it);
          - else Fail."""
        f = {re.sub(r"[-\s]+", "_", str(k).strip().lower()): v for k, v in fields.items()}
        needs = parse_needs_dave(f.get("needs_dave"), f.get("needs_dave_why"),
                                 f.get("needs_dave_step"), f.get("needs_dave_verified"))
        if needs is None and not (auto or inbox):
            raise Fail(needs_dave_error(f.get("needs_dave"), f.get("needs_dave_why")) if f.get("needs_dave") else DECIDE_YOURSELF)
        # a needs_dave that is there but not valid ('money' without a
        # why, an unknown criterion): a classification gone wrong, so
        # it falls back to asking (open, unsorted), never to deciding
        malformed = needs is None and any(f.get(k) not in (None, "") for k in ("needs_dave", "needs_dave_why"))
        # a question for Dave that reads like a work item (a review, a
        # rebase, a parked change, a vars step): the CLI refuses it
        # unless the filer says why only Dave can (not_work_item); an
        # inbox line stays open unsorted for the curator to hand back
        # only the CLI may waive the check: an inbox line is untrusted
        nwi = None if inbox else clean(f.get("not_work_item"), "short")
        work = None
        if needs and not nwi:
            work = work_item_match(*(clean(f.get(k), "long") for k in ("title", "question", "why", "follow_up")),
                                   needs["why"], needs.get("step"))
        if work and not inbox:
            raise Fail(WORK_ITEM_HINT.format(what=work[0], match=work[1]))
        if work:
            needs, malformed = None, True
        title = clean(f.get("title"), "title")
        if not title:
            raise Fail("a decision needs a title")
        # urgency and severity both count; the more urgent one wins (GHSA
        # and CVSS spellings map onto ours)
        level = {"critical": "urgent", "high": "urgent", "medium": "normal", "moderate": "normal", "info": "low"}
        given = [str(f.get(k)).strip().lower() for k in ("urgency", "severity") if f.get(k) not in (None, "")]
        given = [level.get(u, u) for u in given] or ["normal"]
        urgency = next((u for u in URGENCIES if u in given), given[0])
        if urgency not in URGENCIES:
            raise Fail(f"urgency must be one of {URGENCIES}")
        source = clean(f.get("source") or f.get("source_job") or f.get("job") or by, "title")
        links = parse_links(f.get("links") or f.get("link"))
        rec = clean(f.get("recommendation"), "short")
        if inbox:
            # only CLI `decided` names a choice; a job's line answers
            # with its recommendation or not at all
            f.pop("chose", None)
            decides = needs is None and not malformed and urgency != "urgent" and bool(rec)
            if work:
                why_bad = f"filed for Dave but looks like a work item ({work[0]}: {work[1]!r}): left open for curation"
            elif malformed:
                why_bad = f"needs_dave given but not valid ({clean(f.get('needs_dave'), 'title')!r}): left open for curation"
            elif urgency == "urgent":
                why_bad = "urgent without needs_dave: left open for curation, not decided"
            else:
                why_bad = "no needs_dave and no recommendation: left open for curation"
        else:
            decides = needs is None
        if not force_new:
            dup = self.find_duplicate(title)
            if dup:
                dup["seen"] = dup.get("seen", 1) + 1
                dup["updated"] = now()
                a = dup.get("answer") or {}
                if dup["status"] == "work":
                    # handed back to the agents: a refile only adds
                    # sources and links, never turns it into a question
                    pass
                elif needs and not dup.get("needs_dave"):
                    # now filed as a real question: one decided for him
                    # (or filed before the bar) becomes his to answer
                    dup["needs_dave"] = needs
                    if a.get("auto"):
                        self.note(dup, by, f"earlier decided by {a['by']} without asking: {a['text']}")
                        dup["status"], dup["answer"] = "open", None
                elif not needs and not dup.get("needs_dave") and (dup["status"] == "open" or a.get("auto")):
                    if auto:
                        # `decided` (vetted): its choice replaces an open
                        # question's or an earlier automatic answer
                        chose = clean(f.get("chose") or rec or "the default (no recommendation given)", "long")
                        if dup["status"] == "open" or a.get("text") != chose or a.get("unvetted"):
                            dup["answer"] = {"text": chose, "by": by, "at": now(), "auto": True}
                            dup["status"] = "answered"
                            self.note(dup, by, "common sense, not asked (decided on refile)")
                    elif inbox and decides and dup["urgency"] != "urgent" and (dup["status"] == "open" or a.get("unvetted")):
                        # tonight's recommendation is the answer (a new
                        # one is unvetted again; the same one stays as
                        # is)
                        if dup["status"] == "open" or a.get("text") != rec:
                            if a.get("text"):
                                self.note(dup, by, f"automatic answer was ({a['by']}): {a['text']}")
                            dup["answer"] = {"text": rec, "by": "inbox", "at": now(), "auto": True, "unvetted": True}
                            dup["status"] = "answered"
                    elif inbox and (malformed or urgency == "urgent" or dup["urgency"] == "urgent"):
                        # refiled as urgent or with a broken needs_dave:
                        # back to open, for the curator to sort
                        if a.get("auto"):
                            self.note(dup, by, f"earlier decided by {a['by']} without asking: {a['text']}")
                            dup["status"], dup["answer"] = "open", None
                        self.note(dup, by, why_bad if malformed or urgency == "urgent" else "urgent without needs_dave: left open for curation, not decided")
                if source and source not in dup["sources"]:
                    dup["sources"].append(source)
                for link in links:
                    if link not in dup["links"] and len(dup["links"]) < MAX_LINKS:
                        dup["links"].append(link)
                if URGENCIES.index(urgency) < URGENCIES.index(dup["urgency"]):
                    dup["urgency"] = urgency
                # a job refiling an OPEN decision with fresh facts (the
                # range it is about now, tonight's reason): those replace
                # the stale ones, the old value kept in a note (whole up to
                # the long cap, else marked cut). A date stamp `(as of
                # <date>)` alone is no news: no note, no change. An
                # answered decision keeps what Dave answered (one decided
                # without asking him keeps taking fresh facts).
                for k, kind in (("why", "long"), ("still_relevant_if", "short"), ("range", "short"), ("recommendation", "short")):
                    if dup["status"] != "open" and not (dup.get("answer") or {}).get("auto"):
                        break
                    v = clean(f.get(k), kind)
                    if not v or undated(v) == undated(dup.get(k) or ""):
                        continue
                    if dup.get(k):
                        self.note(dup, by, f"{k} was: {dup[k]}", "long")
                    dup[k] = v
                self.put(dup)
                self.log("refiled", dup["id"], by, source=source)
                return dup, False
        pending = sum(1 for d in self.all() if d["status"] in ("open", "answered", "work"))
        if pending >= MAX_PENDING:
            raise Fail(f"registry full: {pending} decisions pending (cap {MAX_PENDING}); curate first")
        created = parse_time(f.get("created") or f.get("date") or "")
        d = {
            "id": self.next_id(),
            "title": title,
            "question": clean(f.get("question") or title, "short"),
            "why": clean(f.get("why") or f.get("why_it_matters"), "long"),
            "options": parse_options(f.get("options")),
            "recommendation": rec,
            "urgency": urgency,
            "source": source,
            "sources": [source],
            "created": created.astimezone(timezone.utc).isoformat() if created else now(),
            "updated": now(),
            "status": "open",
            "still_relevant_if": clean(f.get("still_relevant_if"), "short"),
            # what it is about, for a job's refiles (e.g. a commit range)
            "range": clean(f.get("range"), "short"),
            "links": links,
            "follow_up": clean(f.get("follow_up"), "long"),
            "answer": None,
            "snooze_until": None,
            "notes": [],
            "seen": 1,
        }
        if needs:
            d["needs_dave"] = needs
            if nwi:
                self.note(d, by, "filed past the work-item check: " + nwi)
            self.put(d)
            self.log("add", d["id"], by, source=source, title=title, needs_dave=needs["criterion"])
            return d, True
        if not decides:
            # an inbox line that may not be decided automatically: open,
            # unsorted (no needs_dave), counted in the brief until the
            # curator sorts it
            self.note(d, by, why_bad)
            self.put(d)
            self.log("add", d["id"], by, source=source, title=title, unsorted=True)
            return d, True
        if inbox:
            # a job's recommendation, unvetted: a session re-judges it
            # against the bar before acting on it
            d["answer"] = {"text": rec, "by": "inbox", "at": now(), "auto": True, "unvetted": True}
        else:
            chose = clean(f.get("chose") or rec or "the default (no recommendation given)", "long")
            d["answer"] = {"text": chose, "by": by, "at": now(), "auto": True}
        d["status"] = "done" if f.get("done") and not inbox else "answered"
        self.put(d)
        self.log("decided", d["id"], by, source=source, title=title, answer=d["answer"]["text"])
        return d, True

    def new_work(self, title, step, why, source, links, by):
        pending = sum(1 for d in self.all() if d["status"] in ("open", "answered", "work"))
        if pending >= MAX_PENDING:
            raise Fail(f"registry full: {pending} decisions pending (cap {MAX_PENDING}); curate first")
        source = clean(source, "title")
        d = {
            "id": self.next_id(), "title": title, "question": title, "why": clean(why, "long"),
            "options": [], "recommendation": "", "urgency": "normal", "source": source, "sources": [source],
            "created": now(), "updated": now(), "status": "work", "still_relevant_if": "", "range": "",
            "links": links, "follow_up": clean(step, "long"), "answer": None, "snooze_until": None,
            "notes": [], "seen": 1,
        }
        self.put(d)
        self.log("work", d["id"], by, source=source, title=title)
        return d

    def note(self, d, by, text, kind="short"):
        t = clean(text, kind)
        if len(t) == CAP[kind] and t.endswith("…"):  # clean() cut it: say so
            t = t[: CAP[kind] - 30] + " [cut: the rest is not kept]"
        d["notes"].append({"at": now(), "by": by, "text": t})
        d["notes"] = d["notes"][-30:]

    # -- inbox ----------------------------------------------------------

    def ingest(self, path, by="inbox", truncate=True):
        """Take every line of `path` in; bad lines go to inbox.rejected.jsonl.

        truncate (the inbox): rename `path` to `path`.ingesting first and
        read that, so concurrent appends go to a new `path`; a leftover
        .ingesting (a crash mid-ingest) is taken in first. Otherwise
        (--file) `path` is only read."""
        if not truncate:
            try:
                with open(path, "rb") as fh:
                    return self.ingest_bytes(fh.read(INBOX_MAX_BYTES + 1), by)
            except FileNotFoundError:
                return []
        work = path + ".ingesting"
        results = []
        if os.path.exists(work):
            # a run that died mid-ingest: its lines first
            results += self.ingest_work(work, by)
        try:
            os.rename(path, work)
        except FileNotFoundError:
            return results
        self.recreate_inbox(path)
        return results + self.ingest_work(work, by)

    def ingest_work(self, work, by):
        data, size = b"", -1
        try:
            with open(work, "rb") as fh:
                # A writer that opened the old file just before the rename
                # may still append: read until the size holds still.
                for _ in range(20):
                    data += fh.read(INBOX_MAX_BYTES + 1 - len(data))
                    if len(data) > INBOX_MAX_BYTES:
                        break
                    now_size = os.fstat(fh.fileno()).st_size
                    if now_size == size:
                        break
                    size = now_size
                    time.sleep(0.05)
        except FileNotFoundError:
            pass
        results = self.ingest_bytes(data, by)
        try:
            os.unlink(work)
        except FileNotFoundError:
            pass
        return results

    def recreate_inbox(self, path):
        try:
            os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        except FileExistsError:
            pass

    def ingest_bytes(self, data, by):
        rest_dropped = len(data) > INBOX_MAX_BYTES
        data = data[:INBOX_MAX_BYTES]
        results, rejected = [], []
        for raw in data.split(b"\n"):
            if not raw.strip():
                continue
            if len(raw) > INBOX_MAX_LINE:
                rejected.append({"error": "line too long", "line": raw[:200].decode("utf-8", "replace")})
                continue
            if len([r for r in results if r[1]]) >= MAX_ITEMS_PER_INGEST:
                rejected.append({"error": "too many new entries in one ingest", "line": raw[:2000].decode("utf-8", "replace")})
                continue
            try:
                obj = json.loads(raw.decode("utf-8"))
                if not isinstance(obj, dict):
                    raise Fail("not a JSON object")
                if obj.get("kind") == "notice":
                    self.add_notice(obj.get("text"), obj.get("source") or obj.get("source job") or by)
                    continue
                results.append(self.create(obj, by, inbox=True))
            except Exception as e:  # one poison line must never wedge the registry
                rejected.append({"error": f"{type(e).__name__}: {e}"[:200], "line": raw[:2000].decode("utf-8", "replace")})
        if rest_dropped:
            rejected.append({"error": f"inbox over {INBOX_MAX_BYTES} bytes; the rest was dropped", "line": ""})
        if rejected:
            rej = os.path.join(self.dir, "inbox.rejected.jsonl")
            if not os.path.exists(rej) or os.path.getsize(rej) < 4 * INBOX_MAX_BYTES:
                with open(rej, "a") as f:
                    for r in rejected:
                        r["at"] = now()
                        f.write(json.dumps(r, ensure_ascii=False) + "\n")
        return results

    # -- notices for the brief -------------------------------------------

    def notices_path(self):
        return os.path.join(self.dir, "notices.jsonl")

    def add_notice(self, text, source):
        text = clean(text, "short")
        if not text:
            raise Fail("a notice needs a text")
        source = clean(source, "title")
        digest = hashlib.sha256(f"{source}\0{text}".encode()).hexdigest()[:16]
        for old in self.notices():
            # the same notice still unsent (an inbox re-ingested after a
            # crash, a job filing twice): one line in the brief is enough
            if old.get("hash") == digest:
                return old
        path = self.notices_path()
        if os.path.exists(path) and os.path.getsize(path) > INBOX_MAX_BYTES:
            raise Fail("too many unsent notices")
        n = {"id": f"N{time.time_ns()}", "hash": digest, "at": now(), "source": source, "text": text}
        with open(path, "a") as f:
            f.write(json.dumps(n, ensure_ascii=False) + "\n")
        self.log("notice", n["id"], n["source"], text=text)
        return n

    def notices(self):
        out = []
        try:
            with open(self.notices_path()) as f:
                for raw in f:
                    try:
                        n = json.loads(raw)
                    except ValueError:
                        continue
                    if isinstance(n, dict) and n.get("text"):
                        out.append(n)
        except FileNotFoundError:
            pass
        return out


def sort_key(d):
    return (URGENCIES.index(d["urgency"]), d["created"])


def snoozed(d, at=None):
    t = parse_time(d.get("snooze_until") or "")
    return t is not None and t > (at or datetime.now(timezone.utc))


def local(ts):
    t = parse_time(ts)
    return t.astimezone(BKK).strftime("%Y-%m-%d %H:%M") if t else "?"


def render(d):
    lines = [f"{d['id']} [{d['urgency']}, {d['status']}] {d['title']}"]
    if d.get("needs_dave"):
        nd = d["needs_dave"]
        lines.append(f"Needs Dave ({nd['criterion']}): {nd['why']}")
        if nd.get("step"):
            lines.append(f"  Step for Dave: {nd['step']}")
            lines.append(f"  Verified no agent path: {nd.get('verified', '')}")
    if d["question"] and d["question"] != d["title"]:
        lines.append(f"Question: {d['question']}")
    if d["why"]:
        lines.append(f"Why: {d['why']}")
    for o in d["options"]:
        lines.append(f"  {o['key']}) {o['text']}")
    if d["recommendation"]:
        lines.append(f"Recommendation: {d['recommendation']}")
    if d["follow_up"]:
        lines.append(f"Follow-up: {d['follow_up']}")
    if d["still_relevant_if"]:
        lines.append(f"Still relevant if: {d['still_relevant_if']}")
    if d.get("range"):
        lines.append(f"Range: {d['range']}")
    for link in d["links"]:
        lines.append(f"Link: {link}")
    lines.append(f"Source: {', '.join(d['sources'])}; created {local(d['created'])}, updated {local(d['updated'])}")
    if d.get("snooze_until"):
        lines.append(f"Deferred until {local(d['snooze_until'])}")
    if d["answer"]:
        a = d["answer"]
        how = ", decided without asking Dave" if a.get("auto") else ""
        if a.get("unvetted"):
            how += "; a job's recommendation, unvetted: re-judge it before acting"
        lines.append(f"Answer ({a['by']}, {local(a['at'])}{how}): {a['text']}")
    for n in d["notes"][-5:]:
        lines.append(f"Note ({n['by']}, {local(n['at'])}): {n['text']}")
    return "\n".join(lines)


VERDICT_RE = re.compile(r"NIXPKGS-BUMP: (merged|unchanged|failed)")
LOG_NAME_RE = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{4})Z\.log")


def bump_failed(log_dir, at=None):
    """True when last night's nixpkgs bump failed: the newest log of the
    last 24 h (named <UTC start>.log by ../nixpkgs-bump.nix) ends in
    `NIXPKGS-BUMP: failed`, or has no verdict while no run holds the
    bump's lock (<log_dir>/.lock: a crashed run; `hermes chat -Q`
    writes nothing until the end, so a run still going is not judged).
    Its last non-empty line that is not hermes' trailing `session_id:`
    is the verdict, as nixpkgs-bump-verdict takes it."""
    at = at or datetime.now(timezone.utc)
    newest = None
    try:
        names = os.listdir(log_dir)
    except OSError:
        return False
    for name in names:
        m = LOG_NAME_RE.fullmatch(name)
        if not m:
            continue
        try:
            started = datetime.strptime(m.group(1), "%Y-%m-%dT%H%M").replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        if timedelta(0) <= at - started <= timedelta(hours=24) and (newest is None or started > newest[0]):
            newest = (started, os.path.join(log_dir, name))
    if newest is None:
        return False
    try:
        with open(newest[1], "rb") as f:
            f.seek(max(0, os.fstat(f.fileno()).st_size - 64 * 1024))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return False
    lines = [x.strip() for x in tail.splitlines() if x.strip() and not re.fullmatch(r"session_id: \S*", x.strip())]
    m = VERDICT_RE.fullmatch(lines[-1]) if lines else None
    if m:
        return m.group(1) == "failed"
    return not bump_running(log_dir)


def bump_running(log_dir):
    try:
        fd = os.open(os.path.join(log_dir, ".lock"), os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def asks_dave(d):
    """An open decision that cleared the bar (the only kind he is asked)."""
    return d["status"] == "open" and bool(d.get("needs_dave"))


def unsorted(d):
    """An open decision without needs_dave: the curator has not sorted it
    yet (decide it or name the criterion)."""
    return d["status"] == "open" and not d.get("needs_dave")


def decided_for_him(store, at, hours=24):
    """Decisions agents made without asking, in the last `hours`, newest first."""
    out = []
    for d in store.all():
        a = d.get("answer") or {}
        t = parse_time(a.get("at") or "") if a.get("auto") else None
        if t and timedelta(0) <= at - t <= timedelta(hours=hours):
            out.append(((t, int(d["id"][1:])), d))
    return [d for _, d in sorted(out, key=lambda x: x[0], reverse=True)]


def span(seconds):
    """A duration for the brief: 45min, 30h, 12d."""
    m = int(seconds) // 60
    if m < 120:
        return f"{m}min"
    if m < 48 * 60:
        return f"{m // 60}h"
    return f"{m // 1440}d"


RECURRING_SHOWN = 6


def recurring_lines(status):
    """The recurring tasks' section (`recurring-tasks status`: {total,
    fresh, tasks: [{task, fresh, what, problems: [{kind, why, age, slo}]}]}),
    read leniently: [] when it has no tasks."""
    if not isinstance(status, dict) or not isinstance(status.get("tasks"), list) or not status["tasks"]:
        return []
    tasks = [t for t in status["tasks"] if isinstance(t, dict)]
    stale = [t for t in tasks if t.get("fresh") is not True]
    out = [f"Recurring: {len(tasks) - len(stale)}/{len(tasks)} fresh"]
    for t in stale[:RECURRING_SHOWN]:
        name = clean(t.get("task"), "title")
        whys = []
        for p in t.get("problems") or []:
            if not isinstance(p, dict):
                continue
            age, slo = p.get("age"), p.get("slo")
            num = isinstance(age, (int, float)) and isinstance(slo, (int, float))
            kind, why = p.get("kind"), p.get("why")
            if kind == "exporter":
                whys.append("its host reports nothing" + (f" for {span(age)}" if isinstance(age, (int, float)) else ""))
            elif kind == "result":
                what = clean(t.get("what"), "title") or "result"
                whys.append(f"{what} {span(age)} old (SLO {span(slo)})" if num and why == "old"
                            else f"{what} not measured")
            elif kind == "run":
                whys.append(f"last success {span(age)} ago (SLO {span(slo)})" if num and why == "late"
                            else "no successful run on record")
        out.append(f"- {name}: {'; '.join(whys) or 'stale'}")
    if len(stale) > RECURRING_SHOWN:
        out.append(f"- and {len(stale) - RECURRING_SHOWN} more (Grafana: Recurring task stale)")
    return out


def brief(store, digest, at=None, digest_failed=False, bump_log_dir=None, recurring=None, recurring_failed=False):
    """The morning brief: (text, notice ids shown). Empty text = nothing
    to send. Notices beyond BRIEF_NOTICES stay for the next brief.
    Only decisions that cleared the bar (needs_dave) are listed; the
    ones agents decided for him are one line with a count, open ones
    without needs_dave (not yet sorted by the curator) another."""
    at = at or datetime.now(timezone.utc)
    open_ = sorted([d for d in store.all() if asks_dave(d)], key=sort_key)
    shown = [d for d in open_ if d["urgency"] == "urgent" or not snoozed(d, at)][:3]
    decided = decided_for_him(store, at)
    n_unsorted = sum(1 for d in store.all() if unsorted(d))
    n_work = sum(1 for d in store.all() if d["status"] == "work")
    notices = store.notices()
    warnings = digest_lines(digest)
    parts = []
    if open_:
        n = len(open_)
        parts.append(f"{n} decision{'s' if n != 1 else ''} waiting for you (type /decisions in infra-space):")
        for d in shown:
            tag = "URGENT: " if d["urgency"] == "urgent" else ""
            new = parse_time(d["created"])
            fresh = " (new)" if new and at - new < timedelta(hours=24) else ""
            parts.append(f"- {tag}{d['title']}{fresh}")
        if n > len(shown):
            parts.append(f"- and {n - len(shown)} more")
    if decided:
        ex = ", ".join(undated(d["title"]) for d in decided[:BRIEF_DECIDED_EXAMPLES])
        parts.append(f"Decided for you since yesterday: {len(decided)} (e.g. {ex}; ask to see all)")
    if n_unsorted:
        # nothing hides when the curation failed or has not run yet
        parts.append(f"{n_unsorted} unsorted (curation pending)")
    if n_work and parts:
        # handed back to the agents: nothing for him (never a message
        # of its own), but visible so nothing rots
        parts.append(f"{n_work} work item{'s' if n_work != 1 else ''} handed back to the agents (nothing for you)")
    if warnings:
        if parts:
            parts.append("")
        parts.append("Warnings since yesterday:")
        parts.extend(f"- {w}" for w in warnings[:6])
        if len(warnings) > 6:
            parts.append(f"- and {len(warnings) - 6} more (Grafana)")
    elif digest_failed:
        # always, also with nothing else to say: edi's own digest is
        # skipped once the brief went out, so this is the only trace
        if parts:
            parts.append("")
        parts.append("The warning digest could not be read today (check Grafana).")
    if bump_log_dir and bump_failed(bump_log_dir, at):
        if parts:
            parts.append("")
        parts.append("Nightly nixpkgs bump failed last night (~/nixpkgs-bump in infra-space).")
    rec = recurring_lines(recurring)
    if rec or recurring_failed:
        # always, all fresh included: the line is the proof they ran
        if parts:
            parts.append("")
        parts.extend(rec or ["Recurring tasks: status could not be read (check Grafana)."])
    shown_notices = notices[:BRIEF_NOTICES]
    if notices:
        if parts:
            parts.append("")
        parts.append("Taken down or changed overnight:")
        parts.extend(f"- {clean(n['text'], 'short')}" for n in shown_notices)
        if len(notices) > BRIEF_NOTICES:
            parts.append(f"- +{len(notices) - BRIEF_NOTICES} more (tomorrow, or: decision notice --list)")
    return "\n".join(parts), [n.get("id") for n in shown_notices]


def digest_lines(digest):
    """The alert digest's JSON mode (fleet-alert-digest --json: a list of
    {alert, host, detail, state, since, fired, summary}), read leniently:
    a list, or an object with a list under items/alerts/warnings; each
    entry a string or an object (alert/text/summary/title, host/instance,
    fired/count, state)."""
    if digest is None:
        return []
    items = digest
    if isinstance(digest, dict):
        items = next((digest[k] for k in ("items", "alerts", "warnings") if isinstance(digest.get(k), list)), [])
    if not isinstance(items, list):
        return []
    out = []
    for it in items:
        if isinstance(it, str):
            text = it
        elif isinstance(it, dict):
            text = str(it.get("alert") or it.get("text") or it.get("title") or it.get("alertname") or it.get("summary") or "")
            if it.get("detail"):
                text = f"{text} ({it['detail']})"
            where = it.get("host") or it.get("instance") or it.get("machine")
            if where and str(where) not in text:
                text = f"{where}: {text}"
            if it.get("state") == "resolved":
                text = f"{text}, resolved"
            count = it.get("fired", it.get("count"))
            if isinstance(count, int) and count > 1:
                text = f"{text}, {count}x"
        else:
            continue
        text = clean(text, "title")
        if text:
            out.append(text)
    return out


def main(argv=None, store_dir=DIR):
    p = argparse.ArgumentParser(prog="decision", description="The fleet's decision registry: decisions only Dave can make.")
    p.add_argument("--by", default=os.environ.get("DECISION_BY", "agent"),
                   help="who acts (dave, curator, a job's name); default $DECISION_BY or 'agent'")
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("add", help="ask Dave (only with --needs-dave; anything else: `decided`)")
    a.add_argument("--title", help="plain words, one line, what Dave decides")
    a.add_argument("--needs-dave", metavar="CRITERION",
                   help=f"why only Dave can answer, one of: {', '.join(NEEDS_DAVE)}; "
                   "with --needs-why, or as 'criterion: why'. Without it, add refuses")
    a.add_argument("--needs-why", help="one line: how this question meets the criterion")
    a.add_argument("--step", help="physical / secret-only-dave / access-verified: the concrete step Dave must do")
    a.add_argument("--verified", help="physical / secret-only-dave / access-verified: how you checked that no fleet "
                   "root, clan vars or agent key path can do that step")
    a.add_argument("--not-work-item", metavar="WHY",
                   help="the text reads like a work item (review, rebase, conflict, parked, not landed, vars step) "
                   "but the criterion holds on its own: say why only Dave can")
    a.add_argument("--question")
    a.add_argument("--why", help="why it matters / what it costs to wait")
    a.add_argument("--option", action="append", dest="options", help="repeatable: 'a) text'")
    a.add_argument("--recommendation")
    a.add_argument("--urgency", choices=URGENCIES, default="normal")
    a.add_argument("--source", help="job, agent or session id")
    a.add_argument("--still-relevant-if", help="a condition the curator can check")
    a.add_argument("--link", action="append", dest="links", help="repeatable: commit, report path, file")
    a.add_argument("--follow-up", help="what to do once answered")
    a.add_argument("--json", dest="json_in", metavar="FILE", help="read the fields as a JSON object from FILE ('-' = stdin)")
    a.add_argument("--force-new", action="store_true", help="never merge into an open one of the same title")

    wk = sub.add_parser("work", help="hand a work item back to the agents (a review, a rebase, a step a fleet root "
                        "can run): never shown to Dave; a session dispatches it and closes it. Counts toward the "
                        f"cap of {MAX_PENDING} pending items")
    wk.add_argument("--title", required=True, help="plain words, one line, what has to be done")
    wk.add_argument("--step", required=True, help="what an agent must do")
    wk.add_argument("--why", help="why it matters")
    wk.add_argument("--source", help="job, agent or session id")
    wk.add_argument("--link", action="append", dest="links", help="repeatable: commit, report path, file")

    hb = sub.add_parser("handback", help="an open or answered decision that is really a work item: status work, "
                        "with the step an agent must do (curator, sessions)")
    hb.add_argument("id")
    hb.add_argument("--step", required=True, help="what an agent must do (it becomes the follow-up)")
    hb.add_argument("--note", required=True, help="why it is not Dave's (e.g. 'a review is agents' work')")

    dd = sub.add_parser("decided", help="record a decision you made yourself (visible in the brief, never asked)")
    dd.add_argument("--title", required=True, help="plain words, one line, what was decided")
    dd.add_argument("--chose", required=True, help="what you chose")
    dd.add_argument("--why", required=True, help="one line: why that is the sane choice")
    dd.add_argument("--option", action="append", dest="options", help="repeatable: the alternatives, 'a) text'")
    dd.add_argument("--source", help="job, agent or session id")
    dd.add_argument("--link", action="append", dest="links", help="repeatable: commit, report path, file")
    dd.add_argument("--follow-up", help="what still has to happen")
    dd.add_argument("--done", action="store_true", help="nothing left to do (status done, not answered)")

    dg = sub.add_parser("decide-default", help="an open question that does not clear the bar: answer it with its recommendation; "
                        "also vets an unvetted automatic answer (a job's recommendation) after re-judging it")
    dg.add_argument("id")
    dg.add_argument("--note", help="default 'common sense, not asked'; REQUIRED when the decision carries needs_dave: "
                    "why that criterion does not apply")

    ls = sub.add_parser("list", help="list decisions, urgent first")
    ls.add_argument("--status", default="open", choices=STATUSES + ["all", "pending", "decided", "unvetted"],
                    help="pending = open + answered + work, work = handed back to the agents, "
                    "decided = decided without asking Dave, "
                    "unvetted = answered with a job's recommendation nobody re-judged yet (default: open)")
    ls.add_argument("--json", action="store_true")
    ls.add_argument("--count", action="store_true")

    s = sub.add_parser("show", help="one decision in full")
    s.add_argument("id")
    s.add_argument("--json", action="store_true")

    an = sub.add_parser("answer", help="record Dave's answer (status answered)")
    an.add_argument("id")
    an.add_argument("text")

    df = sub.add_parser("defer", help="Dave said 'later': stays open, out of the brief's top list")
    df.add_argument("id")
    df.add_argument("--days", type=int, default=3)

    cl = sub.add_parser("close", help="the follow-up is done (status done)")
    cl.add_argument("id")
    cl.add_argument("--note", default="")

    ob = sub.add_parser("obsolete", help="no longer relevant (status obsolete)")
    ob.add_argument("id")
    ob.add_argument("--reason", required=True)

    ro = sub.add_parser("reopen", help="back to open (answer kept in the notes)")
    ro.add_argument("id")
    ro.add_argument("--note", default="")
    ro.add_argument("--needs-dave", metavar="'CRITERION: WHY'",
                    help="make it a question for Dave (one decided without asking him that he wants to answer himself)")
    ro.add_argument("--step", help="with a step criterion: the concrete step")
    ro.add_argument("--verified", help="with a step criterion: how you checked no agent path can do it")

    up = sub.add_parser("update", help="refresh fields (curator)")
    up.add_argument("id")
    for f in ("title", "question", "why", "recommendation", "still-relevant-if", "follow-up"):
        up.add_argument(f"--{f}")
    up.add_argument("--urgency", choices=URGENCIES)
    up.add_argument("--options-json", help='replace the options: a JSON list, e.g. ["a) x", "b) y"]')
    up.add_argument("--add-link", action="append", default=[])
    up.add_argument("--needs-dave", metavar="'CRITERION: WHY'",
                    help="set why only Dave can answer (curator: an old question that clears the bar)")
    up.add_argument("--step", help="with a step criterion: the concrete step")
    up.add_argument("--verified", help="with a step criterion: how you checked no agent path can do it")
    up.add_argument("--note", help="why it changed")

    mg = sub.add_parser("merge", help="duplicate: mark DUP obsolete, fold its sources/links into KEEP")
    mg.add_argument("dup")
    mg.add_argument("keep")

    ig = sub.add_parser("ingest", help="take the inbox (or FILE) in; runs before every command anyway")
    ig.add_argument("--file", help="a JSON-lines file to read without truncating it")

    no = sub.add_parser("notice", help="a line for the next morning brief (e.g. a service taken down)")
    no.add_argument("text", nargs="?")
    no.add_argument("--source", default=None)
    no.add_argument("--sent", nargs="+", metavar="ID", help="drop these notices (the brief went out)")
    no.add_argument("--list", action="store_true")

    br = sub.add_parser("brief", help="render the morning brief (prints nothing if there is nothing to say)")
    br.add_argument("--digest-json", metavar="FILE", help="the alert digest's JSON output")
    br.add_argument("--digest-failed", action="store_true", help="say the digest could not be read")
    br.add_argument("--bump-log-dir", metavar="DIR", help="the nightly bump's logs: a line when last night's failed")
    br.add_argument("--recurring-json", metavar="FILE", help="the recurring tasks' freshness (recurring-tasks status)")
    br.add_argument("--recurring-failed", action="store_true", help="say the recurring tasks' status could not be read")
    br.add_argument("--json", action="store_true", help='{"text": ..., "notices": [ids shown], "send": "send" | "send-nostamp"}')

    args = p.parse_args(argv)
    by = clean(args.by, "title") or "agent"
    try:
        with Store(store_dir) as st:
            ingested = st.ingest(os.path.join(st.dir, "inbox.jsonl"))
            return run(st, args, by, ingested)
    except Fail as e:
        print(f"decision: {e}", file=sys.stderr)
        return 1


def cli_needs(args):
    needs = parse_needs_dave(args.needs_dave, step=args.step, verified=args.verified)
    if needs is None:
        err = needs_dave_error(args.needs_dave)
        raise Fail("--needs-dave: " + (err if err != DECIDE_YOURSELF else
                   "'<criterion>: <why>', criterion one of " + ", ".join(NEEDS_DAVE)))
    return needs


def run(st, args, by, ingested):
    out = sys.stdout
    if args.cmd == "add":
        if args.json_in:
            src = sys.stdin if args.json_in == "-" else open(args.json_in)
            try:
                fields = json.load(src)
            except ValueError as e:
                raise Fail(f"bad JSON: {e}")
            if not isinstance(fields, dict):
                raise Fail("the JSON must be an object")
        else:
            fields = {}
        for k in ("title", "question", "why", "options", "recommendation", "source", "still_relevant_if", "links", "follow_up", "needs_dave"):
            v = getattr(args, k)
            if v:
                fields[k] = v
        if args.needs_why:
            fields["needs_dave_why"] = args.needs_why
        for k, v in (("needs_dave_step", args.step), ("needs_dave_verified", args.verified), ("not_work_item", args.not_work_item)):
            if v:
                fields[k] = v
        if args.urgency != "normal" or "urgency" not in fields:
            fields["urgency"] = args.urgency
        d, created = st.create(fields, by, force_new=args.force_new)
        if not created and d["status"] == "work":
            print(f"{d['id']} is handed back as work (an agent does it, Dave is not asked): refiled", file=out)
            return 1
        print(d["id"] if created else f"{d['id']} (already open: refiled)", file=out)
        return 0

    if args.cmd == "work":
        title = clean(args.title, "title")
        if not title:
            raise Fail("a work item needs a title")
        dup = st.find_duplicate(title)
        if dup:
            if dup["status"] != "work":
                raise Fail(f"{dup['id']} has that title and is {dup['status']}: `decision handback {dup['id']}` it instead")
            st.note(dup, by, "refiled as work: " + clean(args.step, "short"))
            dup["seen"], dup["updated"] = dup.get("seen", 1) + 1, now()
            st.put(dup)
            st.log("refiled", dup["id"], by)
            print(f"{dup['id']} (already handed back: refiled)", file=out)
            return 0
        d = st.new_work(title, args.step, args.why, args.source or by, parse_links(args.links), by)
        print(d["id"], file=out)
        return 0

    if args.cmd == "handback":
        d = st.get(args.id)
        if d["status"] not in ("open", "answered"):
            raise Fail(f"{d['id']} is {d['status']}")
        if d["status"] == "answered" and not (d.get("answer") or {}).get("auto"):
            raise Fail(f"{d['id']} is answered by {d['answer']['by']}: its follow-up is work already; note the dispatch with update --note")
        st.note(d, by, "handed back to the agents: " + clean(args.note, "short"))
        if d.get("answer"):
            st.note(d, by, f"earlier answer ({d['answer']['by']}): {d['answer']['text']}")
        if d.get("needs_dave"):
            nd = d.pop("needs_dave")
            st.note(d, by, f"was filed as needing Dave ({nd['criterion']}): {nd['why']}")
        d["follow_up"] = clean(args.step, "long")
        d["status"], d["answer"], d["snooze_until"] = "work", None, None
        d["updated"] = now()
        st.put(d)
        st.log("handback", d["id"], by, step=d["follow_up"], note=clean(args.note, "short"))
        print(f"{d['id']}: work", file=out)
        return 0

    if args.cmd == "decided":
        fields = {"chose": args.chose, "done": args.done}
        for k in ("title", "why", "options", "source", "links", "follow_up"):
            v = getattr(args, k)
            if v:
                fields[k] = v
        fields["recommendation"] = args.chose
        dup = st.find_duplicate(clean(args.title, "title"))
        if dup and dup["status"] == "work":
            print(f"{dup['id']} is handed back as work: dispatch it and `decision close {dup['id']}`; not decided", file=out)
            return 1
        if dup and dup["status"] == "answered" and not (dup.get("answer") or {}).get("auto"):
            # Dave (or someone by hand) answered it: his answer stays
            print(f"{dup['id']} is already answered by {dup['answer']['by']}: {dup['answer']['text'][:80]}; not decided", file=out)
            return 1
        d, created = st.create(fields, by, auto=True)
        if d["status"] == "open":
            # same title as a question that cleared the bar: stays his
            print(f"{d['id']} is open as a question for Dave ({d['needs_dave']['criterion']}); not decided", file=out)
            return 1
        print(d["id"] if created else f"{d['id']} (same title: refiled)", file=out)
        return 0

    if args.cmd == "decide-default":
        d = st.get(args.id)
        a = d.get("answer") or {}
        vetting = d["status"] == "answered" and a.get("unvetted")
        if d["status"] != "open" and not vetting:
            raise Fail(f"{d['id']} is {d['status']}")
        if d.get("needs_dave") and not (args.note or "").strip():
            nd = d["needs_dave"]
            raise Fail(f"{d['id']} was filed as needing Dave ({nd['criterion']}: {nd['why']}); "
                       "say with --note why that criterion does not apply")
        if not d["recommendation"]:
            raise Fail(f"{d['id']} has no recommendation: decide it yourself with `decision answer {d['id']} <choice>`")
        if vetting and a.get("text") != d["recommendation"]:
            st.note(d, by, f"automatic answer was ({a['by']}): {a['text']}")
        d["answer"] = {"text": d["recommendation"], "by": by, "at": now(), "auto": True}
        d["status"], d["snooze_until"] = "answered", None
        note = args.note or ("common sense, vetted" if vetting else "common sense, not asked")
        args.note = note
        st.note(d, by, note)
        d["updated"] = now()
        st.put(d)
        st.log("decide-default", d["id"], by, answer=d["recommendation"], note=clean(args.note, "short"))
        print(f"{d['id']}: answered ({d['recommendation']})", file=out)
        return 0

    if args.cmd == "list":
        ds = st.all()
        if args.status == "pending":
            ds = [d for d in ds if d["status"] in ("open", "answered", "work")]
        elif args.status == "decided":
            ds = [d for d in ds if (d.get("answer") or {}).get("auto")]
        elif args.status == "unvetted":
            ds = [d for d in ds if d["status"] == "answered" and (d.get("answer") or {}).get("unvetted")]
        elif args.status != "all":
            ds = [d for d in ds if d["status"] == args.status]
        ds.sort(key=lambda d: (snoozed(d) and d["urgency"] != "urgent",) + sort_key(d))
        if args.count:
            print(len(ds), file=out)
        elif args.json:
            json.dump(ds, out, indent=1, ensure_ascii=False)
            out.write("\n")
        else:
            for d in ds:
                flag = " (deferred)" if snoozed(d) else ""
                if d["status"] == "work":
                    flag += f" (agents' work: {d['follow_up'][:60]})"
                elif d["status"] == "open" and not d.get("needs_dave"):
                    flag += " (unsorted, no needs-dave: decide-default it or name the criterion)"
                elif (d.get("answer") or {}).get("auto"):
                    flag += f" (decided by {d['answer']['by']}{', unvetted' if d['answer'].get('unvetted') else ''}: {d['answer']['text'][:60]})"
                print(f"{d['id']:>5}  {d['urgency']:<6}  {d['status']:<8}  {d['title']}{flag}", file=out)
        return 0

    if args.cmd == "show":
        d = st.get(args.id)
        if args.json:
            json.dump(d, out, indent=1, ensure_ascii=False)
            out.write("\n")
        else:
            print(render(d), file=out)
        return 0

    if args.cmd in ("answer", "defer", "close", "obsolete", "reopen", "update"):
        d = st.get(args.id)
        if args.cmd == "answer":
            if d["status"] not in ("open", "answered"):
                raise Fail(f"{d['id']} is {d['status']}; reopen it first")
            d["answer"] = {"text": clean(args.text, "long"), "by": by, "at": now()}
            d["status"] = "answered"
            d["snooze_until"] = None
            detail = {"answer": d["answer"]["text"]}
        elif args.cmd == "defer":
            if d["status"] != "open":
                raise Fail(f"{d['id']} is {d['status']}")
            until = datetime.now(timezone.utc) + timedelta(days=max(1, min(args.days, 60)))
            d["snooze_until"] = until.replace(microsecond=0).isoformat()
            detail = {"until": d["snooze_until"]}
        elif args.cmd == "close":
            d["status"] = "done"
            if args.note:
                st.note(d, by, args.note)
            detail = {"note": args.note}
        elif args.cmd == "obsolete":
            d["status"] = "obsolete"
            st.note(d, by, "obsolete: " + args.reason)
            detail = {"reason": clean(args.reason, "short")}
        elif args.cmd == "reopen":
            if d["answer"]:
                st.note(d, by, f"earlier answer ({d['answer']['by']}): {d['answer']['text']}")
            d["status"], d["answer"], d["snooze_until"] = "open", None, None
            if args.needs_dave:
                d["needs_dave"] = cli_needs(args)
            elif args.step or args.verified:
                raise Fail("--step/--verified go with --needs-dave")
            if args.note:
                st.note(d, by, args.note)
            detail = {"note": args.note}
        else:
            detail = {}
            for f in ("title", "question", "why", "recommendation", "still_relevant_if", "follow_up", "urgency"):
                v = getattr(args, f)
                if v is not None:
                    kind = "title" if f in ("title", "urgency") else ("long" if f in ("why", "follow_up") else "short")
                    d[f] = clean(v, kind)
                    detail[f] = d[f]
            if args.options_json:
                try:
                    d["options"] = parse_options(json.loads(args.options_json))
                except ValueError as e:
                    raise Fail(f"bad --options-json: {e}")
                detail["options"] = d["options"]
            if args.needs_dave:
                d["needs_dave"] = detail["needs_dave"] = cli_needs(args)
            elif args.step or args.verified:
                # complete a step criterion's step / verification
                nd = dict(d.get("needs_dave") or {})
                if not nd:
                    raise Fail("--step/--verified go with a needs_dave (give --needs-dave too)")
                nd.update({k: v for k, v in (("step", args.step), ("verified", args.verified)) if v})
                needs = parse_needs_dave(nd)
                if needs is None:
                    raise Fail(needs_dave_error(nd))
                d["needs_dave"] = detail["needs_dave"] = needs
            for link in parse_links(args.add_link):
                if link not in d["links"] and len(d["links"]) < MAX_LINKS:
                    d["links"].append(link)
                    detail.setdefault("links", []).append(link)
            if args.note:
                st.note(d, by, args.note)
                detail["note"] = args.note
            if not detail:
                raise Fail("nothing to update")
        d["updated"] = now()
        st.put(d)
        st.log(args.cmd, d["id"], by, **detail)
        print(f"{d['id']}: {d['status']}", file=out)
        return 0

    if args.cmd == "merge":
        dup, keep = st.get(args.dup), st.get(args.keep)
        if dup["id"] == keep["id"]:
            raise Fail("cannot merge a decision into itself")
        for s in dup["sources"]:
            if s not in keep["sources"]:
                keep["sources"].append(s)
        for link in dup["links"]:
            if link not in keep["links"] and len(keep["links"]) < MAX_LINKS:
                keep["links"].append(link)
        keep["seen"] = keep.get("seen", 1) + dup.get("seen", 1)
        if URGENCIES.index(dup["urgency"]) < URGENCIES.index(keep["urgency"]):
            keep["urgency"] = dup["urgency"]
        st.note(keep, by, f"merged {dup['id']} ({dup['title']})")
        dup["status"] = "obsolete"
        st.note(dup, by, f"obsolete: duplicate of {keep['id']}")
        dup["updated"] = keep["updated"] = now()
        st.put(keep)
        st.put(dup)
        st.log("merge", dup["id"], by, into=keep["id"])
        print(f"{dup['id']} merged into {keep['id']}", file=out)
        return 0

    if args.cmd == "ingest":
        res = ingested + (st.ingest(args.file, by="inbox", truncate=False) if args.file else [])
        for d, created in res:
            print(f"{d['id']} {'added' if created else 'refiled'}: {d['title']}", file=out)
        if not res:
            print("nothing to ingest", file=out)
        return 0

    if args.cmd == "notice":
        path = st.notices_path()
        if args.sent:
            keep = [n for n in st.notices() if n.get("id") not in set(args.sent)]
            st.write_atomic(path, "".join(json.dumps(n, ensure_ascii=False) + "\n" for n in keep))
            return 0
        if args.list:
            for n in st.notices():
                print(f"{n.get('id')}  {n.get('source')}  {n['text']}", file=out)
            return 0
        if not args.text:
            raise Fail("notice: give the text")
        print(st.add_notice(args.text, args.source or by)["id"], file=out)
        return 0

    if args.cmd == "brief":
        digest, digest_ok = None, False
        if args.digest_json and not args.digest_failed:
            try:
                with open(args.digest_json) as f:
                    raw = f.read(INBOX_MAX_BYTES)
                digest = json.loads(raw) if raw.strip() else None
                digest_ok = True
            except (OSError, ValueError) as e:
                print(f"decision: digest unreadable, left out: {e}", file=sys.stderr)
        failed = args.digest_failed or (bool(args.digest_json) and not digest_ok)
        recurring, rec_failed = None, args.recurring_failed
        if args.recurring_json and not rec_failed:
            try:
                with open(args.recurring_json) as f:
                    recurring = json.loads(f.read(INBOX_MAX_BYTES))
            except (OSError, ValueError) as e:
                print(f"decision: recurring status unreadable, left out: {e}", file=sys.stderr)
                rec_failed = True
        text, ids = brief(st, digest, digest_failed=failed, bump_log_dir=args.bump_log_dir,
                          recurring=recurring, recurring_failed=rec_failed)
        if args.json:
            # send: "send" stamps the day on edi (its own 09:30 digest is
            # skipped); only a brief that really carries the digest may.
            json.dump({"text": text, "notices": ids, "send": "send" if digest_ok else "send-nostamp"},
                      out, ensure_ascii=False)
            out.write("\n")
        elif text:
            print(text, file=out)
        return 0
    raise Fail(f"unknown command {args.cmd}")


if __name__ == "__main__":
    sys.exit(main())
