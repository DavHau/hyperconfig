"""Unit tests of ./decision.py, run by ../decisions.nix at build time."""

import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone

import decision


class Registry(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        os.makedirs(os.path.join(self.dir, "items"))

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, *argv, by="dave"):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = decision.main(["--by", by, *argv], store_dir=self.dir)
        return rc, out.getvalue(), err.getvalue()

    def ok(self, *argv, **kw):
        rc, out, err = self.cli(*argv, **kw)
        self.assertEqual(rc, 0, err)
        return out

    def inbox(self, *objs, raw=None):
        with open(os.path.join(self.dir, "inbox.jsonl"), "a") as f:
            for o in objs:
                f.write(json.dumps(o) + "\n")
            if raw is not None:
                f.write(raw)

    def read(self, name):
        with open(os.path.join(self.dir, name)) as f:
            return f.read()

    def show(self, did):
        return json.loads(self.ok("show", did, "--json"))

    def test_add_show_answer_close(self):
        did = self.ok("add", "--title", "Buy a proxy", "--option", "a) Decodo", "--option", "b) Evomi",
                      "--recommendation", "a", "--urgency", "low", "--source", "research").strip()
        self.assertEqual(did, "D1")
        d = self.show("D1")
        self.assertEqual(d["options"], [{"key": "a", "text": "Decodo"}, {"key": "b", "text": "Evomi"}])
        self.assertEqual((d["status"], d["urgency"]), ("open", "low"))
        self.ok("answer", "D1", "a, 20 USD")
        d = self.show("D1")
        self.assertEqual(d["status"], "answered")
        self.assertEqual(d["answer"]["by"], "dave")
        self.assertIn("a, 20 USD", self.ok("show", "D1"))
        self.ok("close", "D1", "--note", "bought")
        self.assertEqual(self.show("D1")["status"], "done")
        rc, _, err = self.cli("answer", "D1", "x")
        self.assertEqual(rc, 1)
        self.assertIn("reopen", err)
        log = self.read("log.jsonl").splitlines()
        self.assertEqual([json.loads(x)["action"] for x in log], ["add", "answer", "close"])

    def test_same_title_refiles(self):
        self.ok("add", "--title", "Backup of dave-hermes?", "--source", "a")
        out = self.ok("add", "--title", "backup of DAVE-hermes", "--source", "b", "--urgency", "urgent")
        self.assertIn("refiled", out)
        d = self.show("D1")
        self.assertEqual(d["sources"], ["a", "b"])
        self.assertEqual(d["urgency"], "urgent")
        self.assertEqual(self.ok("list", "--count").strip(), "1")

    def test_refile_updates_why_still_and_range(self):
        # the nightly bump refiles a held-back SearXNG update with the
        # night's range and reason: the stale ones go to the notes
        t = "SearXNG update held back from the nightly review"
        self.inbox({"title": t, "why": "a..b: too big", "still_relevant_if": "pin a", "range": "aaaa..bbbb"})
        self.ok("list")
        self.inbox({"title": t, "why": "a..c: U+2026", "still_relevant_if": "pin a, tip c", "range": "aaaa..cccc"})
        self.ok("list")
        d = self.show("D1")
        self.assertEqual((d["why"], d["still_relevant_if"], d["range"]), ("a..c: U+2026", "pin a, tip c", "aaaa..cccc"))
        self.assertEqual(d["seen"], 2)
        notes = " ".join(n["text"] for n in d["notes"])
        self.assertIn("why was: a..b: too big", notes)
        self.assertIn("range was: aaaa..bbbb", notes)
        self.assertIn("Range: aaaa..cccc", self.ok("show", "D1"))
        # a refile without them keeps them
        self.ok("add", "--title", t, "--source", "x")
        self.assertEqual(self.show("D1")["range"], "aaaa..cccc")

    def test_refile_date_only_long_why_and_answered(self):
        t = "SearXNG update held back from the nightly review"
        long_why = "x" * 3000 + " (as of 2026-11-14) end"
        self.inbox({"title": t, "why": long_why, "range": "a..b"})
        self.ok("list")
        # only the `(as of <date>)` part changed: no note, why kept
        self.inbox({"title": t, "why": long_why.replace("2026-11-14", "2026-11-15"), "range": "a..b"})
        self.ok("list")
        d = self.show("D1")
        self.assertEqual((d["why"], d["notes"]), (long_why, []))
        # a real change: the old why in the note uncut (3000+ characters)
        self.inbox({"title": t, "why": "new reason", "range": "a..c"})
        self.ok("list")
        d = self.show("D1")
        self.assertIn(f"why was: {long_why}", [n["text"] for n in d["notes"]])
        # over the long cap: the note says it was cut
        self.inbox({"title": t, "why": "y" * 3999})
        self.ok("list")
        self.inbox({"title": t, "why": "z"})
        self.ok("list")
        self.assertTrue(self.show("D1")["notes"][-1]["text"].endswith("[cut: the rest is not kept]"))
        # answered: a refile counts but leaves why/range as Dave saw them
        self.ok("answer", "D1", "b")
        self.inbox({"title": t, "why": "tonight's", "range": "a..d"})
        self.ok("list")
        d = self.show("D1")
        self.assertEqual((d["status"], d["why"], d["range"]), ("answered", "z", "a..c"))

    def test_inbox_ingest_formats_and_rejects(self):
        # the security jobs' infra-decision line, a notice, junk
        self.inbox(
            {"id": "abc", "title": "Take down X?", "why": "CVE", "options": ["a) yes", "b) no"],
             "recommendation": "a", "source": "cve-watch", "severity": "critical",
             "date": "2026-11-14", "still_relevant_if": "X still runs"},
            {"kind": "notice", "text": "stopped foo.service on bam (CVE-1)", "source": "cve-watch"},
            [1, 2],
            raw="{not json\n" + "x" * (decision.INBOX_MAX_LINE + 1) + "\n",
        )
        out = self.ok("list")
        self.assertIn("urgent", out)
        self.assertIn("Take down X?", out)
        self.assertEqual(os.path.getsize(os.path.join(self.dir, "inbox.jsonl")), 0)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "inbox.jsonl.ingesting")))
        rej = self.read("inbox.rejected.jsonl").splitlines()
        self.assertEqual(len(rej), 3)
        self.assertIn("stopped foo.service", self.ok("notice", "--list"))
        d = self.show("D1")
        self.assertEqual(d["created"], "2026-11-13T17:00:00+00:00")

    def test_ingest_caps_new_entries(self):
        self.inbox(*[{"title": f"t{i}"} for i in range(decision.MAX_ITEMS_PER_INGEST + 5)])
        self.assertEqual(self.ok("list", "--count").strip(), str(decision.MAX_ITEMS_PER_INGEST))

    def test_caps_and_control_chars(self):
        self.ok("add", "--title", "a\x1b[31m" + "t" * 500, "--why", "w" * 10000)
        d = self.show("D1")
        self.assertNotIn("\x1b", d["title"])
        self.assertLessEqual(len(d["title"]), decision.CAP["title"])
        self.assertLessEqual(len(d["why"]), decision.CAP["long"])

    def test_bad_ids_refused(self):
        for bad in ("../x", "D1/../../etc", "X1", "D1\n", "D1/x"):
            rc, _, err = self.cli("show", bad)
            self.assertEqual(rc, 1, bad)
            self.assertIn("not a decision id", err)

    def test_obsolete_merge_reopen_defer_update(self):
        self.ok("add", "--title", "one")
        self.ok("add", "--title", "two", "--source", "s2", "--link", "L")
        self.ok("merge", "D2", "D1")
        self.assertEqual(self.show("D2")["status"], "obsolete")
        self.assertEqual(self.show("D1")["links"], ["L"])
        self.ok("obsolete", "D1", "--reason", "landed on main")
        self.assertEqual(self.ok("list", "--count").strip(), "0")
        self.ok("reopen", "D1")
        self.ok("defer", "D1", "--days", "2")
        self.assertIn("deferred", self.ok("list"))
        self.ok("update", "D1", "--recommendation", "b", "--options-json", '["a) x", "b) y"]', "--note", "fresh")
        d = self.show("D1")
        self.assertEqual((d["recommendation"], len(d["options"])), ("b", 2))
        rc, _, _ = self.cli("update", "D1")
        self.assertEqual(rc, 1)

    def test_brief(self):
        self.assertEqual(self.ok("brief"), "")  # nothing to say: nothing printed
        for i, (t, u) in enumerate([("low one", "low"), ("urgent one", "urgent"), ("normal one", "normal"),
                                    ("normal two", "normal"), ("normal three", "normal")]):
            self.ok("add", "--title", t, "--urgency", u)
        self.ok("defer", "D3")
        digest = os.path.join(self.dir, "digest.json")
        with open(digest, "w") as f:
            json.dump([{"alert": "Disk almost full", "host": "vit", "detail": "/ 91 %", "state": "firing", "fired": 3},
                       {"alert": "unit failed", "host": "nas", "state": "resolved"}], f)
        self.ok("notice", "stopped foo on bam", "--source", "cve-watch")
        res = json.loads(self.ok("brief", "--json", "--digest-json", digest))
        text = res["text"]
        lines = text.splitlines()
        self.assertEqual(lines[0], "5 decisions waiting for you (type /decisions in infra-space):")
        self.assertTrue(lines[1].startswith("- URGENT: urgent one"), lines)
        # the deferred normal one is left out of the top three
        self.assertNotIn("normal one", text)
        self.assertIn("- and 2 more", text)
        self.assertIn("vit: Disk almost full (/ 91 %), 3x", text)
        self.assertIn("nas: unit failed, resolved", text)
        self.assertIn("stopped foo on bam", text)
        self.assertLessEqual(len(lines), 14)
        self.assertEqual(len(res["notices"]), 1)
        self.ok("notice", "--sent", *res["notices"])
        self.assertEqual(self.ok("notice", "--list"), "")

    def test_brief_digest_only_and_failed_digest(self):
        digest = os.path.join(self.dir, "digest.json")
        with open(digest, "w") as f:
            f.write("[]")
        self.assertEqual(self.ok("brief", "--digest-json", digest), "")
        with open(digest, "w") as f:
            json.dump(["plain text warning"], f)
        self.assertEqual(self.ok("brief", "--digest-json", digest).strip(),
                         "Warnings since yesterday:\n- plain text warning")
        self.ok("add", "--title", "x")
        self.assertIn("could not be read", self.ok("brief", "--digest-failed"))
        self.ok("close", "D1")
        with open(digest, "w") as f:
            f.write("{broken")
        rc, out, err = self.cli("brief", "--digest-json", digest)
        self.assertEqual(rc, 0)
        self.assertIn("left out", err)

    def test_digest_failure_alone_is_sent(self):
        # no open decisions, no notices: the failed digest is still a line
        # (edi skips its own digest once the brief went out)
        res = json.loads(self.ok("brief", "--json", "--digest-failed"))
        self.assertIn("warning digest could not be read", res["text"])

    def test_poison_lines_rejected_alone(self):
        self.inbox(
            {"title": "year one", "date": "0001-01-01"},
            {"title": "year max", "created": "9999-12-31T23:59:59"},
            {"title": "aware max", "created": "9999-12-31T23:59:59-05:00"},
            {"title": ["a", "list"], "urgency": ["x"]},
            {"title": "fine", "options": {"key": [1]}, "links": {"x": 1}},
            {"title": "after the poison"},
        )
        out = self.ok("list")
        self.assertIn("after the poison", out)
        # dates out of range are dropped (created = now), not fatal
        for t in ("year one", "year max", "aware max"):
            self.assertIn(t, out)
        rej = [json.loads(x) for x in self.read("inbox.rejected.jsonl").splitlines()]
        self.assertTrue(all("error" in r for r in rej), rej)
        # the inbox is empty and works on: the next command is fine
        self.assertEqual(os.path.getsize(os.path.join(self.dir, "inbox.jsonl")), 0)
        self.ok("list")

    def test_poison_line_exception_is_contained(self):
        # any exception from one line (not only Fail/ValueError) is a reject
        orig = decision.Store.create

        def boom(st, obj, by, force_new=False):
            if obj.get("title") == "boom":
                raise OverflowError("date value out of range")
            return orig(st, obj, by, force_new)
        decision.Store.create = boom
        try:
            self.inbox({"title": "boom"}, {"title": "ok one"})
            self.assertIn("ok one", self.ok("list"))
        finally:
            decision.Store.create = orig
        rej = self.read("inbox.rejected.jsonl")
        self.assertIn("OverflowError", rej)

    def test_inbox_rename_keeps_concurrent_appends(self):
        inbox = os.path.join(self.dir, "inbox.jsonl")
        self.inbox({"title": "first"})
        st = decision.Store(self.dir)
        orig = st.recreate_inbox

        def racing_writer(path):
            orig(path)
            # a job appends right after the rename: lands in the new inbox
            with open(inbox, "a") as f:
                f.write(json.dumps({"title": "during ingest"}) + "\n")
        st.recreate_inbox = racing_writer
        with st:
            got = [d["title"] for d, _ in st.ingest(inbox)]
        self.assertEqual(got, ["first"])
        self.assertIn("during ingest", self.read("inbox.jsonl"))
        self.assertIn("during ingest", self.ok("list"))

    def test_leftover_ingesting_file_taken_in(self):
        with open(os.path.join(self.dir, "inbox.jsonl.ingesting"), "w") as f:
            f.write(json.dumps({"title": "from a crashed run"}) + "\n")
        self.inbox({"title": "new"})
        out = self.ok("list")
        self.assertIn("from a crashed run", out)
        self.assertIn("new", out)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "inbox.jsonl.ingesting")))

    def test_notice_reingest_after_crash_not_doubled(self):
        line = json.dumps({"kind": "notice", "text": "stopped foo.service on bam", "source": "cve-watch"}) + "\n"
        # a run that died after taking the notice in, before unlinking
        self.ok("notice", "stopped foo.service on bam", "--source", "cve-watch")
        with open(os.path.join(self.dir, "inbox.jsonl.ingesting"), "w") as f:
            f.write(line)
        self.inbox({"kind": "notice", "text": "stopped foo.service on bam", "source": "cve-watch"})
        self.ok("list")
        listed = self.ok("notice", "--list").strip().splitlines()
        self.assertEqual(len(listed), 1, listed)
        # once sent, the same text is a new notice again (another night)
        ids = json.loads(self.ok("brief", "--json"))["notices"]
        self.ok("notice", "--sent", *ids)
        self.ok("notice", "stopped foo.service on bam", "--source", "cve-watch")
        self.assertEqual(len(self.ok("notice", "--list").strip().splitlines()), 1)
        # another source with the same text is another notice
        self.ok("notice", "stopped foo.service on bam", "--source", "other")
        self.assertEqual(len(self.ok("notice", "--list").strip().splitlines()), 2)

    def test_brief_send_verb(self):
        # only a brief that carries the digest may stamp edi's day
        digest = os.path.join(self.dir, "digest.json")
        with open(digest, "w") as f:
            json.dump(["w"], f)
        self.assertEqual(json.loads(self.ok("brief", "--json", "--digest-json", digest))["send"], "send")
        with open(digest, "w") as f:
            f.write("[]")
        self.ok("add", "--title", "x")
        self.assertEqual(json.loads(self.ok("brief", "--json", "--digest-json", digest))["send"], "send")
        self.assertEqual(json.loads(self.ok("brief", "--json", "--digest-failed"))["send"], "send-nostamp")
        # no digest configured at all: edi's own digest must still run
        self.assertEqual(json.loads(self.ok("brief", "--json"))["send"], "send-nostamp")
        # a digest file that does not parse counts as failed
        with open(digest, "w") as f:
            f.write("{broken")
        res = json.loads(self.cli("brief", "--json", "--digest-json", digest)[1])
        self.assertEqual(res["send"], "send-nostamp")
        self.assertIn("could not be read", res["text"])

    def test_many_notices_only_shown_ones_returned(self):
        for i in range(9):
            self.ok("notice", f"took down svc{i}", "--source", "cve-watch")
        res = json.loads(self.ok("brief", "--json"))
        self.assertEqual(len(res["notices"]), decision.BRIEF_NOTICES)
        self.assertIn("+3 more", res["text"])
        self.assertIn("svc0", res["text"])
        self.assertNotIn("svc8", res["text"])
        self.ok("notice", "--sent", *res["notices"])
        left = self.ok("notice", "--list")
        self.assertEqual(len(left.splitlines()), 3)
        self.assertIn("svc8", left)
        # the next brief shows the rest
        res = json.loads(self.ok("brief", "--json"))
        self.assertEqual(len(res["notices"]), 3)
        self.assertNotIn("more", res["text"])

    def test_unsent_brief_keeps_notices(self):
        # the unit drops notices only after a send succeeded: rendering
        # alone (a failed send) keeps them all
        self.ok("notice", "stopped x")
        self.ok("brief", "--json")
        self.ok("brief", "--json")
        self.assertIn("stopped x", self.ok("notice", "--list"))

    def test_pending_cap(self):
        old = decision.MAX_PENDING
        decision.MAX_PENDING = 3
        try:
            for i in range(3):
                self.ok("add", "--title", f"t{i}")
            rc, _, err = self.cli("add", "--title", "one too many")
            self.assertEqual(rc, 1)
            self.assertIn("registry full", err)
            self.inbox({"title": "inbox too many"})
            self.ok("list")
            self.assertIn("registry full", self.read("inbox.rejected.jsonl"))
            self.ok("close", "D1")
            self.ok("add", "--title", "room again")
        finally:
            decision.MAX_PENDING = old

    def test_log_rotation(self):
        old = decision.LOG_MAX_BYTES
        decision.LOG_MAX_BYTES = 300
        try:
            for i in range(10):
                self.ok("add", "--title", f"title number {i}")
        finally:
            decision.LOG_MAX_BYTES = old
        log = os.path.join(self.dir, "log.jsonl")
        self.assertTrue(os.path.exists(log + ".1"))
        self.assertLess(os.path.getsize(log), 600)
        self.assertLess(os.path.getsize(log + ".1"), 600)

    def test_bump_failed_line(self):
        logs = os.path.join(self.dir, "bump")
        os.makedirs(logs)
        at = datetime(2026, 11, 15, 2, 0, tzinfo=timezone.utc)

        def log(name, *lines):
            path = os.path.join(logs, name)
            with open(path, "w") as f:
                f.write("\n".join(lines) + "\n")
        log("2026-11-13T1830Z.log", "NIXPKGS-BUMP: merged", "session_id: x")
        self.assertFalse(decision.bump_failed(logs, at))
        log("2026-11-14T1830Z.log", "report", "NIXPKGS-BUMP: failed", "", "session_id: 20261114_x")
        self.assertTrue(decision.bump_failed(logs, at))
        st = decision.Store(self.dir)
        with st:
            text, _ = decision.brief(st, None, at=at, bump_log_dir=logs)
        self.assertEqual(text, "Nightly nixpkgs bump failed last night (~/nixpkgs-bump in infra-space).")
        # a newer run (by hand) that merged wins
        log("2026-11-15T0100Z.log", "NIXPKGS-BUMP: merged", "session_id: y")
        self.assertFalse(decision.bump_failed(logs, at))
        # no verdict, no run holding the lock: crashed = failed
        log("2026-11-15T0110Z.log", "half a report")
        self.assertTrue(decision.bump_failed(logs, at))
        # a run still going (lock held): not judged
        import fcntl
        with open(os.path.join(logs, ".lock"), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertFalse(decision.bump_failed(logs, at))
        self.assertTrue(decision.bump_failed(logs, at))
        # older than a day: not last night
        self.assertFalse(decision.bump_failed(logs, at + timedelta(days=2)))
        self.assertFalse(decision.bump_failed(os.path.join(self.dir, "missing"), at))

    def test_new_marker(self):
        st = decision.Store(self.dir)
        with st:
            st.create({"title": "old", "created": "2026-01-01T00:00:00+00:00"}, "t")
            st.create({"title": "fresh"}, "t")
            text, _ = decision.brief(st, None, at=datetime.now(timezone.utc) + timedelta(hours=1))
        self.assertIn("- fresh (new)", text)
        self.assertIn("- old\n", text + "\n")


if __name__ == "__main__":
    unittest.main()
