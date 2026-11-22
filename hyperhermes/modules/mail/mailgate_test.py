"""Offline Mailgate policy, delivery and promotion tests with no live relay or IMAP."""

import asyncio
import base64
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from typing import Any
from unittest import mock

from sanitize_test import AUTHSERV, DKIM_OK, DMARC_OK, SIG_OK, ar, raw


class TrustedAlias(unittest.IsolatedAsyncioTestCase):
    agent = "infra"
    base = "infra@agents.test"
    alias = "infra+claude-proton@agents.test"
    other = "infra+other@agents.test"
    domain = "mail.anthropic.com"

    def setUp(self):
        state = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (state / "raw").mkdir()
        config = state / "config.json"
        config.write_text(json.dumps({
            "domain": "agents.test", "hostname": AUTHSERV, "stateDir": str(state),
            "ownerOrigin": "https://owner.agents.test",
            "agents": {self.agent: {"owners": ["dave"], "allowDomains": False}},
            "limits": {
                "messageBytes": 1048576, "quarantineKeepBytes": 1048576,
                "quarantineMessages": 50, "quarantineBytes": 1048576,
                "quarantineSourceMessages": 50, "quarantineSourceBytes": 1048576,
                "quarantineDays": 14, "activeAliases": 20, "aliasesPerDay": 20, "summaryQueue": 10,
                "workerMemoryBytes": 671088640, "workerSeconds": 10, "attachmentBytes": 1048576,
            },
        }))
        spec = importlib.util.spec_from_file_location("mailgate", Path(__file__).with_name("mailgate.py"))
        assert spec is not None and spec.loader is not None
        self.gate = importlib.util.module_from_spec(spec)
        with mock.patch.dict(os.environ, MAILGATE_CONFIG=str(config)):
            spec.loader.exec_module(self.gate)
        self.addCleanup(self.gate.DB.close)
        self.append = self.enterContext(mock.patch.object(self.gate, "imap_append"))
        self.gate.alias_create(self.agent, "claude-proton", False, None, "Claude via Proton", "agent")
        self.gate.alias_create(self.agent, "other", False, self.domain, "ordinary bound alias", "agent")

    def enable_trust(self):
        self.gate.AGENTS[self.agent]["trustedAliasDomains"] = {self.alias: self.domain}

    def message(self, local="rotated", domain=None, *, dmarc=True, dkim_domain=None, extra=""):
        domain = domain or self.domain
        dkim_domain = domain if dkim_domain is None else dkim_domain
        results = []
        headers = [f"From: {local}@{domain}", "Subject: login code", extra]
        if dkim_domain:
            results.append(DKIM_OK.replace("lax.test", dkim_domain))
            headers.insert(0, SIG_OK.replace("lax.test", dkim_domain))
        results.append(DMARC_OK.replace("lax.test", domain).replace("=pass", "=pass" if dmarc else "=fail"))
        headers.insert(0, ar(AUTHSERV + "; " + "; ".join(results)))
        return raw("\n".join(headers), body="hello\r\n")

    async def deliver(self, rcpt, *args, sticky=(), **kwargs):
        data = self.message(*args, **kwargs)
        a = await self.gate.analyze(data)
        self.assertIsNotNone(a)
        return await self.gate.file_message(rcpt, self.gate.store_raw(data), len(data), a, sticky, data)

    async def test_only_exact_authenticated_domain_on_existing_alias(self):
        self.enable_trust()
        for local in ("no-reply-first", "no-reply-rotated"):
            self.assertTrue(await self.deliver(self.alias, local))
        for rcpt in (self.base, self.other):
            self.assertFalse(await self.deliver(rcpt))
        blocked: list[dict[str, Any]] = [
            {"domain": "relay.mail.anthropic.com"}, {"domain": "mail.anthropic.com.evil.test"},
            {"dmarc": False}, {"dkim_domain": ""}, {"dkim_domain": "relay.mail.anthropic.com"},
            {"extra": "From: second@mail.anthropic.com"}, {"local": "bad@"},
        ]
        for opts in blocked:
            with self.subTest(opts=opts):
                self.assertFalse(await self.deliver(self.alias, **opts))
        # Existing runtime binding remains an independent veto, and the
        # declarative binding also constrains regular single-address entries.
        await self.gate.allow_add(self.agent, "match@relay.mail.anthropic.com", "admin")
        self.assertFalse(await self.deliver(self.alias, "match", "relay.mail.anthropic.com"))
        await self.gate.alias_revoke([self.agent], self.alias, "agent")
        self.assertIsNone(await self.deliver(self.alias))
        with self.assertRaisesRegex(self.gate.ApiError, "only the owner"):
            self.gate.alias_create(self.agent, "claude-proton", False, None, "", "agent")
        self.gate.alias_create(self.agent, "claude-proton", False, "elsewhere.test", "", "owner:dave")
        self.assertFalse(await self.deliver(self.alias))
        self.assertEqual(self.append.call_count, 2)

    async def test_startup_promotes_only_eligible_copy_and_owner_can_override(self):
        copies: list[tuple[str, dict[str, Any]]] = [
            (self.alias, {}), (self.base, {}), (self.other, {}),
            (self.alias, {"dkim_domain": ""}), (self.alias, {"sticky": ["truncated"]}),
            (self.alias, {"local": "expired"}),
        ]
        for rcpt, opts in copies:
            self.assertFalse(await self.deliver(rcpt, **opts))
        ids = [r["id"] for r in self.gate.q("SELECT id FROM messages ORDER BY rowid")]
        self.gate.DB.execute("UPDATE messages SET received_at = 0 WHERE id = ?", (ids[-1],))
        self.enable_trust()
        await self.gate.alias_revoke([self.agent], self.alias, "owner:dave")
        await self.gate.release_trusted_aliases()
        self.assertEqual(self.append.call_count, 0)
        self.gate.alias_create(self.agent, "claude-proton", False, None, "", "owner:dave")
        await self.gate.release_trusted_aliases()
        self.assertEqual([r["id"] for r in self.gate.q("SELECT id FROM messages WHERE folder='inbox'")], ids[:1])
        await self.gate.alias_revoke([self.agent], self.alias, "owner:dave")
        self.assertEqual(await self.gate.release(self.agent), 0)
        result = await self.gate.release_one(self.agent, ids[3], "owner:dave")
        self.assertIn("no-dkim-for-from-domain", result["despite"])
        self.assertEqual(self.append.call_count, 2)

    async def check_revoke_waits_for_append(self, filing, *, cancel=False):
        started, revoke_started = asyncio.Event(), asyncio.Event()
        finish = threading.Event()
        loop = asyncio.get_running_loop()
        order = []

        def append(agent, data):
            loop.call_soon_threadsafe(started.set)
            if not finish.wait(5):
                raise AssertionError("test did not unblock APPEND")
            order.append("appended")

        async def revoke():
            revoke_started.set()
            result = await self.gate.agent_op(self.agent, {"op": "alias.revoke", "address": self.alias.upper()})
            order.append("revoked")
            return result

        self.append.side_effect = append
        delivery = asyncio.create_task(filing)
        revocation = None
        try:
            await asyncio.wait_for(started.wait(), 5)
            if cancel:
                delivery.cancel()
            revocation = asyncio.create_task(revoke())
            # revoke() runs up to the lock (or returns) before this resumes.
            await asyncio.wait_for(revoke_started.wait(), 5)
            self.assertFalse(revocation.done(), "revocation returned before APPEND completed")
            self.assertIsNotNone(self.gate.resolve(self.alias), "revocation committed before APPEND completed")
            # An unrelated alias of the same agent must not wait for this APPEND.
            other = await asyncio.wait_for(self.gate.admin_op({"op": "alias-revoke", "address": self.other}), 1)
            self.assertTrue(other["revoked"])
        finally:
            finish.set()
            await asyncio.gather(*(t for t in (delivery, revocation) if t is not None), return_exceptions=True)
            self.append.side_effect = None
        if cancel:
            self.assertTrue(delivery.cancelled())
        else:
            delivery.result()
        self.assertEqual(revocation.result(), {"address": self.alias, "revoked": True})
        self.assertEqual(order, ["appended", "revoked"])
        self.assertIsNone(await self.deliver(self.alias, "after-revoke"))
        self.assertEqual(self.append.call_count, 1)
        self.assertFalse(self.gate.RECIPIENT_LOCKS)

    async def test_startup_promotion_serializes_with_revocation(self):
        self.assertFalse(await self.deliver(self.alias))
        self.enable_trust()
        await self.check_revoke_waits_for_append(self.gate.release_trusted_aliases())
        self.assertEqual([r["folder"] for r in self.gate.q("SELECT folder FROM messages")], ["inbox"])

    async def test_inbound_delivery_serializes_with_revocation(self):
        self.enable_trust()
        await self.check_revoke_waits_for_append(self.deliver(self.alias))
        self.assertEqual([r["folder"] for r in self.gate.q("SELECT folder FROM messages")], ["inbox"])

    async def test_cancelled_delivery_still_holds_revocation_until_append_finishes(self):
        self.enable_trust()
        await self.check_revoke_waits_for_append(self.deliver(self.alias), cancel=True)
        self.assertEqual([r["folder"] for r in self.gate.q("SELECT folder FROM messages")], ["inbox"])

    async def test_lmtp_disconnect_while_queued_files_only_on_retry(self):
        gate = self.gate
        self.enable_trust()
        gate.CFG["lmtpUser"] = "relay"
        self.enterContext(mock.patch.object(gate, "LMTP_SECRET", "fixture"))
        auth = base64.b64encode(b"\0relay\0fixture")
        data = self.message()
        delivered = b"250 2.0.0 Delivered\r\n"

        def session():
            reader = asyncio.StreamReader()
            writer = mock.Mock(is_closing=mock.Mock(return_value=False), drain=mock.AsyncMock())
            reader.feed_data(b"AUTH PLAIN " + auth + b"\r\nMAIL FROM:<sender@example.test>\r\n"
                             + f"RCPT TO:<{self.alias}>\r\nDATA\r\n".encode() + data + b".\r\n")
            return reader, writer

        lock = gate.recipient_lock(self.alias)
        queued = asyncio.Event()
        acquire = lock.acquire

        async def acquire_queued():
            queued.set()
            return await acquire()

        reader, writer = session()
        async with lock:
            with mock.patch.object(lock, "acquire", acquire_queued):
                abandoned = asyncio.create_task(gate.Lmtp(reader, writer).run())
                try:
                    await asyncio.wait_for(queued.wait(), 5)
                finally:
                    reader.feed_eof()  # DATA consumed; the real lock still holds filing back
        await asyncio.wait_for(abandoned, 5)
        prior_appends = self.append.call_count
        prior_replies = list(writer.write.call_args_list)

        reader, writer = session()

        def quit_after_delivery(reply):
            if reply == delivered:
                reader.feed_data(b"QUIT\r\n")

        writer.write.side_effect = quit_after_delivery
        await asyncio.wait_for(gate.Lmtp(reader, writer).run(), 5)
        writer.write.assert_any_call(delivered)
        self.assertEqual(self.append.call_count, 1, "the disconnected session and retry must not both file")
        self.assertEqual(prior_appends, 0)
        self.assertEqual(prior_replies[-1], mock.call(b"354 End data with <CR><LF>.<CR><LF>\r\n"))
        self.assertEqual([r["folder"] for r in gate.q("SELECT folder FROM messages")], ["inbox"])

    async def test_pending_domain_request_and_runtime_writes_stay_restricted(self):
        gate = self.gate
        gate.DB.execute("INSERT INTO requests (id, agent, entry, reason, created_at) VALUES (34, ?, ?, 'test', 0)",
                        (self.agent, "@" + self.domain))
        self.enable_trust()
        request = mock.Mock(headers={"X-Mailgate-Account": "dave", "Origin": gate.CFG["ownerOrigin"]})
        page = await gate.owner_page(request)
        self.assertIn("Trusted exact From domain (Nix)", page.text)
        self.assertIn(self.alias, page.text)
        for data in ({"op": "allow", "entry": "@" + self.domain}, {"op": "confirm", "id": "34"},
                     {"op": "confirm-all", "ids": "34"}):
            request.post = mock.AsyncMock(return_value=data | {"agent": self.agent, "csrf": gate.csrf_token("dave")})
            self.assertEqual((await gate.owner_action(request)).status, 400)
        for op in ({"op": "allow", "agent": self.agent, "entry": "@" + self.domain}, {"op": "confirm", "id": 34}):
            with self.assertRaisesRegex(gate.ApiError, "single addresses only"):
                await gate.admin_op(op)
        with self.assertRaisesRegex(gate.ApiError, "single addresses only"):
            gate.request_allow(self.agent, "@" + self.domain, "test")
        self.assertEqual(gate.requests_of([self.agent])[0]["state"], "pending")
        self.assertEqual(gate.allowlist(self.agent), [])
        self.assertEqual((await gate.admin_op({"op": "deny", "id": 34}))["state"], "denied")
        self.assertTrue(await self.deliver(self.alias))
        self.assertFalse(await self.deliver(self.base))
