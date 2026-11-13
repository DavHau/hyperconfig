"""Unit tests of the voice-gateway router: fake clock, mocked agents, ntfy,
announce and the OIDC/passkey step. Run: python -m pytest test_gateway.py
(the package's checkPhase does)."""

import asyncio
import json
import re

import pytest
from aiohttp.test_utils import TestClient, TestServer

import gateway as g

DEV = "sat-device"
OTHER = "other-device"
CODE = "407219"


class Clock:
    def __init__(self):
        self.t = 1_000_000.0

    def __call__(self):
        return self.t


@pytest.fixture
def env(tmp_path):
    seed = tmp_path / "seed"
    seed.write_text(CODE + "\n")
    cfg = {
        "stateDir": str(tmp_path),
        "publicUrl": "https://voice.example",
        "allowedDevices": [DEV],
        "idleMinutes": 10,
        "unlockPhrases": ["unlock", "trusted mode", "entsperren"],
        "offPhrases": ["trusted mode off", "lock", "trusted modus aus"],
        "unlockTtl": 120,
        "unlockRate": [3, 600],
        "replyTimeout": 5,
        "voiceCode": {"seedFile": str(seed), "maxUses": 5, "maxFails": 2, "challengeTtl": 30,
                      "startPhrases": ["what's on the list", "was steht auf der liste"]},
        "oidc": {"clientId": "voice", "authorizationEndpoint": "https://id.example/authorize",
                 "user": "dave", "group": "voice", "maxAuthAge": 60},
    }
    clock = Clock()
    calls, pushes, announces = [], [], []
    down = set()

    async def agent(name, text):
        calls.append((name, text))
        if name in down:
            raise g.AgentUnreachable(name)
        if name == "infra" and "done with admin" in text:
            gw.tool_lock("infra")  # what the agent does through MCP
            return "**Okay**, trusted mode is off."
        return f"{name} says hi"

    async def notify(title, message, **kw):
        pushes.append((title, message, kw))

    async def announce(msg):
        announces.append(msg)

    async def verify(code, flow, state):
        claims = {"nonce": flow.nonce, "auth_time": clock() - 5, "amr": ["phr"],
                  "preferred_username": "dave", "groups": ["voice"]}
        gw.check_claims(claims, flow)
        return claims

    gw = g.Gateway(cfg, clock=clock, agent_call=agent, notify=notify, announce=announce,
                   verify_login=verify)
    return type("Env", (), dict(gw=gw, clock=clock, calls=calls, pushes=pushes,
                                announces=announces, down=down, cfg=cfg, tmp=tmp_path))


def run(coro):
    return asyncio.run(coro)


async def settle():
    for _ in range(5):
        await asyncio.sleep(0)


def answer_for(gw, positions):
    code = gw.state["code"]
    return str(sum(int(code[p - 1]) for p in positions) % 10)


async def passkey_unlock(e, client=None):
    r = await e.gw.handle("Unlock", DEV)
    assert r == "Check your phone."
    url = e.pushes[-1][2]["click"]
    uid = url.rsplit("/", 1)[1]
    assert e.gw.begin_unlock(uid)
    state, auth_url = e.gw.oidc_start(f"unlock:{uid}")
    assert "prompt=login" in auth_url and "max_age=0" in auth_url
    flow = e.gw.flows.pop(state)
    await e.gw.verify_login("code", flow, state)
    assert e.gw.complete_unlock(uid)


# ------------------------------------------------------------------ routing
def test_untrusted_goes_to_voice_agent(env):
    async def t():
        r = await env.gw.handle("What's the weather?", DEV)
        assert r == "voice says hi"
        assert env.calls == [("voice", "What's the weather?")]
    run(t())


def test_passkey_unlock_then_infra_then_idle_relock(env):
    async def t():
        await passkey_unlock(env)
        await settle()
        assert env.gw.trusted_device == DEV
        assert "Trusted mode on." in env.announces
        assert await env.gw.handle("deploy som", DEV) == "infra says hi"
        # another device stays untrusted
        assert await env.gw.handle("hello", OTHER) == "voice says hi"
        # activity keeps it on past 10 minutes in total
        for _ in range(3):
            env.clock.t += 9 * 60
            assert await env.gw.handle("status?", DEV) == "infra says hi"
        # 10 minutes idle relock
        env.clock.t += 10 * 60
        env.gw.tick()
        await settle()
        assert env.gw.trusted_device is None
        assert env.announces[-1] == "Trusted mode off."
        assert env.pushes[-1][0] == "Trusted mode off"
        assert await env.gw.handle("status?", DEV) == "voice says hi"
    run(t())


def test_unlock_link_single_use_and_expiry(env):
    async def t():
        await env.gw.handle("unlock", DEV)
        uid = env.pushes[-1][2]["click"].rsplit("/", 1)[1]
        assert env.gw.begin_unlock(uid)
        assert not env.gw.begin_unlock(uid)  # single use
        await env.gw.handle("unlock", DEV)
        uid2 = env.pushes[-1][2]["click"].rsplit("/", 1)[1]
        env.clock.t += 121
        assert not env.gw.begin_unlock(uid2)  # expired
        # rate limit: third request ok, fourth refused within 10 min
        env.clock.t += 1
        assert await env.gw.handle("unlock", DEV) == "Check your phone."
        assert "Too many" in await env.gw.handle("unlock", DEV)
    run(t())


def test_unlock_needs_known_device(env):
    async def t():
        assert await env.gw.handle("unlock", OTHER) == "voice says hi"
        assert not env.pushes
    run(t())


def test_claims_checks(env):
    flow = g.OidcFlow("code", "v", "n", env.clock())
    good = {"nonce": "n", "auth_time": env.clock() - 3, "amr": ["phr"],
            "preferred_username": "dave", "groups": ["voice"]}
    env.gw.check_claims(good, flow)
    for bad in ({"auth_time": env.clock() - 600}, {"preferred_username": "eve"},
                {"groups": []}, {"nonce": "x"}):
        with pytest.raises(PermissionError):
            env.gw.check_claims({**good, **bad}, flow)


def test_tool_relock_free_form(env):
    async def t():
        await passkey_unlock(env)
        r = await env.gw.handle("I'm done with admin stuff", DEV)
        assert r == "Okay, trusted mode is off."  # markdown stripped
        assert env.gw.trusted_device is None
        assert await env.gw.handle("hi", DEV) == "voice says hi"
        assert env.gw.tool_lock("voice") == "Trusted mode was already off."
    run(t())


def test_fallback_phrase_when_infra_unreachable(env):
    async def t():
        await passkey_unlock(env)
        env.down.add("infra")
        assert "not reachable" in await env.gw.handle("deploy", DEV)
        assert env.gw.trusted
        assert await env.gw.handle("Trusted mode off", DEV) == "Trusted mode off."
        assert not env.gw.trusted
    run(t())


# --------------------------------------------------------------- voice code
async def do_challenge(e, right=(True, True), lang="en", phrase="What's on the list?"):
    r = await e.gw.handle(phrase, DEV, lang)
    if not e.gw.challenge:
        return r
    for ok in right:
        ch = e.gw.challenge
        a = answer_for(e.gw, ch.positions)
        if not ok:
            a = str((int(a) + 1) % 10)
        words = g.DE_DIGITS if lang == "de" else g.EN_DIGITS
        r = await e.gw.handle(words[int(a)].capitalize() + ".", DEV, lang)
        if not ok:
            return r
    return r


def test_voice_code_correct_unlocks_and_not_forwarded(env):
    async def t():
        r = await env.gw.handle("what's on the list", DEV)
        assert re.fullmatch(r"(Zero|One|Two|Three|Four|Five|Six), (One|Two|Three|Four|Five|Six)\.", r)
        p = env.gw.challenge.positions
        assert len(set(p)) == 2 and all(1 <= x <= 6 for x in p)
        r = await env.gw.handle(answer_for(env.gw, p), DEV)  # "7" etc.
        assert env.gw.challenge.round == 2
        p2 = env.gw.challenge.positions
        r = await env.gw.handle("the answer is " + g.EN_DIGITS[int(answer_for(env.gw, p2))], DEV)
        assert r == "Trusted mode on."
        await settle()
        assert env.gw.trusted_device == DEV
        assert env.calls == []  # nothing of the challenge reached an agent
        assert any("voice code" in m for _, m, _ in env.pushes)
        assert env.gw.state["uses"] == 1
    run(t())


def test_voice_code_german(env):
    async def t():
        r = await do_challenge(env, lang="de", phrase="Was steht auf der Liste")
        assert r == "Trusted mode on."
    run(t())


def test_voice_code_two_wrong_locks_until_passkey(env):
    async def t():
        assert await do_challenge(env, (False,)) == "No."
        env.clock.t += 86400  # not reset by time
        assert await do_challenge(env, (True, False)) == "No."
        await settle()
        assert sum(1 for t_, _, _ in env.pushes if "wrong" in t_) == 2
        assert env.gw.state["fails"] == 2
        r = await env.gw.handle("what's on the list", DEV)
        assert r == "The list is empty." and env.gw.challenge is None
        assert env.calls == []
        await passkey_unlock(env)
        env.gw.relock("test")
        assert await do_challenge(env) == "Trusted mode on."
    run(t())


def test_voice_code_expires_after_five_uses_and_rotation(env):
    async def t():
        for _ in range(5):
            assert await do_challenge(env) == "Trusted mode on."
            env.gw.relock("test")
        await settle()
        assert any("new code needed" in t_ for t_, _, _ in env.pushes)
        assert await env.gw.handle("what's on the list", DEV) == "The list is empty."
        new = env.gw.rotate_code()
        assert re.fullmatch(r"\d{6}", new)
        state = json.loads((env.tmp / "state.json").read_text())
        assert state["code"] == new and state["uses"] == 0
        assert oct((env.tmp / "state.json").stat().st_mode & 0o777) == "0o600"
        assert await do_challenge(env) == "Trusted mode on."
    run(t())


def test_challenge_timeout_is_not_a_failure(env):
    async def t():
        await env.gw.handle("what's on the list", DEV)
        env.clock.t += 31
        assert await env.gw.handle("seven", DEV) == "voice says hi"
        assert env.gw.state["fails"] == 0
    run(t())


def test_state_survives_restart(env):
    env.gw.rotate_code()
    gw2 = g.Gateway(env.cfg, clock=env.clock, agent_call=env.gw.agent_call,
                    notify=env.gw.notify, announce=env.gw.announce)
    assert gw2.state["code"] == env.gw.state["code"] != CODE


def test_parse_digit():
    assert g.parse_digit(g.normalize("Neun.")) == 9
    assert g.parse_digit(g.normalize("9")) == 9
    assert g.parse_digit(g.normalize("fünf")) == 5
    assert g.parse_digit(g.normalize("one two")) is None


# ------------------------------------------------------------------- HTTP
def test_http_surfaces(env, tmp_path):
    secret = tmp_path / "ha"
    secret.write_text("s3cret")

    async def t():
        ha = TestClient(TestServer(g.ha_app(env.gw, lambda: "s3cret")))
        web_ = TestClient(TestServer(g.web_app(env.gw)))
        mcp = TestClient(TestServer(g.mcp_app(env.gw, lambda: {"infra": "tok-i", "voice": "tok-v"})))
        for c in (ha, web_, mcp):
            await c.start_server()
        try:
            r = await ha.post("/v1/converse", json={"text": "hi", "device_id": DEV})
            assert r.status == 401
            r = await ha.post("/v1/converse", json={"text": "hi", "device_id": DEV},
                              headers={"Authorization": "Bearer s3cret"})
            assert (await r.json())["speech"] == "voice says hi"
            # the unlock page redirects to the IdP with prompt=login
            await env.gw.handle("unlock", DEV)
            path = "/unlock/" + env.pushes[-1][2]["click"].rsplit("/", 1)[1]
            r = await web_.get(path, allow_redirects=False)
            assert r.status == 302 and "prompt=login" in r.headers["Location"]
            r = await web_.get(path, allow_redirects=False)
            assert r.status == 410
            # MCP
            r = await mcp.post("/mcp", json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
            assert r.status == 401
            h = {"Authorization": "Bearer tok-v"}
            r = await mcp.post("/mcp", json={"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                             "params": {"protocolVersion": "2025-06-18"}}, headers=h)
            assert (await r.json())["result"]["serverInfo"]["name"] == "voice-gateway"
            r = await mcp.post("/mcp", json={"jsonrpc": "2.0", "method": "notifications/initialized"}, headers=h)
            assert r.status == 202
            r = await mcp.post("/mcp", json={"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, headers=h)
            tools = (await r.json())["result"]["tools"]
            assert [x["name"] for x in tools] == ["voice_trusted_mode_off"]
            env.gw.enter_trusted(DEV, "test")
            r = await mcp.post("/mcp", json={"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                             "params": {"name": "voice_trusted_mode_off", "arguments": {}}},
                               headers=h)
            assert "off now" in (await r.json())["result"]["content"][0]["text"]
            assert not env.gw.trusted
        finally:
            for c in (ha, web_, mcp):
                await c.close()
    run(t())



def test_session_rotates_after_idle(env):
    gw = env.gw
    gw.cfg["agents"] = {"voice": {"session": "voice"}}
    a = gw.session_id("voice")
    env.clock.t += 60
    assert gw.session_id("voice") == a          # follow-up keeps context
    env.clock.t += 11 * 60
    b = gw.session_id("voice")
    assert b != a and b.startswith("voice-")    # new conversation after 10 min silence



def test_reply_language():
    assert g.reply_language("What time is it?") == "English"
    assert g.reply_language("Turn on the aircon in the living room.") == "English"
    assert g.reply_language("Wie spät ist es?") == "German"
    assert g.reply_language("Schalt die Klimaanlage an.") == "German"
    assert g.reply_language("ปิดแอร์") == "Thai"
    assert g.with_language("What time is it?").endswith("(Dave spoke English. Reply in English only.)")


# --------------------------------------------------- follow-up listening
def scripted(env, replies):
    """Agent replies from a list (the last one repeats)."""
    async def agent(name, text):
        env.calls.append((name, text))
        return replies.pop(0) if len(replies) > 1 else replies[0]
    env.gw.agent_call = agent


def test_marker_continues_and_is_stripped(env):
    async def t():
        scripted(env, ["Which room, living room or bedroom? [listen]", "Done."])
        assert await env.gw.turn("Turn on the light", DEV) == ("Which room, living room or bedroom?", True)
        env.clock.t += 5
        assert await env.gw.turn("The living room.", DEV) == ("Done.", False)
    run(t())


def test_bare_question_mark_does_not_continue(env):
    async def t():
        scripted(env, ["It is sunny. Anything else?"])
        assert await env.gw.turn("Weather?", DEV) == ("It is sunny. Anything else?", False)
    run(t())


def test_http_returns_continue_flag(env):
    async def t():
        scripted(env, ["Should I? [listen]"])
        ha = TestClient(TestServer(g.ha_app(env.gw, lambda: "s")))
        await ha.start_server()
        try:
            r = await ha.post("/v1/converse", json={"text": "do it", "device_id": DEV},
                              headers={"Authorization": "Bearer s"})
            assert await r.json() == {"speech": "Should I?", "continue_conversation": True}
        finally:
            await ha.close()
    run(t())


def test_conversation_mode_on_off(env):
    async def t():
        scripted(env, ["Sure."])
        assert await env.gw.turn("Let's talk.", DEV) == ("Okay, I'm listening.", True)
        assert env.calls == []
        for q in ("How are you?", "Tell me more."):
            env.clock.t += 8
            assert await env.gw.turn(q, DEV) == ("Sure.", True)
        env.clock.t += 8
        assert await env.gw.turn("That's all.", DEV) == ("Okay.", False)
        env.clock.t += 8
        assert await env.gw.turn("Weather?", DEV) == ("Sure.", False)
        assert await env.gw.turn("Lass uns reden.", DEV) == ("Okay, ich höre zu.", True)
        env.clock.t += 5
        assert await env.gw.turn("Das war's.", DEV) == ("Alles klar.", False)
        assert len(env.calls) == 3
    run(t())


def test_conversation_mode_other_phrases_and_idle(env):
    async def t():
        scripted(env, ["Sure."])
        assert (await env.gw.turn("Lass uns quatschen", DEV))[1]
        env.clock.t += 5
        assert (await env.gw.turn("Ende", DEV)) == ("Alles klar.", False)
        assert (await env.gw.turn("conversation mode", DEV))[1]
        # 5 min without speech: the reopened mic gave nothing, mode is over
        env.clock.t += 301
        assert await env.gw.turn("hello", DEV) == ("Sure.", False)
        # a stop word outside any follow-up is a normal request
        assert await env.gw.turn("stop", DEV) == ("Sure.", False)
        # "conversation mode off" is not "on"
        assert await env.gw.turn("conversation mode off", DEV) == ("Sure.", False)
    run(t())


def test_filler_or_empty_followup_ends_chain(env):
    async def t():
        scripted(env, ["Which one? [listen]"])
        for chatter in ("you", "Oh.", "All that.", ""):
            env.calls.clear()
            assert (await env.gw.turn("Turn on the light", DEV))[1]
            env.clock.t += 5
            assert await env.gw.turn(chatter, DEV) == ("", False)
            assert len(env.calls) == 1  # chatter never reached the agent
        # a short confirmation is an answer, not filler
        assert (await env.gw.turn("Turn on the light", DEV))[1]
        env.clock.t += 5
        assert (await env.gw.turn("Okay.", DEV))[0] == "Which one?"
        env.clock.t += 5
        assert (await env.gw.turn("Ja", DEV))[0] == "Which one?"
        env.clock.t += 120
        # in conversation mode too
        assert (await env.gw.turn("let's talk", DEV))[1]
        env.clock.t += 5
        assert await env.gw.turn("you", DEV) == ("", False)
        env.clock.t += 5
        assert await env.gw.turn("Hi", DEV) == ("Which one?", True)  # wake-word turn, mode off
    run(t())


def test_silence_after_reopen_ends_chain(env):
    async def t():
        scripted(env, ["Sure."])
        assert (await env.gw.turn("let's talk", DEV))[1]
        env.clock.t += 60  # no answer on the reopened mic (HA never calls us)
        assert await env.gw.turn("What time is it", DEV) == ("Sure.", False)
    run(t())


def test_followup_cap(env):
    async def t():
        scripted(env, ["Really? [listen]"])
        conts = []
        for _ in range(12):
            conts.append((await env.gw.turn("yes, go on please", DEV))[1])
            env.clock.t += 5
        assert conts[:10] == [True] * 10 and conts[10] is False
        # a fresh wake-word turn starts a new chain
        env.clock.t += 120
        assert (await env.gw.turn("one more thing please", DEV))[1]
    run(t())


def test_followups_per_device(env):
    async def t():
        scripted(env, ["Sure."])
        assert (await env.gw.turn("let's talk", DEV))[1]
        assert await env.gw.turn("hello there", OTHER) == ("Sure.", False)
        assert await env.gw.turn("hello there", DEV) == ("Sure.", True)
    run(t())


def test_late_reply_strips_marker(env):
    async def t():
        async def slow(name, text):
            await asyncio.sleep(0.05)
            return "Finished. Shall I deploy? [listen]"
        env.gw.agent_call = slow
        env.gw.cfg["replyTimeout"] = 0.01
        r = await env.gw.turn("build it", DEV)
        assert r[1] is False and "still working" in r[0]
        await asyncio.sleep(0.1)
        await settle()
        assert env.announces == ["Finished. Shall I deploy?"]
    run(t())


def test_time_injection(env, monkeypatch):
    monkeypatch.setenv("TZ", "<+07>-7")  # POSIX form: no tzdata in the build sandbox
    import time as _t
    _t.tzset()
    try:
        env.clock.t = 1794575340.0  # 2026-11-13 13:09 UTC
        assert g.time_line(env.clock()) == "Current time: Fri 2026-11-13 20:09 (+07)"
        c = env.gw.user_content("What time is it?")
        assert c.startswith("What time is it?\n\n(Dave spoke English.")
        assert c.endswith("(Current time: Fri 2026-11-13 20:09 (+07))")
        assert "use it, never guess" in " ".join(g.SPOKEN_PREFIX.split())
    finally:
        monkeypatch.delenv("TZ")
        _t.tzset()
