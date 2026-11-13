"""voice-gateway: routes Home Assistant Assist turns to hermes agents.

Untrusted by default (the `voice` agent); trusted (the infra agent) after a
passkey unlock (ntfy push -> pocket-id with forced re-authentication) or the
voice-code challenge, bound to the satellite that asked, ended by 10 minutes
without a request from it or by the agents' MCP tool voice_trusted_mode_off.
See ./default.nix for the deployment and the threat notes.

Three listeners (one aiohttp app each, so a path cannot be reached on the
wrong port):
  ha   POST /v1/converse      Home Assistant's hermes_conversation entity
  web  GET  /unlock/<id>, /code, /callback, POST /code/rotate  (via edi)
  mcp  POST /mcp              streamable-HTTP MCP, one tool, bearer per agent

Never logged: the voice code, challenge positions, challenge answers.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import hmac
import html
import json
import logging
import os
import re
import secrets
import socket
import time
import unicodedata
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable, Optional

from aiohttp import BasicAuth, ClientSession, ClientTimeout, web

log = logging.getLogger("voice-gateway")
_rng = secrets.SystemRandom()

SPOKEN_PREFIX = """\
You are answering Dave through a voice satellite (Home Assistant Voice PE):
your reply is converted to speech. Reply in 1-3 short spoken sentences, no
markdown, no lists, no code, no URLs. Always answer in the language of
Dave's latest message (English, German or Thai), even if earlier turns
were in another language. Plain punctuation only, no typographic
quotes or dashes. Do not end with filler follow-ups such as "anything
else?": Dave says the wake word when he wants more. Only when your reply
really needs an answer from Dave to go on (a question you must ask, a
choice between options, a confirmation before you act), end it with the
marker [listen]: the microphone then reopens for his answer without the
wake word. Never add [listen] otherwise; a question mark alone does not
reopen the microphone. Each message carries the current local time; use
it, never guess the time. Never read out secrets, tokens,
passwords, keys or codes. If a task takes longer than a few seconds, say
briefly that you are on it, keep working, and report the result later via
Dave's normal channel (Telegram or the desktop app), not here.
When Dave says in any wording that he wants to leave or end trusted mode or
admin mode (e.g. "I'm done with admin stuff", "lock it again"), call the tool
voice_trusted_mode_off and confirm in a few words. There is no tool to turn
trusted mode on: if he asks for that, tell him to say "unlock".
"""

# Reply language per turn, from the transcript itself (speech-stt picked
# the language when it transcribed it). Same rule as speech-tts's
# guess_lang: Thai script -> Thai; else German vs English function words,
# umlauts count triple; a tie stays English.
_THAI = re.compile("[\u0e00-\u0e7f]")
_DE = set("""der die das den dem des ein eine einen einem einer und oder aber doch denn weil wenn dass ob
als wie ist sind war bin bist hat habe hast haben wird werden kann kannst muss soll will willst möchte ich
du er sie es wir ihr mich dich mir dir uns kein keine nicht nichts noch schon auch nur sehr mal jetzt hier
heute bitte danke ja nein alles mach macht gib zu zum zur im am auf aus bei mit nach von vor über für
was wer wo wann warum welche viel mehr etwas einfach genau schalt schalte stell an aus""".split())
_EN = set("""the a an and or but because if that is are was were be am has have had will would can could
must should do does did i you he she it we they me him her us them my your no not still already also only
very now here today please thanks yes sure let tell give make to of in on at from by with for about what
who where when why which much more something turn set put off""".split())


def reply_language(text: str) -> str:
    if _THAI.search(text):
        return "Thai"
    low = text.lower()
    w = re.findall(r"[a-zäöüß]+", low)
    de = sum(x in _DE for x in w) + 3 * len(re.findall("[äöüß]", low))
    en = sum(x in _EN for x in w)
    return "German" if de > en else "English"


def with_language(text: str) -> str:
    lang = reply_language(text)
    return f"{text}\n\n(Dave spoke {lang}. Reply in {lang} only.)"


def time_line(t: float) -> str:
    """'Current time: Fri 2026-11-13 20:09 (+07)' in the host's zone: the
    agent guessed the time otherwise (said 20:21 at 20:09)."""
    lt = time.localtime(t)
    z = time.strftime("%z", lt)
    z = z[:3] if z.endswith("00") else f"{z[:3]}:{z[3:]}"
    return f"Current time: {time.strftime('%a %Y-%m-%d %H:%M', lt)} ({z})"


# ------------------------------------------------- follow-up listening
# The agent ends a reply with LISTEN_MARKER when it really needs an answer
# (question, choice, confirmation); the gateway strips it and answers HA
# with continue_conversation, so the satellite reopens its microphone
# without the wake word. A bare "?" does not (HA's default did, and room
# chatter then became the next turn: a loop).
LISTEN_MARKER = re.compile(r"\s*\[\s*listen\s*\]\s*", re.I)


def split_marker(reply: str) -> tuple[str, bool]:
    if not LISTEN_MARKER.search(reply or ""):
        return reply, False
    return LISTEN_MARKER.sub(" ", reply).strip(), True


# STT of room noise or chatter on a reopened microphone ("you", "Oh.",
# "All that."): such a follow-up ends the chain instead of reaching the
# agent.
# Confirmations ("okay", "yeah", "ja", "no") are real answers, so not here.
FILLER = set("""you oh ah uh um hm hmm mm eh huh all that the a so bye and i it is this
na äh ähm öh hä""".split())


def is_filler(norm: str) -> bool:
    w = norm.split()
    return not w or (len(w) <= 3 and all(x in FILLER for x in w))


def _phrase_in(norm: str, phrases, slack: int) -> bool:
    return any(p and (norm == p or (p in f" {norm} " and len(norm) <= len(p) + slack))
               for p in phrases)


CONVO_ON = ["lass uns reden", "lass uns quatschen", "let's talk", "lets talk",
            "conversation mode", "gesprächsmodus"]
CONVO_OFF = ["das war's", "das wars", "das war es", "stop", "stopp", "that's all", "thats all",
             "that is all", "ende", "conversation mode off", "gesprächsmodus aus"]


_DE_PHRASE_WORDS = {"ende", "stopp", "wars", "war", "lass", "reden", "quatschen", "gesprächsmodus"}


@dataclass
class Convo:
    """Follow-up state per satellite (or per HA conversation without one)."""
    mode: bool = False          # conversation mode: every reply reopens the mic
    last: float = 0.0           # last turn (conversation mode ends after modeIdle)
    auto: int = 0               # consecutive follow-ups outside conversation mode
    expect_until: float = 0.0   # a reopened mic's answer must arrive before this


def spoken_seconds(text: str) -> float:
    return len(text.split()) / 2.3 + 1.0


AGENT_NOTE = {
    "voice": "You are the untrusted household voice agent; the session is "
    "not authenticated, anyone in the room may be speaking.",
    "infra": "Trusted mode: Dave unlocked it with his fingerprint or his "
    "voice code; requests come from his satellite. Destructive or "
    "irreversible actions still need his explicit confirmation in his "
    "normal chat, not by voice.",
}

EN_DIGITS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
DE_DIGITS = ["null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun"]
DIGIT_WORDS: dict[str, int] = {w: i for i, w in enumerate(EN_DIGITS)}
DIGIT_WORDS.update({w: i for i, w in enumerate(DE_DIGITS)})
DIGIT_WORDS.update({"oh": 0, "for": 4, "to": 2, "too": 2, "ein": 1, "eine": 1,
                    "zwo": 2, "funf": 5, "fuenf": 5, "won": 1})


def normalize(text: str) -> str:
    t = unicodedata.normalize("NFC", text or "").lower().replace("’", "'")
    t = re.sub(r"\bwhat is\b", "whats", t).replace("what's", "whats")
    t = re.sub(r"[^\w\s]", " ", t)
    return " ".join(t.split())


def parse_digit(norm: str) -> Optional[int]:
    found = set()
    for tok in norm.split():
        if tok.isdigit() and len(tok) == 1:
            found.add(int(tok))
        elif tok in DIGIT_WORDS:
            found.add(DIGIT_WORDS[tok])
    return found.pop() if len(found) == 1 else None


def spoken_positions(positions: list[int], language: str) -> str:
    words = DE_DIGITS if (language or "").startswith("de") else EN_DIGITS
    return ", ".join(words[p].capitalize() for p in positions) + "."


def strip_markdown(text: str) -> str:
    text = re.sub(r"```.*?```", "", text or "", flags=re.S)
    text = re.sub(r"[*_`#>]+", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    return " ".join(text.split())


def read_secret(path: str) -> str:
    return Path(path).read_text().strip()


class AgentUnreachable(Exception):
    pass


@dataclass
class Challenge:
    device: str
    round: int
    positions: list[int]
    created: float
    language: str


@dataclass
class Pending:
    """An unlock request (passkey path): the push carries its id."""
    device: str
    created: float
    used: bool = False


@dataclass
class OidcFlow:
    intent: str  # "unlock:<id>" | "code"
    verifier: str
    nonce: str
    created: float


@dataclass
class CodeView:
    created: float


@dataclass
class Gateway:
    cfg: dict
    clock: Callable[[], float] = time.time
    # Pluggable for the tests: (agent, text) -> reply.
    agent_call: Optional[Callable[[str, str], Awaitable[str]]] = None
    notify: Optional[Callable[..., Awaitable[None]]] = None
    announce: Optional[Callable[[str], Awaitable[None]]] = None
    verify_login: Optional[Callable[[str, OidcFlow, str], Awaitable[dict]]] = None

    trusted_device: Optional[str] = None
    last_activity: float = 0.0
    challenge: Optional[Challenge] = None
    unlocks: dict[str, Pending] = field(default_factory=dict)
    unlock_times: list[float] = field(default_factory=list)
    flows: dict[str, OidcFlow] = field(default_factory=dict)
    views: dict[str, CodeView] = field(default_factory=dict)
    state: dict = field(default_factory=dict)
    background: set = field(default_factory=set)
    # Conversation sessions per agent: a new Hermes session after
    # sessionIdleMinutes of silence, so a wrong conclusion from an old
    # exchange ("the token is expired") doesn't stick for days.
    sessions: dict = field(default_factory=dict)
    convos: dict = field(default_factory=dict)

    def __post_init__(self) -> None:
        c = self.cfg
        self.idle = float(c.get("idleMinutes", 10)) * 60
        self.allowed = set(c.get("allowedDevices", []))
        vc = c.get("voiceCode", {})
        self.max_uses = int(vc.get("maxUses", 5))
        self.max_fails = int(vc.get("maxFails", 2))
        self.challenge_ttl = float(vc.get("challengeTtl", 30))
        self.start_phrases = [normalize(p) for p in vc.get("startPhrases", ["what's on the list"])]
        self.unlock_phrases = {normalize(p) for p in c.get("unlockPhrases", [])}
        self.off_phrases = {normalize(p) for p in c.get("offPhrases", [])}
        self.unlock_ttl = float(c.get("unlockTtl", 120))
        self.rate_n, self.rate_window = c.get("unlockRate", [3, 600])
        self.state_path = Path(c["stateDir"]) / "state.json"
        f = c.get("followUp", {})
        self.max_auto = int(f.get("maxAuto", 10))
        self.mode_idle = float(f.get("modeIdleSeconds", 300))
        # How long after the reply is spoken an answer may still arrive on
        # the reopened mic (lead-in, the satellite's listening, STT).
        self.listen_window = float(f.get("listenWindowSeconds", 25))
        self.convo_on = [normalize(p) for p in f.get("onPhrases", CONVO_ON)]
        self.convo_off = [normalize(p) for p in f.get("offPhrases", CONVO_OFF)]
        self.agent_call = self.agent_call or self._http_agent
        self.notify = self.notify or self._ntfy
        self.announce = self.announce or self._ha_announce
        self.verify_login = self.verify_login or self._oidc_verify
        self._load_state()

    # ---------------------------------------------------------------- state
    def _load_state(self) -> None:
        if self.state_path.exists():
            self.state = json.loads(self.state_path.read_text())
        else:
            seed = read_secret(self.cfg["voiceCode"]["seedFile"])
            if not re.fullmatch(r"\d{6}", seed):
                raise SystemExit("voice code seed is not 6 digits")
            self.state = {"code": seed, "uses": 0, "fails": 0, "source": "seed"}
            self._save_state()

    def _save_state(self) -> None:
        tmp = self.state_path.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(self.state, f)
        os.replace(tmp, self.state_path)

    @property
    def trusted(self) -> bool:
        return self.trusted_device is not None

    def _spawn(self, coro) -> None:
        task = asyncio.ensure_future(coro)
        self.background.add(task)
        task.add_done_callback(self.background.discard)

    async def _safe(self, coro, what: str) -> None:
        try:
            await coro
        except Exception as e:  # never let a push/announce failure break a turn
            log.warning("%s failed: %s", what, e)

    def notify_bg(self, title: str, message: str, **kw) -> None:
        self._spawn(self._safe(self.notify(title, message, **kw), "ntfy"))

    def announce_bg(self, message: str) -> None:
        self._spawn(self._safe(self.announce(message), "announce"))

    # ---------------------------------------------------------- trust state
    def enter_trusted(self, device: str, via: str) -> None:
        self.trusted_device = device
        self.last_activity = self.clock()
        log.warning("trusted mode ON via %s for device %s", via, device)

    def relock(self, reason: str) -> bool:
        if not self.trusted:
            return False
        log.warning("trusted mode OFF (%s)", reason)
        self.trusted_device = None
        if reason == "idle":
            self.announce_bg("Trusted mode off.")
            self.notify_bg("Trusted mode off", "Relocked after 10 minutes without a request.")
        return True

    def tick(self) -> None:
        now = self.clock()
        if self.trusted and now - self.last_activity >= self.idle:
            self.relock("idle")
        if self.challenge and now - self.challenge.created > self.challenge_ttl:
            self.challenge = None
        for k, p in list(self.unlocks.items()):
            if now - p.created > self.unlock_ttl + 60:
                del self.unlocks[k]
        for k, f in list(self.flows.items()):
            if now - f.created > 300:
                del self.flows[k]
        for k, v in list(self.views.items()):
            if now - v.created > 60:
                del self.views[k]

    # ------------------------------------------------------------ the turn
    async def turn(self, text: str, device: Optional[str], language: str = "en",
                   conversation_id: Optional[str] = None) -> tuple[str, bool]:
        """One HA turn -> (speech, continue_conversation)."""
        now = self.clock()
        key = device or (f"conv:{conversation_id}" if conversation_id else "anon")
        cv = self.convos.setdefault(key, Convo())
        norm = normalize(text)
        followup = cv.expect_until > 0 and now <= cv.expect_until
        if cv.expect_until and not followup:
            # A reopened mic got no turn in time: silence (HA ends the run
            # with "no text recognized" and never calls us). Chain over.
            log.info("follow-up missed on %s: chain ended", key)
            cv.mode, cv.auto = False, 0
        if cv.mode and now - cv.last > self.mode_idle:
            cv.mode = False
        cv.expect_until = 0.0
        cv.last = now
        if not followup:
            cv.auto = 0

        # Short phrases carry few function words: their own German words decide.
        de = reply_language(text) == "German" or bool(_DE_PHRASE_WORDS & set(norm.split()))
        is_off = _phrase_in(norm, self.convo_off, 4)
        if (cv.mode or followup) and is_off:
            was = cv.mode
            cv.mode, cv.auto = False, 0
            log.info("conversation ended by phrase on %s (mode was %s)", key, was)
            return ("Alles klar." if de else "Okay."), False
        if not is_off and _phrase_in(norm, self.convo_on, 12):
            cv.mode, cv.auto = True, 0
            log.info("conversation mode ON for %s", key)
            return self._reply(cv, "Okay, ich höre zu." if de else "Okay, I'm listening.", True)
        pending_challenge = self.challenge is not None and self.challenge.device == device
        if followup and is_filler(norm) and not pending_challenge:
            # Empty or chatter on a reopened mic ends the chain, conversation
            # mode included: the agent is not asked, nothing is spoken.
            log.info("follow-up on %s was filler (%r): chain ended", key, text[:40])
            cv.mode, cv.auto = False, 0
            return "", False

        speech, wants = await self._handle(text, device, language)
        if cv.mode:
            return self._reply(cv, speech, True)
        if wants and cv.auto < self.max_auto:
            cv.auto += 1
            return self._reply(cv, speech, True)
        if wants:
            log.info("follow-up cap (%d) reached on %s", self.max_auto, key)
        cv.auto = 0
        return speech, False

    def _reply(self, cv: Convo, speech: str, cont: bool) -> tuple[str, bool]:
        if cont and speech.strip():
            cv.expect_until = self.clock() + spoken_seconds(speech) + self.listen_window
            return speech, True
        return speech, False

    async def handle(self, text: str, device: Optional[str], language: str = "en") -> str:
        return (await self.turn(text, device, language))[0]

    async def _handle(self, text: str, device: Optional[str], language: str = "en") -> tuple[str, bool]:
        self.tick()
        now = self.clock()
        norm = normalize(text)
        known = device is not None and device in self.allowed

        ch = self.challenge
        if ch is not None and device == ch.device:
            return self._answer(ch, norm), False

        if known and self._is_start_phrase(norm):
            return self._start_challenge(device, language), False
        if known and norm in self.unlock_phrases:
            return await self._request_unlock(device), False

        if self.trusted and device == self.trusted_device:
            self.last_activity = now
            log.warning("trusted request device=%s text=%r", device, text)
            try:
                return await self._ask("infra", text)
            except AgentUnreachable as e:
                log.warning("infra agent unreachable: %s", e)
                if norm in self.off_phrases:
                    self.relock("phrase")
                    return "Trusted mode off.", False
                return "The admin agent is not reachable right now.", False
        try:
            return await self._ask("voice", text)
        except AgentUnreachable as e:
            log.warning("voice agent unreachable: %s", e)
            return "Sorry, I can't reach the assistant right now.", False

    def _is_start_phrase(self, norm: str) -> bool:
        return any(p and p in norm and len(norm) <= len(p) + 12 for p in self.start_phrases)

    async def _ask(self, agent: str, text: str) -> tuple[str, bool]:
        task = asyncio.ensure_future(self.agent_call(agent, text))
        timeout = float(self.cfg.get("replyTimeout", 40))
        done, _ = await asyncio.wait({task}, timeout=timeout)
        if task in done:
            reply, wants = split_marker(task.result())
            return strip_markdown(reply), wants

        def late(t: asyncio.Task) -> None:
            if not t.cancelled() and t.exception() is None and t.result():
                self.announce_bg(strip_markdown(split_marker(t.result())[0])[:600])
        task.add_done_callback(late)
        self.background.add(task)
        task.add_done_callback(self.background.discard)
        return "I'm still working on that and will tell you when it's done.", False

    # --------------------------------------------------- passkey unlock path
    async def _request_unlock(self, device: str) -> str:
        if self.trusted:
            return "Trusted mode is already on."
        now = self.clock()
        self.unlock_times = [t for t in self.unlock_times if now - t < self.rate_window]
        if len(self.unlock_times) >= self.rate_n:
            log.warning("unlock request rate-limited")
            return "Too many unlock requests. Try again later."
        self.unlock_times.append(now)
        uid = secrets.token_urlsafe(18)
        self.unlocks[uid] = Pending(device=device, created=now)
        url = f"{self.cfg['publicUrl']}/unlock/{uid}"
        log.warning("unlock requested from device %s", device)
        try:
            await self.notify("Voice unlock", "Tap Unlock to turn on trusted mode (fingerprint).",
                              click=url, actions=[{"action": "view", "label": "Unlock", "url": url, "clear": True}],
                              priority=5)
        except Exception as e:
            log.warning("ntfy failed: %s", e)
            return "I could not reach your phone."
        return "Check your phone."

    def begin_unlock(self, uid: str) -> bool:
        """GET /unlock/<id>: single use, valid unlockTtl seconds."""
        p = self.unlocks.get(uid)
        if p is None or p.used or self.clock() - p.created > self.unlock_ttl:
            return False
        p.used = True
        return True

    def complete_unlock(self, uid: str) -> bool:
        p = self.unlocks.pop(uid, None)
        if p is None:
            return False
        self.enter_trusted(p.device, "passkey")
        # A fingerprint unlock re-enables the voice code after lockout.
        if self.state.get("fails"):
            self.state["fails"] = 0
            self._save_state()
        self.challenge = None
        self.announce_bg("Trusted mode on.")
        return True

    # ------------------------------------------------------ voice-code path
    def voice_code_available(self) -> bool:
        return self.state["fails"] < self.max_fails and self.state["uses"] < self.max_uses

    def _start_challenge(self, device: str, language: str) -> str:
        if self.trusted:
            return "Trusted mode is already on."
        if not self.voice_code_available():
            log.warning("voice-code start refused (locked or expired)")
            return "The list is empty."
        positions = _rng.sample(range(1, 7), 2)
        self.challenge = Challenge(device, 1, positions, self.clock(), language)
        log.warning("voice-code challenge started")
        return spoken_positions(positions, language)

    def _answer(self, ch: Challenge, norm: str) -> str:
        digit = parse_digit(norm)
        if digit is None:
            return spoken_positions(ch.positions, ch.language)
        code = self.state["code"]
        expected = sum(int(code[p - 1]) for p in ch.positions) % 10
        if not hmac.compare_digest(str(digit), str(expected)):
            self.challenge = None
            self.state["fails"] += 1
            self._save_state()
            log.warning("voice-code attempt fail")
            n = self.state["fails"]
            msg = f"Wrong voice-code answer ({n}/{self.max_fails})."
            if n >= self.max_fails:
                msg += " Voice-code unlock is locked until the next fingerprint unlock."
            self.notify_bg("Voice code: wrong answer", msg, priority=5)
            return "No."
        if ch.round == 1:
            positions = _rng.sample(range(1, 7), 2)
            self.challenge = Challenge(ch.device, 2, positions, self.clock(), ch.language)
            return spoken_positions(positions, ch.language)
        self.challenge = None
        self.state["uses"] += 1
        self._save_state()
        log.warning("voice-code attempt ok")
        self.enter_trusted(ch.device, "voice-code")
        self.notify_bg("Trusted mode on", "Trusted mode unlocked by voice code.")
        if self.state["uses"] >= self.max_uses:
            self.notify_bg("Voice code: new code needed",
                           f"Used {self.max_uses} times; open {self.cfg['publicUrl']}/code and generate a new code.")
        return "Trusted mode on."

    def rotate_code(self) -> str:
        code = "".join(str(_rng.randrange(10)) for _ in range(6))
        self.state.update(code=code, uses=0, fails=0, source="rotated")
        self._save_state()
        log.warning("voice code rotated")
        return code

    # -------------------------------------------------------- MCP: lock tool
    def tool_lock(self, agent: str) -> str:
        if self.relock(f"tool:{agent}"):
            return "Trusted mode is off now."
        return "Trusted mode was already off."

    def session_id(self, agent: str) -> str:
        base = self.cfg["agents"][agent].get("session", agent)
        idle = float(self.cfg.get("sessionIdleMinutes", 10)) * 60
        now = self.clock()
        sid, last = self.sessions.get(agent, (None, 0.0))
        if sid is None or now - last > idle:
            sid = f"{base}-{time.strftime('%Y%m%d-%H%M%S', time.localtime(now))}"
        self.sessions[agent] = (sid, now)
        return sid

    def user_content(self, text: str) -> str:
        return f"{with_language(text)}\n({time_line(self.clock())})"

    # ------------------------------------------------------- real backends
    async def _http_agent(self, agent: str, text: str) -> str:
        a = self.cfg["agents"][agent]
        body: dict[str, Any] = {
            "messages": [
                {"role": "system", "content": SPOKEN_PREFIX + "\n" + AGENT_NOTE.get(agent, "")},
                {"role": "user", "content": self.user_content(text)},
            ],
        }
        if a.get("model"):
            body["model"] = a["model"]
        # Spoken replies: thinking off ("none" = the lowest the api_server
        # accepts; it disables extended thinking), unless the agent entry
        # says otherwise.
        body["model_options"] = {"reasoning_effort": a.get("reasoningEffort", "none")}
        if a.get("provider"):
            body["provider"] = a["provider"]
        headers = {"Authorization": f"Bearer {read_secret(a['keyFile'])}",
                   "X-Hermes-Session-Id": self.session_id(agent)}
        try:
            async with ClientSession(timeout=ClientTimeout(total=1800, connect=5)) as s:
                async with s.post(a["url"] + "/v1/chat/completions", json=body, headers=headers) as r:
                    if r.status >= 500 or r.status in (401, 403, 404):
                        raise AgentUnreachable(f"{agent}: HTTP {r.status}")
                    data = await r.json(content_type=None)
        except AgentUnreachable:
            raise
        except Exception as e:
            raise AgentUnreachable(f"{agent}: {e}") from e
        try:
            return data["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, TypeError):
            raise AgentUnreachable(f"{agent}: unexpected answer")

    async def _ntfy(self, title: str, message: str, **kw) -> None:
        n = self.cfg["ntfy"]
        body = {"topic": n["topic"], "title": title, "message": message, **kw}
        async with ClientSession(timeout=ClientTimeout(total=15)) as s:
            async with s.post(n["url"], json=body,
                              headers={"Authorization": f"Bearer {read_secret(n['tokenFile'])}"}) as r:
                if r.status != 200:
                    raise RuntimeError(f"ntfy HTTP {r.status}")

    async def _ha_announce(self, message: str) -> None:
        h = self.cfg["ha"]
        async with ClientSession(timeout=ClientTimeout(total=30)) as s:
            async with s.post(f"{h['url']}/api/services/assist_satellite/announce",
                              json={"entity_id": h["satellite"], "message": message},
                              headers={"Authorization": f"Bearer {read_secret(h['tokenFile'])}"}) as r:
                if r.status != 200:
                    raise RuntimeError(f"announce HTTP {r.status}")

    # ------------------------------------------------------------- OIDC
    def oidc_start(self, intent: str) -> tuple[str, str]:
        o = self.cfg["oidc"]
        state = secrets.token_urlsafe(24)
        verifier = secrets.token_urlsafe(48)
        nonce = secrets.token_urlsafe(24)
        self.flows[state] = OidcFlow(intent, verifier, nonce, self.clock())
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        q = {
            "response_type": "code", "client_id": o["clientId"],
            "redirect_uri": f"{self.cfg['publicUrl']}/callback",
            "scope": "openid profile groups", "state": state, "nonce": nonce,
            "code_challenge": challenge, "code_challenge_method": "S256",
            # Fresh passkey assertion every time: pocket-id re-authenticates
            # on prompt=login (and max_age=0); auth_time is checked below.
            "prompt": "login", "max_age": "0",
        }
        return state, f"{o['authorizationEndpoint']}?{urllib.parse.urlencode(q)}"

    def check_claims(self, claims: dict, flow: OidcFlow) -> None:
        o = self.cfg["oidc"]
        now = self.clock()
        if claims.get("nonce") != flow.nonce:
            raise PermissionError("nonce")
        auth_time = claims.get("auth_time")
        if not isinstance(auth_time, (int, float)) or not (-30 <= now - auth_time <= o.get("maxAuthAge", 60)):
            raise PermissionError("authentication not fresh")
        # pocket-id re-authenticates on prompt=login only by a passkey
        # assertion with user verification (its WEBAUTHN_USER_VERIFICATION
        # default "required"), and auth_time is that assertion's time. amr
        # names the session's original login method, so it is only logged.
        log.info("login amr=%s", claims.get("amr"))
        if claims.get("preferred_username") != o["user"]:
            raise PermissionError("wrong user")
        if o["group"] not in (claims.get("groups") or []):
            raise PermissionError("not in group")

    async def _oidc_verify(self, code: str, flow: OidcFlow, _state: str) -> dict:
        import jwt  # pyjwt[crypto]
        o = self.cfg["oidc"]
        secret = read_secret(o["secretFile"])
        async with ClientSession(timeout=ClientTimeout(total=20)) as s:
            async with s.post(o["tokenEndpoint"], data={
                "grant_type": "authorization_code", "code": code,
                "redirect_uri": f"{self.cfg['publicUrl']}/callback",
                "code_verifier": flow.verifier,
            # client_secret_basic: RFC 6749 2.3.1 wants id and secret
            # form-urlencoded before base64, and pocket-id (fosite) decodes
            # them, so a raw "+" in the secret would arrive as a space.
            }, auth=BasicAuth(urllib.parse.quote_plus(o["clientId"]),
                              urllib.parse.quote_plus(secret))) as r:
                if r.status != 200:
                    raise PermissionError(f"token endpoint HTTP {r.status}")
                tok = await r.json()
        id_token = tok["id_token"]
        jwks = jwt.PyJWKClient(o["jwksUri"])
        key = await asyncio.to_thread(jwks.get_signing_key_from_jwt, id_token)
        claims = jwt.decode(id_token, key.key, algorithms=["RS256", "ES256", "EdDSA", "PS256"],
                            audience=o["clientId"], issuer=o["issuer"],
                            options={"require": ["exp", "iat", "aud", "iss", "sub"]})
        self.check_claims(claims, flow)
        return claims


# ======================================================================= web
PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark light"><title>Voice</title>
<style>:root{{--bg:#111;--fg:#eee;--mut:#999;--acc:#5b9cff}}
@media (prefers-color-scheme: light){{:root{{--bg:#fafafa;--fg:#111;--mut:#555;--acc:#1557d0}}}}
body{{background:var(--bg);color:var(--fg);font:18px system-ui,sans-serif;margin:2em;text-align:center}}
a.b,button{{display:inline-block;background:var(--acc);color:#fff;border:0;border-radius:10px;
padding:.8em 1.4em;font-size:1em;text-decoration:none;margin:.5em}}
.code{{font:700 4em ui-monospace,monospace;letter-spacing:.25em;margin:.5em 0}}.m{{color:var(--mut)}}</style>
</head><body>{body}</body></html>"""

HEADERS = {
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
}


def page(body: str, status: int = 200) -> web.Response:
    return web.Response(text=PAGE.format(body=body), status=status, content_type="text/html", headers=HEADERS)


def code_page(code: str, token: str) -> web.Response:
    return page(f"""<h1>Voice code</h1><div id=c class=code>{html.escape(code)}</div>
<p class=m id=t>Hidden in 60 s.</p>
<form method=post action="/code/rotate"><input type=hidden name=t value="{html.escape(token)}">
<button>Generate new code</button></form>
<script>let n=60;const t=setInterval(()=>{{n--;document.getElementById('t').textContent='Hidden in '+n+' s.';
if(n<=0){{clearInterval(t);document.body.innerHTML='<p>Hidden.</p>';}}}},1000);</script>""")


def web_app(gw: Gateway) -> web.Application:
    app = web.Application(client_max_size=4096)
    cookie = "__Host-vg_state"

    def redirect_to_login(intent: str) -> web.Response:
        state, url = gw.oidc_start(intent)
        r = web.Response(status=302, headers={"Location": url, **HEADERS})
        r.set_cookie(cookie, state, max_age=300, secure=True, httponly=True, samesite="Lax", path="/")
        return r

    async def index(_req):
        return page('<h1>Voice</h1><p><a class=b href="/code">Show voice code</a></p>'
                    '<p class=m>Every view asks for your fingerprint.</p>')

    async def unlock(req):
        uid = req.match_info["uid"]
        if not gw.begin_unlock(uid):
            return page("<h1>Expired</h1><p>This unlock link is used or expired. Say “unlock” again.</p>", 410)
        return redirect_to_login(f"unlock:{uid}")

    async def code(_req):
        return redirect_to_login("code")

    async def callback(req):
        state = req.query.get("state", "")
        flow = gw.flows.pop(state, None)
        if flow is None or not hmac.compare_digest(req.cookies.get(cookie, ""), state):
            return page("<h1>Invalid</h1><p>Start again.</p>", 400)
        if "code" not in req.query:
            return page("<h1>Cancelled</h1>", 400)
        try:
            await gw.verify_login(req.query["code"], flow, state)
        except Exception as e:
            log.warning("login refused: %s", e)
            return page("<h1>Refused</h1><p>A fresh fingerprint login as Dave is required.</p>", 403)
        if flow.intent.startswith("unlock:"):
            if gw.complete_unlock(flow.intent.split(":", 1)[1]):
                return page("<h1>Trusted mode on</h1><p class=m>Ends after 10 minutes without a request, "
                            "or when you say you are done.</p>")
            return page("<h1>Expired</h1>", 410)
        if flow.intent == "code":
            token = secrets.token_urlsafe(24)
            gw.views[token] = CodeView(gw.clock())
            log.warning("voice code shown")
            return code_page(gw.state["code"], token)
        return page("<h1>?</h1>", 400)

    async def rotate(req):
        data = await req.post()
        token = str(data.get("t", ""))
        v = gw.views.pop(token, None)
        if v is None or gw.clock() - v.created > 60:
            return page("<h1>Expired</h1><p>Open “Show voice code” again.</p>", 403)
        new = gw.rotate_code()
        token = secrets.token_urlsafe(24)
        gw.views[token] = CodeView(gw.clock())
        return code_page(new, token)

    app.router.add_get("/", index)
    app.router.add_get(r"/unlock/{uid:[A-Za-z0-9_-]{16,64}}", unlock)
    app.router.add_get("/code", code)
    app.router.add_get("/callback", callback)
    app.router.add_post("/code/rotate", rotate)
    return app


def _bearer_ok(req: web.Request, secret: str) -> bool:
    got = req.headers.get("Authorization", "")
    return hmac.compare_digest(got.encode(), f"Bearer {secret}".encode())


def ha_app(gw: Gateway, secret: Callable[[], str]) -> web.Application:
    app = web.Application(client_max_size=64 * 1024)

    async def converse(req):
        if not _bearer_ok(req, secret()):
            return web.json_response({"error": "unauthorized"}, status=401)
        body = await req.json()
        text = str(body.get("text") or "")[:2000]
        speech, cont = await gw.turn(text, body.get("device_id"), str(body.get("language") or "en"),
                                     body.get("conversation_id"))
        return web.json_response({"speech": speech, "continue_conversation": cont})

    app.router.add_post("/v1/converse", converse)
    return app


TOOL = {
    "name": "voice_trusted_mode_off",
    "description": "End the voice satellite's trusted (admin) mode right now. Call it whenever Dave says, "
                   "in any wording, that he wants to leave or end trusted/admin mode. Idempotent. "
                   "It can only lock; nothing can unlock trusted mode by tool.",
    "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
}


def mcp_app(gw: Gateway, tokens: Callable[[], dict[str, str]]) -> web.Application:
    app = web.Application(client_max_size=256 * 1024)

    def who(req) -> Optional[str]:
        for agent, tok in tokens().items():
            if _bearer_ok(req, tok):
                return agent
        return None

    def rpc(agent: str, msg: dict) -> Optional[dict]:
        mid, method = msg.get("id"), msg.get("method", "")
        if mid is None:  # notification
            return None
        if method == "initialize":
            pv = (msg.get("params") or {}).get("protocolVersion") or "2025-06-18"
            result: Any = {"protocolVersion": pv, "capabilities": {"tools": {"listChanged": False}},
                           "serverInfo": {"name": "voice-gateway", "version": "1"}}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": [TOOL]}
        elif method == "tools/call":
            name = (msg.get("params") or {}).get("name")
            if name != TOOL["name"]:
                return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "unknown tool"}}
            result = {"content": [{"type": "text", "text": gw.tool_lock(agent)}], "isError": False}
        else:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found"}}
        return {"jsonrpc": "2.0", "id": mid, "result": result}

    async def post(req):
        agent = who(req)
        if agent is None:
            return web.json_response({"error": "unauthorized"}, status=401)
        body = await req.json()
        msgs = body if isinstance(body, list) else [body]
        out = [r for r in (rpc(agent, m) for m in msgs if isinstance(m, dict)) if r is not None]
        if not out:
            return web.Response(status=202)
        return web.json_response(out if isinstance(body, list) else out[0])

    async def other(_req):
        return web.Response(status=405, headers={"Allow": "POST"})

    async def delete(_req):
        return web.Response(status=200)

    app.router.add_post("/mcp", post)
    app.router.add_get("/mcp", other)
    app.router.add_delete("/mcp", delete)
    return app


def freebind_socket(host: str, port: int) -> socket.socket:
    """A listening socket that binds before its address exists (the ygg
    address and the container's veth come up after this unit may start)."""
    fam = socket.AF_INET6 if ":" in host else socket.AF_INET
    s = socket.socket(fam, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_IP, 15, 1)  # IP_FREEBIND (also covers IPv6)
    s.bind((host, port))
    s.listen(128)
    s.setblocking(False)
    return s


async def discover(cfg: dict) -> None:
    o = cfg["oidc"]
    async with ClientSession(timeout=ClientTimeout(total=20)) as s:
        async with s.get(o["issuer"] + "/.well-known/openid-configuration") as r:
            d = await r.json()
    o.setdefault("authorizationEndpoint", d["authorization_endpoint"])
    o.setdefault("tokenEndpoint", d["token_endpoint"])
    o.setdefault("jwksUri", d["jwks_uri"])


async def main(cfg_path: str) -> None:
    cfg = json.loads(Path(cfg_path).read_text())
    for attempt in range(30):
        try:
            await discover(cfg)
            break
        except Exception as e:
            log.warning("OIDC discovery failed (%s), retrying", e)
            await asyncio.sleep(10)
    gw = Gateway(cfg)
    runners = []
    apps = {
        "ha": ha_app(gw, lambda: read_secret(cfg["haSecretFile"])),
        "web": web_app(gw),
        "mcp": mcp_app(gw, lambda: {a: read_secret(p) for a, p in cfg["mcpTokens"].items()}),
    }
    for name, app in apps.items():
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        for host, port in cfg["listen"][name]:
            await web.SockSite(runner, freebind_socket(host, port)).start()
            log.info("%s listening on %s:%s", name, host, port)
        runners.append(runner)
    while True:
        await asyncio.sleep(5)
        gw.tick()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("config")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    asyncio.run(main(ap.parse_args().config))
