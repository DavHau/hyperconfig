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

    def ask(self, *argv, **kw):
        """`add` of a question that clears the bar"""
        return self.ok("add", "--needs-dave", "money: test", *argv, **kw)

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
        did = self.ask("--title", "Buy a proxy", "--option", "a) Decodo", "--option", "b) Evomi",
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
        self.ask("--title", "Backup of dave-hermes?", "--source", "a")
        out = self.ask("--title", "backup of DAVE-hermes", "--source", "b", "--urgency", "urgent")
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
        self.ask("--title", t, "--source", "x")
        self.assertEqual(self.show("D1")["range"], "aaaa..cccc")

    def test_refile_date_only_long_why_and_answered(self):
        t = "SearXNG update held back from the nightly review"
        long_why = "x" * 3000 + " (as of 2026-11-14) end"
        self.inbox({"title": t, "why": long_why, "range": "a..b", "recommendation": "keep"})
        self.ok("list")
        # only the `(as of <date>)` part changed: no note, why kept
        self.inbox({"title": t, "why": long_why.replace("2026-11-14", "2026-11-15"), "range": "a..b", "recommendation": "keep"})
        self.ok("list")
        d = self.show("D1")
        self.assertEqual((d["why"], d["notes"]), (long_why, []))
        # a real change: the old why in the note uncut (3000+ characters)
        self.inbox({"title": t, "why": "new reason", "range": "a..c"})
        self.ok("list")
        d = self.show("D1")
        self.assertIn(f"why was: {long_why}", [n["text"] for n in d["notes"]])
        self.assertEqual((d["status"], d["answer"]["text"]), ("answered", "keep"))
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
             "date": "2026-11-14", "still_relevant_if": "X still runs", "needs_dave": "noticeable: X goes away"},
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
        self.assertEqual(self.ok("list", "--status", "all", "--count").strip(), str(decision.MAX_ITEMS_PER_INGEST))

    def test_caps_and_control_chars(self):
        self.ask("--title", "a\x1b[31m" + "t" * 500, "--why", "w" * 10000)
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
        self.ask("--title", "one")
        self.ask("--title", "two", "--source", "s2", "--link", "L")
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

    def test_add_without_needs_dave_refused(self):
        rc, out, err = self.cli("add", "--title", "Test priming dictation?", "--option", "a) measure first",
                                "--recommendation", "a")
        self.assertEqual(rc, 1)
        self.assertIn("decision decided --title", err)
        self.assertIn("decide it yourself", err.lower())
        # an unknown criterion or one without a reason is no better
        for bad in (["--needs-dave", "convenience: nicer"], ["--needs-dave", "money"], ["--needs-dave", "money:  "]):
            rc, _, err = self.cli("add", "--title", "x", *bad)
            self.assertEqual(rc, 1, bad)
            self.assertIn("does not clear the bar", err)
        self.assertEqual(self.ok("list", "--status", "all", "--count").strip(), "0")
        # both spellings of a valid one
        self.ok("add", "--title", "Buy a proxy?", "--needs-dave", "money", "--needs-why", "20 USD a month")
        self.ok("add", "--title", "Give Adam ssh to bam?", "--needs-dave", "access: another person on bam")
        d = self.show("D1")
        self.assertEqual(d["needs_dave"], {"criterion": "money", "why": "20 USD a month"})
        self.assertEqual(d["status"], "open")
        self.assertIn("Needs Dave (money): 20 USD a month", self.ok("show", "D1"))
        self.assertEqual(self.show("D2")["needs_dave"]["criterion"], "access")

    def test_work_items_are_refused(self):
        # D10's and D9's shapes: a review, a parked change, an unlanded
        # branch, a vars step are the agents' work, never Dave's question
        cases = [
            ("cm-pi slim closure change", "never reviewed, touches the clan inventory", "a review"),
            ("Land the nas tang unlock?", "rebased on main, not landed", "a rebase"),
            ("cm-pi slim closure", "conflicts with the recurring-tasks module on main", "a conflict"),
            ("Keep the proxy change parked?", "x", "a parked change"),
            ("Generate nas' unlock var", "needs a vars step first", "a vars step"),
            ("Land the nas change?", "not landed yet", "an unlanded change"),
        ]
        for title, why, what in cases:
            rc, _, err = self.cli("add", "--title", title, "--why", why, "--needs-dave", "noticeable: he sees it")
            self.assertEqual(rc, 1, title)
            self.assertIn("work item", err, title)
            self.assertIn(what, err, title)
            self.assertIn("decision work", err, title)
        self.assertEqual(self.ok("list", "--status", "all", "--count").strip(), "0")
        # the filer may say why only Dave can, recorded in a note
        self.ok("add", "--title", "Buy the reviewed proxy plan?", "--needs-dave", "money: 20 USD a month",
                "--not-work-item", "the review is done; the purchase is his")
        d = self.show("D1")
        self.assertEqual(d["status"], "open")
        self.assertIn("past the work-item check", d["notes"][-1]["text"])
        # a job's inbox line of that shape: open unsorted for the curator, never asked
        self.inbox({"title": "Land nas unlock", "why": "reviewed change, not landed", "recommendation": "a",
                    "needs_dave": "noticeable: x"})
        d = self.show("D2")
        self.assertEqual((d["status"], d.get("needs_dave")), ("open", None))
        self.assertIn("looks like a work item", d["notes"][-1]["text"])

    def test_work_item_patterns_spare_real_questions(self):
        for t in ("Write a review of the hotel under your name?", "Review your Google privacy settings?",
                  "Fix the car park sensor?", "his bank password, not in clan vars",
                  "conflicts with the maintenance window", "conflicts with the change you asked for",
                  "SearXNG update held back from the nightly review", "the parked domain renewal costs 12 USD"):
            self.assertIsNone(decision.work_item_match(t), t)
        for t in ("never reviewed", "needs an independent review", "rebased on main", "conflicts in 9 files with main",
                  "parked as a patch", "not landed", "needs a vars step", "generating the disk-unlock var",
                  "needs to be reviewed", "has not been reviewed", "awaiting review", "the stack is behind main",
                  "diverged from main", "unmerged", "Park the cm-pi slim closure change (not landed)"):
            self.assertIsNotNone(decision.work_item_match(t), t)
        self.ok("add", "--title", "Give Anna access?", "--needs-dave", "access: to the Nextcloud Dave runs")

    def test_inbox_cannot_waive_the_work_item_check(self):
        self.inbox({"title": "Land it?", "why": "never reviewed", "needs_dave": "money: x",
                    "not_work_item": "trust me", "recommendation": "a"})
        d = self.show("D1")
        self.assertEqual((d["status"], d.get("needs_dave")), ("open", None))
        self.assertNotIn("past the work-item check", json.dumps(d))

    def test_work_title_collisions(self):
        self.ok("work", "--title", "Review the cm-pi change", "--step", "review it")
        rc, out, _ = self.cli("add", "--title", "Review the cm-pi change", "--needs-dave", "money: x",
                              "--not-work-item", "y")
        self.assertEqual(rc, 1)
        self.assertIn("handed back as work", out)
        rc, out, _ = self.cli("decided", "--title", "Review the cm-pi change", "--chose", "a", "--why", "b")
        self.assertEqual(rc, 1)
        self.assertIn("handed back as work", out)
        self.assertEqual(self.show("D1")["status"], "work")
        # handback only from open/answered; reopen takes a work item back
        rc, _, _ = self.cli("handback", "D1", "--step", "x", "--note", "y")
        self.assertEqual(rc, 1)
        rc, _, err = self.cli("reopen", "D1", "--step", "x")
        self.assertEqual(rc, 1)
        self.assertIn("--needs-dave", err)
        self.ok("reopen", "D1", "--needs-dave", "money: it costs", "--note", "turned out to cost money")
        self.assertEqual(self.show("D1")["status"], "open")
        self.ok("obsolete", "D1", "--reason", "x")
        rc, _, _ = self.cli("handback", "D1", "--step", "x", "--note", "y")
        self.assertEqual(rc, 1)

    def test_access_claims_need_a_verified_step(self):
        # D9's shape: "only Dave runs it" filed as access
        rc, _, err = self.cli("add", "--title", "Unlock nas by itself?",
                              "--needs-dave", "access: only Dave runs it from the casa LAN")
        self.assertEqual(rc, 1)
        self.assertIn("access-verified", err)
        for crit in ("physical", "secret-only-dave", "access-verified", "only-dave"):
            rc, _, err = self.cli("add", "--title", "x " + crit, "--needs-dave", crit + ": he has to")
            self.assertEqual(rc, 1, crit)
            self.assertIn("--step", err, crit)
            rc, _, err = self.cli("add", "--title", "x " + crit, "--needs-dave", crit + ": he has to",
                                  "--step", "plug it in")
            self.assertEqual(rc, 1, crit)
        self.ok("add", "--title", "Plug the Voice PE into amy", "--needs-dave", "physical: hardware on his desk",
                "--step", "plug it into amy by USB", "--verified", "no remote path flashes a new device")
        d = self.show("D1")
        self.assertEqual(d["needs_dave"], {"criterion": "physical", "why": "hardware on his desk",
                                           "step": "plug it into amy by USB",
                                           "verified": "no remote path flashes a new device"})
        self.assertIn("Step for Dave: plug it into amy by USB", self.ok("show", "D1"))
        self.ok("add", "--title", "Pick the wake word", "--needs-dave", "preference: he hears it every day")
        self.assertEqual(self.show("D2")["needs_dave"]["criterion"], "preference")
        # alias
        self.ok("add", "--title", "Bank login", "--needs-dave", "secret: his bank password", "--step", "type it",
                "--verified", "not in clan vars, on no machine")
        self.assertEqual(self.show("D3")["needs_dave"]["criterion"], "secret-only-dave")
        # an inbox line with such an unverified claim: unsorted, not asked
        self.inbox({"title": "Run the unlock step", "needs_dave": "access-verified: only him", "recommendation": "a"})
        d4 = self.show("D4")
        self.assertEqual((d4["status"], d4.get("needs_dave")), ("open", None))
        # update can complete the step of an existing claim
        self.ok("update", "D1", "--step", "plug it into amy's front USB", by="curator")
        self.assertEqual(self.show("D1")["needs_dave"]["step"], "plug it into amy's front USB")

    def test_work_and_handback(self):
        self.assertEqual(self.ok("work", "--title", "Review the cm-pi slim closure", "--step",
                                 "independent review, then land", "--source", "infra", by="infra").strip(), "D1")
        d = self.show("D1")
        self.assertEqual((d["status"], d["follow_up"]), ("work", "independent review, then land"))
        self.assertEqual(self.ok("list").strip(), "")  # not a question
        self.assertEqual(self.ok("brief"), "")  # never a message of its own
        self.ask("--title", "Buy a proxy?")
        self.assertIn("1 work item handed back to the agents (nothing for you)", self.ok("brief"))
        self.ok("obsolete", "D2", "--reason", "test")
        self.assertIn("agents' work", self.ok("list", "--status", "pending"))
        self.assertIn("refiled", self.ok("work", "--title", "review the cm-pi slim closure", "--step", "again"))
        # a work-shaped question already open (filed before the check): handed back
        self.ask("--title", "Let nas unlock by itself?")
        with self.assertRaises(SystemExit):  # --note required
            self.cli("handback", "D3", "--step", "x")
        self.ok("handback", "D3", "--step", "infra binds the passphrase offline, lands, deploys",
                "--note", "the step is offline with the passphrase in clan vars", by="curator")
        d = self.show("D3")
        self.assertEqual((d["status"], d.get("needs_dave")), ("work", None))
        self.assertIn("was filed as needing Dave (money)", d["notes"][-1]["text"])
        self.assertNotIn("Let nas unlock", self.ok("brief"))
        # a refile of the same title with needs_dave does not reopen it as a question
        rc, out, _ = self.cli("add", "--needs-dave", "money: test", "--title", "Let nas unlock by itself?")
        self.assertEqual(rc, 1)
        self.assertIn("handed back as work", out)
        self.assertEqual(self.show("D3")["status"], "work")
        # done: closed like any follow-up
        self.ok("close", "D3", "--note", "landed and deployed")
        self.assertEqual(self.show("D3")["status"], "done")
        # Dave's own answer is never handed back
        self.ask("--title", "Buy it?")
        self.ok("answer", "D4", "a")
        rc, _, err = self.cli("handback", "D4", "--step", "x", "--note", "y")
        self.assertEqual(rc, 1)

    def test_decided_subcommand(self):
        out = self.ok("decided", "--title", "Keep SearXNG engines off", "--chose", "no change",
                      "--why", "nothing asked for them", "--source", "research", by="infra")
        self.assertEqual(out.strip(), "D1")
        d = self.show("D1")
        self.assertEqual(d["status"], "answered")
        self.assertEqual((d["answer"]["text"], d["answer"]["by"], d["answer"]["auto"]), ("no change", "infra", True))
        self.assertNotIn("needs_dave", d)
        self.assertIn("decided without asking Dave", self.ok("show", "D1"))
        # never asked: not in the open list, nor in the brief's questions
        self.assertEqual(self.ok("list").strip(), "")
        self.assertIn("Keep SearXNG engines off", self.ok("list", "--status", "decided"))
        self.ok("decided", "--title", "Move rebuildable data", "--chose", "symlinks", "--why", "reversible", "--done")
        self.assertEqual(self.show("D2")["status"], "done")
        # the same title as a real open question stays his
        self.ask("--title", "Buy a proxy?")
        rc, out, _ = self.cli("decided", "--title", "Buy a proxy?", "--chose", "a", "--why", "cheap")
        self.assertEqual(rc, 1)
        self.assertIn("question for Dave", out)
        self.assertEqual(self.show("D3")["status"], "open")
        log = [json.loads(x)["action"] for x in self.read("log.jsonl").splitlines()]
        self.assertEqual(log[:2], ["decided", "decided"])
        # Dave wants to answer one himself: reopened as his question
        self.ok("reopen", "D1", "--needs-dave", "conflict: Dave asked to decide it")
        d = self.show("D1")
        self.assertEqual((d["status"], d["needs_dave"]["criterion"]), ("open", "conflict"))
        self.assertEqual([n["text"] for n in d["notes"]], ["earlier answer (infra): no change"])

    def test_ingest_without_needs_dave_is_decided(self):
        self.inbox(
            {"title": "SearXNG update held back", "why": "too big", "recommendation": "a) review it and take it",
             "options": ["a) review", "b) keep"], "source": "nixpkgs-bump (main)"},
            {"title": "Take down foo?", "recommendation": "a", "source": "cve-watch",
             "needs_dave": "noticeable: foo stops for him", "severity": "critical"},
            {"title": "Junk reason", "recommendation": "b", "needs_dave": "because: I said so"},
        )
        self.assertEqual(self.ok("list").split("\n")[0].split()[-3:], ["Take", "down", "foo?"])
        d1 = self.show("D1")
        self.assertEqual(d1["status"], "answered")
        self.assertEqual(d1["answer"]["text"], "a) review it and take it")
        self.assertEqual((d1["answer"]["by"], d1["answer"]["auto"], d1["answer"]["unvetted"]), ("inbox", True, True))
        self.assertEqual(d1["source"], "nixpkgs-bump (main)")
        # an invalid criterion is a broken classification: asked, not decided
        d3 = self.show("D3")
        self.assertEqual((d3["status"], d3["answer"], d3.get("needs_dave")), ("open", None, None))
        self.assertEqual(self.show("D2")["status"], "open")
        # the nightly refile of the decided one: new facts, still not asked
        self.inbox({"title": "SearXNG update held back", "why": "still too big", "source": "nixpkgs-bump (main)"})
        d1 = self.show("D1")
        self.assertEqual((d1["status"], d1["why"], d1["seen"]), ("answered", "still too big", 2))
        # an open question from before the bar, refiled without one: decided
        st = decision.Store(self.dir)
        with st:
            old = st.get("D2")
            del old["needs_dave"]
            old["title"], old["urgency"] = "Old question", "normal"
            st.put(old)
        self.inbox({"title": "Old question", "source": "cve-watch"})
        self.assertEqual(self.show("D2")["status"], "open")  # no recommendation in the line: stays open
        self.inbox({"title": "Old question", "source": "cve-watch", "recommendation": "a"})
        d2 = self.show("D2")
        self.assertEqual((d2["status"], d2["answer"]["text"], d2["answer"]["by"]), ("answered", "a", "inbox"))
        # ... and a refile WITH a reason makes a decided one his question
        self.inbox({"title": "Old question", "needs_dave": "access: now another person", "source": "x"})
        d2 = self.show("D2")
        self.assertEqual((d2["status"], d2["answer"]), ("open", None))
        self.assertIn("earlier decided by", d2["notes"][-1]["text"])

    def test_decide_default(self):
        st = decision.Store(self.dir)
        with st:  # a question filed before the bar existed: no needs_dave
            d, _ = st.create({"title": "Test priming dictation", "recommendation": "a) measure first",
                              "needs_dave": "money: x"}, "t")
            del d["needs_dave"]
            st.put(d)
        self.assertIn("decide-default it", self.ok("list"))
        # one that does clear the bar gets its reason instead (and the brief lists it)
        self.ok("add", "--title", "pre-bar but real", "--force-new", "--needs-dave", "money: x")
        st = decision.Store(self.dir)
        with st:
            d2 = st.get("D2")
            del d2["needs_dave"]
            st.put(d2)
        self.assertEqual(self.ok("brief"), "2 unsorted (curation pending)\n")
        self.ok("update", "D2", "--needs-dave", "money: 20 USD a month", by="curator")
        self.assertIn("pre-bar but real", self.ok("brief"))
        self.assertIn("1 unsorted (curation pending)", self.ok("brief"))
        rc, _, _ = self.cli("update", "D2", "--needs-dave", "nice: x")
        self.assertEqual(rc, 1)
        self.ok("obsolete", "D2", "--reason", "test")
        out = self.ok("decide-default", "D1", by="curator")
        self.assertIn("answered", out)
        d = self.show("D1")
        self.assertEqual((d["status"], d["answer"]["text"], d["answer"]["by"]), ("answered", "a) measure first", "curator"))
        self.assertTrue(d["answer"]["auto"])
        self.assertEqual(d["notes"][-1]["text"], "common sense, not asked")
        # only open ones, and only with a recommendation
        rc, _, err = self.cli("decide-default", "D1")
        self.assertEqual(rc, 1)
        self.ask("--title", "no rec")
        rc, _, err = self.cli("decide-default", "D3", "--note", "no money involved after all")
        self.assertEqual(rc, 1)
        self.assertIn("no recommendation", err)

    def test_decide_default_needs_note_when_needs_dave(self):
        self.ask("--title", "Buy a proxy?", "--recommendation", "a) the free tier")
        rc, _, err = self.cli("decide-default", "D1", by="curator")
        self.assertEqual(rc, 1)
        self.assertIn("--note", err)
        self.assertIn("money: test", err)
        self.assertEqual(self.show("D1")["status"], "open")
        rc, _, err = self.cli("decide-default", "D1", "--note", "  ", by="curator")
        self.assertEqual(rc, 1)
        self.ok("decide-default", "D1", "--note", "the free tier costs nothing", by="curator")
        d = self.show("D1")
        self.assertEqual((d["status"], d["answer"]["text"], d["notes"][-1]["text"]),
                         ("answered", "a) the free tier", "the free tier costs nothing"))

    def test_inbox_gating(self):
        # untrusted lines without a valid needs_dave: only a calm one
        # with a recommendation and no broken needs_dave is decided
        self.inbox(
            {"title": "critical", "severity": "critical", "recommendation": "stop it"},
            {"title": "high", "severity": "high", "recommendation": "stop it"},
            {"title": "urgent", "urgency": "urgent", "recommendation": "stop it"},
            {"title": "money without why", "needs_dave": "money", "recommendation": "buy"},
            {"title": "why without criterion", "needs_dave_why": "costs 20 USD", "recommendation": "buy"},
            {"title": "no recommendation"},
            {"title": "mixed", "urgency": "normal", "severity": "critical", "recommendation": "stop it"},
            {"title": "spaced", "severity": " High ", "recommendation": "stop it"},
            {"title": "calm", "recommendation": "keep", "chose": "rm -rf / --no-preserve-root"},
            {"title": "ghsa moderate", "severity": "MODERATE", "recommendation": "bump"},
            {"title": "bidi \u202eevil", "recommendation": "keep"},
        )
        self.ok("list")
        by_title = {d["title"]: d for d in json.loads(self.ok("list", "--status", "all", "--json"))}
        for t in ("critical", "high", "urgent", "money without why", "why without criterion", "no recommendation",
                  "mixed", "spaced"):
            d = by_title[t]
            self.assertEqual((d["status"], d["answer"], d.get("needs_dave")), ("open", None, None), t)
            self.assertIn("left open for curation", d["notes"][-1]["text"], t)
        self.assertIn("not valid", by_title["money without why"]["notes"][-1]["text"])
        # GHSA's MODERATE is normal (decided, not rejected); bidi overrides dropped
        self.assertEqual(by_title["ghsa moderate"]["status"], "answered")
        self.assertIn("bidi evil", by_title)
        # chose ignored: the recommendation is the (unvetted) answer
        calm = by_title["calm"]
        self.assertEqual((calm["status"], calm["answer"]["text"], calm["answer"]["by"], calm["answer"]["unvetted"]),
                         ("answered", "keep", "inbox", True))
        self.assertNotIn("rm -rf", json.dumps(calm))
        self.assertIn("unvetted: re-judge it before acting", self.ok("show", calm["id"]))
        self.assertEqual(self.ok("list", "--status", "unvetted").count("\n"), 3)
        # a session vets it after re-judging: no longer unvetted
        self.ok("decide-default", calm["id"], by="infra")
        a = self.show(calm["id"])["answer"]
        self.assertEqual((a["by"], a.get("unvetted"), a["text"]), ("infra", None, "keep"))
        self.assertEqual(self.show(calm["id"])["notes"][-1]["text"], "common sense, vetted")
        # the brief counts the unsorted ones (8) so none hides
        self.assertIn("8 unsorted (curation pending)", self.ok("brief"))

    def test_inbox_refile_updates_auto_answer(self):
        t = "SearXNG update held back"
        self.inbox({"title": t, "recommendation": "keep the pin"})
        self.ok("list")
        self.assertEqual(self.show("D1")["answer"]["text"], "keep the pin")
        self.inbox({"title": t, "recommendation": "take it after review"})
        self.ok("list")
        d = self.show("D1")
        self.assertEqual((d["status"], d["recommendation"], d["answer"]["text"], d["answer"]["by"], d["seen"]),
                         ("answered", "take it after review", "take it after review", "inbox", 2))
        self.assertIn("automatic answer was (inbox): keep the pin", [n["text"] for n in d["notes"]])
        # a vetted answer (a session re-judged it) is not undone by job text
        self.ok("decide-default", "D1", by="infra")
        self.inbox({"title": t, "recommendation": "drop the pin"})
        self.ok("list")
        a = self.show("D1")["answer"]
        self.assertEqual((a["text"], a["by"], a.get("unvetted")), ("take it after review", "infra", None))
        self.assertEqual(self.show("D1")["recommendation"], "drop the pin")
        # refiled as critical: back to open for the curator, not decided
        self.inbox({"title": t, "recommendation": "drop the pin", "severity": "critical"})
        self.ok("list")
        d = self.show("D1")
        self.assertEqual((d["status"], d["answer"], d["urgency"]), ("open", None, "urgent"))
        # Dave's answer is never replaced by a refile
        self.ok("answer", "D1", "keep it")
        self.inbox({"title": t, "recommendation": "something else"})
        self.ok("list")
        d = self.show("D1")
        self.assertEqual((d["answer"]["text"], d["answer"]["by"], d["recommendation"]), ("keep it", "dave", "drop the pin"))

    def test_decided_on_dave_answered_title(self):
        self.ask("--title", "Buy a proxy?")
        self.ok("answer", "D1", "b) no proxy")
        rc, out, _ = self.cli("decided", "--title", "buy a PROXY", "--chose", "a", "--why", "cheap", by="infra")
        self.assertEqual(rc, 1)
        self.assertIn("answered by dave", out)
        d = self.show("D1")
        self.assertEqual((d["status"], d["answer"]["text"], d["answer"]["by"], d["seen"]), ("answered", "b) no proxy", "dave", 1))
        # one answered without needs_dave by hand (`answer`) is kept too
        self.ok("decided", "--title", "Keep engines off", "--chose", "off", "--why", "w", by="infra")
        self.ok("answer", "D2", "on, please")
        rc, out, _ = self.cli("decided", "--title", "Keep engines off", "--chose", "off", "--why", "w", by="infra")
        self.assertEqual(rc, 1)
        self.assertEqual(self.show("D2")["answer"]["text"], "on, please")

    def test_brief_shows_decided_count(self):
        self.ask("--title", "Buy a proxy?")
        self.ok("decided", "--title", "Keep SearXNG engines off", "--chose", "no change", "--why", "w")
        self.ok("decided", "--title", "Move rebuildable data (as of 2026-11-14)", "--chose", "symlinks", "--why", "w")
        self.ok("decided", "--title", "Test priming dictation", "--chose", "measure first", "--why", "w", "--done")
        # an open question without a reason (pre-bar) is not listed
        st = decision.Store(self.dir)
        with st:
            d, _ = st.create({"title": "pre-bar question", "needs_dave": "money: x"}, "t")
            del d["needs_dave"]
            st.put(d)
            # decided 2 days ago: not "since yesterday"
            old = st.get("D2")
            old["answer"]["at"] = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
            st.put(old)
        text = json.loads(self.ok("brief", "--json"))["text"]
        lines = text.splitlines()
        self.assertEqual(lines[0], "1 decision waiting for you (type /decisions in infra-space):")
        self.assertEqual(lines[1], "- Buy a proxy? (new)")
        self.assertEqual(lines[2], "Decided for you since yesterday: 2 (e.g. Test priming dictation, "
                                   "Move rebuildable data; ask to see all)")
        self.assertEqual(lines[3], "1 unsorted (curation pending)")
        self.assertNotIn("pre-bar", text)
        self.assertNotIn("SearXNG", text)
        self.assertEqual(len(lines), 4)
        # only decided ones: the line alone is still worth the message
        self.ok("answer", "D1", "a")
        self.assertTrue(self.ok("brief").startswith("Decided for you since yesterday: 2"))

    def test_brief(self):
        self.assertEqual(self.ok("brief"), "")  # nothing to say: nothing printed
        for i, (t, u) in enumerate([("low one", "low"), ("urgent one", "urgent"), ("normal one", "normal"),
                                    ("normal two", "normal"), ("normal three", "normal")]):
            self.ask("--title", t, "--urgency", u)
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
        self.ask("--title", "x")
        self.assertIn("could not be read", self.ok("brief", "--digest-failed"))
        self.ok("close", "D1")
        with open(digest, "w") as f:
            f.write("{broken")
        rc, out, err = self.cli("brief", "--digest-json", digest)
        self.assertEqual(rc, 0)
        self.assertIn("left out", err)

    def test_brief_recurring(self):
        rec = os.path.join(self.dir, "recurring.json")
        with open(rec, "w") as f:
            json.dump({"total": 3, "fresh": 1, "tasks": [
                {"task": "decisions-brief", "fresh": True, "problems": []},
                {"task": "nixpkgs-bump", "fresh": False, "what": "main's nixpkgs", "problems": [
                    {"kind": "run", "why": "late", "age": 30 * 3600, "slo": 26 * 3600},
                    {"kind": "result", "why": "old", "age": 25 * 86400, "slo": 7 * 86400}]},
                {"task": "storagebox-sync", "fresh": False, "problems": [{"kind": "exporter", "why": "host not reporting", "age": None}]},
            ]}, f)
        text = self.ok("brief", "--recurring-json", rec)
        self.assertIn("Recurring: 1/3 fresh", text)
        self.assertIn("- nixpkgs-bump: last success 30h ago (SLO 26h); main's nixpkgs 25d old (SLO 7d)", text)
        self.assertIn("- storagebox-sync: its host reports nothing", text)
        self.assertNotIn("decisions-brief", text)
        # all fresh: one line, still sent
        with open(rec, "w") as f:
            json.dump({"tasks": [{"task": "a", "fresh": True}, {"task": "b", "fresh": True}]}, f)
        self.assertEqual(self.ok("brief", "--recurring-json", rec).strip(), "Recurring: 2/2 fresh")
        # unreadable or failed: a line instead
        with open(rec, "w") as f:
            f.write("{broken")
        rc, out, err = self.cli("brief", "--recurring-json", rec)
        self.assertEqual(rc, 0)
        self.assertIn("status could not be read", out)
        self.assertIn("could not be read", self.ok("brief", "--recurring-failed"))
        # many stale: capped
        with open(rec, "w") as f:
            json.dump({"tasks": [{"task": f"t{i}", "fresh": False, "problems": [{"kind": "run", "why": "no success on record"}]}
                                 for i in range(9)]}, f)
        text = self.ok("brief", "--recurring-json", rec)
        self.assertIn("Recurring: 0/9 fresh", text)
        self.assertIn("- t0: no successful run on record", text)
        self.assertIn("- and 3 more", text)
        self.assertNotIn("- t6", text)
        self.assertEqual(decision.span(90 * 60), "90min")

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
        out = self.ok("list", "--status", "all")
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

        def boom(st, obj, by, force_new=False, auto=False, inbox=False):
            if obj.get("title") == "boom":
                raise OverflowError("date value out of range")
            return orig(st, obj, by, force_new, auto, inbox)
        decision.Store.create = boom
        try:
            self.inbox({"title": "boom"}, {"title": "ok one"})
            self.assertIn("ok one", self.ok("list", "--status", "all"))
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
        self.assertIn("during ingest", self.ok("list", "--status", "all"))

    def test_leftover_ingesting_file_taken_in(self):
        with open(os.path.join(self.dir, "inbox.jsonl.ingesting"), "w") as f:
            f.write(json.dumps({"title": "from a crashed run"}) + "\n")
        self.inbox({"title": "new"})
        out = self.ok("list", "--status", "all")
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
        self.ask("--title", "x")
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
                self.ask("--title", f"t{i}")
            rc, _, err = self.cli("add", "--needs-dave", "money: t", "--title", "one too many")
            self.assertEqual(rc, 1)
            self.assertIn("registry full", err)
            self.inbox({"title": "inbox too many"})
            self.ok("list")
            self.assertIn("registry full", self.read("inbox.rejected.jsonl"))
            self.ok("close", "D1")
            self.ask("--title", "room again")
        finally:
            decision.MAX_PENDING = old

    def test_log_rotation(self):
        old = decision.LOG_MAX_BYTES
        decision.LOG_MAX_BYTES = 300
        try:
            for i in range(10):
                self.ask("--title", f"title number {i}")
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

    def test_job_failed_lines(self):
        at = datetime(2026, 11, 15, 2, 0, tzinfo=timezone.utc)
        jobs = []
        for name, tag, verdict in [("cve-watch", "CVE-WATCH", "quiet"), ("security-audit", "SECURITY-AUDIT", "failed"),
                                   ("hygiene-report", "HYGIENE", None)]:
            d = os.path.join(self.dir, name)
            os.makedirs(d)
            with open(os.path.join(d, "2026-11-14T2000Z.log"), "w") as f:
                f.write("report\n" + (f"{tag}: {verdict}\n" if verdict else "") + "session_id: x\n")
            jobs.append({"name": name, "logDir": d, "verdictTag": tag, "okVerdicts": ["quiet", "all-clear", "clean"]})
        st = decision.Store(self.dir)
        with st:
            text, _ = decision.brief(st, None, at=at, jobs=jobs)
        self.assertNotIn("cve-watch", text)
        self.assertIn("security-audit failed in its last run", text)
        # no verdict, no lock holder: crashed
        self.assertIn("hygiene-report failed in its last run", text)
        self.assertFalse(decision.job_failed(jobs[0]["logDir"], "CVE-WATCH", ["quiet"], at + timedelta(days=2)))

    def test_new_marker(self):
        st = decision.Store(self.dir)
        with st:
            st.create({"title": "old", "created": "2026-01-01T00:00:00+00:00", "needs_dave": "money: x"}, "t")
            st.create({"title": "fresh", "needs_dave": "money: x"}, "t")
            text, _ = decision.brief(st, None, at=datetime.now(timezone.utc) + timedelta(hours=1))
        self.assertIn("- fresh (new)", text)
        self.assertIn("- old\n", text + "\n")


if __name__ == "__main__":
    unittest.main()
