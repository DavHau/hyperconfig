"""Wyoming TTS server (CPU only) plus a small HTTP voice API, one process.

Engines (dave-hermes's ~/jobs/speechbench/voicesvc/engines.py, Dave's spec):
  kokoro82   Kokoro-82M int8 ONNX (kokoro-onnx), English voices af/am/bf/bm
  supertonic Supertonic 3 (en/de), built-in F1..F5/M1..M5, 8 flow steps
  wayu_thai  Wayu Kokoro-Thai fp32 ONNX (kokoro_thai.onnx_infer from the HF
             snapshot), the roster's 12 speakers at their roster speed
Voice ids are "<engine>/<name>". Drop-in voices come from
<voices-dir>/<engine>/ (see voices.d-README.md), rescanned whenever a file
there changes; bad files are logged and skipped, built-in names refused.

Per request: language = Thai script -> th, German-looking text -> de, else
en (HA's Wyoming client sends no language); voice = the selection file's
entry for that language (re-read when its mtime changes). The voice HA
names is ignored: the selection file is the only source of truth.

HTTP (--api-port; the unit admits localhost and the dashboard proxy only):
  GET  /         voice-picker page (voices.html)
  GET  /voices   {languages: {<lang>: {selected, voices: [...]}}, selection}
  PUT  /voices   {"de": "supertonic/F2", ...} -> validated, written atomically
  POST /translate {text} -> {source, en, de, th} (via speech-translate)
  POST /preview  {lang, voice, text} -> audio/wav
PUT/POST need Content-Type: application/json, which a cross-origin page
cannot send without a CORS preflight this server never answers.
"""
import argparse, asyncio, io, json, logging, os, re, sys, threading, time, wave
from functools import partial
from pathlib import Path

import numpy as np
from aiohttp import web
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.event import Event
from wyoming.info import Attribution, Describe, Info, TtsProgram, TtsVoice
from wyoming.server import AsyncEventHandler, AsyncServer
from wyoming.tts import Synthesize

log = logging.getLogger("speech-tts")
LANGS = ("en", "de", "th")
DEFAULTS = {"en": "kokoro82/af_heart", "de": "supertonic/M3", "th": "wayu_thai/m_elderly_deep"}
THAI = re.compile("[\u0e00-\u0e7f]")
DE_WORDS = set("der die das und ist nicht ich ein eine zu im mit auf den dem es sie wir ihr "
               "habe hat wird werden kann bitte danke ja nein licht".split())
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
MAX_TEXT = 2000


def guess_lang(text):
    if THAI.search(text):
        return "th"
    w = re.findall(r"[a-zäöüß]+", text.lower())
    if re.search("[äöüß]", text.lower()) or sum(x in DE_WORDS for x in w) >= max(1, len(w) // 5):
        return "de"
    return "en"


class Voice:
    def __init__(s, engine, name, langs, style, speed=1.0, label=None, description="", builtin=True,
                 path=None, extra=None):
        s.engine, s.name, s.langs, s.style, s.speed = engine, name, tuple(langs), style, speed
        s.label = label or name
        s.description, s.builtin, s.path, s.extra = description, builtin, path, extra or {}

    @property
    def id(s):
        return f"{s.engine}/{s.name}"

    def json(s):
        return {"id": s.id, "engine": s.engine, "name": s.name, "label": s.label, "langs": list(s.langs),
                "speed": s.speed, "description": s.description, "builtin": s.builtin}


# ---- engines -------------------------------------------------------------

class Kokoro82:
    name, langs, ext = "kokoro82", ("en",), ".npy"

    def __init__(s, a):
        import onnxruntime as ort
        from kokoro_onnx import Kokoro
        o = ort.SessionOptions(); o.intra_op_num_threads = a.threads; o.inter_op_num_threads = 1
        sess = ort.InferenceSession(a.kokoro_model, o, providers=["CPUExecutionProvider"])
        s.k = Kokoro.from_session(sess, a.kokoro_voices)
        s.builtins = {v: Voice(s.name, v, s.langs, s.k.get_voice_style(v), description=f"Kokoro-82M {v}")
                      for v in sorted(s.k.get_voices()) if v[:2] in ("af", "am", "bf", "bm")}
        s.shape = next(iter(s.builtins.values())).style.shape  # (510, 1, 256)

    def load(s, path, meta):
        st = np.load(path, allow_pickle=False)
        if st.dtype != np.float32:
            raise ValueError(f"dtype {st.dtype}, want float32")
        if st.shape == s.shape[:1] + s.shape[2:]:
            st = st.reshape(s.shape)
        if st.shape != s.shape or not np.isfinite(st).all():
            raise ValueError(f"shape {st.shape}, want {s.shape} (finite)")
        return st

    def synth(s, text, v, lang):
        british = v.name.startswith("b") if v.builtin else bool(v.extra.get("british"))
        a, sr = s.k.create(text, voice=v.style, speed=v.speed, lang="en-gb" if british else "en-us")
        return np.asarray(a, np.float32).reshape(-1), sr


class Supertonic:
    name, langs, ext = "supertonic", ("de", "en"), ".json"

    def __init__(s, a):
        from supertonic import TTS
        from supertonic.loader import load_voice_style_from_json_file
        s.loadjson = load_voice_style_from_json_file
        s.steps = a.steps
        s.t = TTS(model="supertonic-3", model_dir=a.supertonic_dir, auto_download=False,
                  intra_op_num_threads=a.threads, inter_op_num_threads=1)
        s.builtins = {v: Voice(s.name, v, s.langs, s.t.get_voice_style(voice_name=v),
                               description=f"Supertonic 3 {v}") for v in sorted(s.t.voice_style_names)}
        b = next(iter(s.builtins.values())).style
        s.shapes = (b.ttl.shape, b.dp.shape)

    def load(s, path, meta):
        st = s.loadjson(path)
        for x, want in zip((st.ttl, st.dp), s.shapes):
            if x.shape != want or not np.isfinite(x).all():
                raise ValueError(f"style shape {x.shape}, want {want} (finite)")
        return st

    # German low quotes are outside Supertonic's character set and make
    # synthesize() raise (a whole reply went silent); its own normalizer
    # handles the other typographic marks.
    QUOTES = str.maketrans({"\u201e": '"', "\u201a": "'"})

    def synth(s, text, v, lang):
        text = text.translate(s.QUOTES)
        ok, bad = s.t.model.text_processor.validate_text(text)
        if not ok:
            log.warning("supertonic: dropping unsupported characters %s", bad)
            text = "".join(c for c in text if c not in set(bad))
        w, _ = s.t.synthesize(text, voice_style=v.style, lang=lang if lang in s.langs else "en",
                              total_steps=s.steps, speed=v.speed)
        return np.asarray(w, np.float32).reshape(-1), s.t.sample_rate


class WayuThai:
    name, langs, ext = "wayu_thai", ("th",), ".npy"
    MAX_TOKENS = 400  # Kokoro's hard limit is 510

    def __init__(s, a):
        d = a.wayu_dir
        sys.path.insert(0, d)
        from kokoro_thai import onnx_infer as oi
        s.oi = oi
        s.st = oi.load_onnx(f"{d}/onnx", intra_threads=a.threads, precision="fp32")
        styles = oi.load_styles(f"{d}/onnx")
        roster = json.load(open(f"{d}/data/seeds/roster.json"))
        s.builtins = {r["name"]: Voice(s.name, r["name"], s.langs, styles[r["id"]], speed=float(r.get("speed", 1.0)),
                                       description=f"Wayu Kokoro-Thai: {r.get('instruct', '')}")
                      for r in roster if r["id"] in styles}

    def load(s, path, meta):
        st = np.load(path, allow_pickle=False)
        if st.dtype != np.float32 or st.size != 256 or not np.isfinite(st).all():
            raise ValueError(f"want 256 finite float32 values ((1, 256)), got {st.dtype} {st.shape}")
        return st.reshape(1, 256)

    def chunks(s, text):
        """Whitespace-separated pieces, packed below MAX_TOKENS phonemes each."""
        out, cur = [], ""
        for piece in text.split():
            cand = f"{cur} {piece}".strip()
            if cur and s.oi.count_tokens(s.st, s.st.g2p.phonemize(cand)) > s.MAX_TOKENS:
                out.append(cur); cur = piece
            else:
                cur = cand
        return out + [cur] if cur else out

    def synth(s, text, v, lang):
        gap = np.zeros(int(0.15 * 24000), np.float32)
        parts = []
        for c in s.chunks(text):
            parts += [s.oi.synth(s.st, c, v.style, speed=v.speed), gap]
        return (np.concatenate(parts[:-1]) if parts else np.zeros(0, np.float32)), 24000


# ---- voices, drop-ins, selection --------------------------------------------

class Catalog:
    def __init__(s, engines, voices_dir, selection_file):
        s.engines = {e.name: e for e in engines}
        s.locks = {e.name: threading.Lock() for e in engines}
        s.dir, s.file = Path(voices_dir), Path(selection_file)
        s.dropins, s.sig = {}, None
        s.sel, s.sel_mtime = dict(DEFAULTS), None
        s.mutex = threading.Lock()
        s.refresh()

    def _signature(s):
        sig = []
        for e in s.engines:
            try:
                for f in sorted(os.scandir(s.dir / e), key=lambda x: x.name):
                    st = f.stat()
                    sig.append((e, f.name, st.st_mtime_ns, st.st_size))
            except (FileNotFoundError, NotADirectoryError, PermissionError):
                pass
        return tuple(sig)

    def _scan(s):
        found = {}
        for ename, eng in s.engines.items():
            d = s.dir / ename
            if not d.is_dir():
                continue
            for p in sorted(d.iterdir()):
                n = p.name
                if not n.endswith(eng.ext) or n.endswith(".meta.json") or n.startswith("."):
                    continue
                name = n[: -len(eng.ext)]
                try:
                    if not NAME.match(name):
                        raise ValueError("name must match " + NAME.pattern)
                    if name in eng.builtins:
                        raise ValueError("name clashes with a built-in voice")
                    meta = {}
                    # sidecar: <name>.meta.json; for the .npy engines <name>.json too
                    side = [d / f"{name}.meta.json"] + ([d / f"{name}.json"] if eng.ext != ".json" else [])
                    for m in side:
                        if m.exists():
                            meta = json.loads(m.read_text())
                            if not isinstance(meta, dict):
                                raise ValueError(f"{m.name}: not a JSON object")
                            break
                    langs = meta.get("lang", list(eng.langs))
                    langs = [langs] if isinstance(langs, str) else list(langs)
                    if not langs or any(l not in eng.langs for l in langs):
                        raise ValueError(f"lang {langs} not within {list(eng.langs)}")
                    speed = float(meta.get("speed", 1.0))
                    if not 0.5 <= speed <= 2.0:
                        raise ValueError(f"speed {speed} outside 0.5..2.0")
                    v = Voice(ename, name, langs, eng.load(p, meta), speed=speed,
                              label=str(meta.get("label") or name), description=str(meta.get("description", "")),
                              builtin=False, path=str(p), extra=meta)
                    found[v.id] = v
                except Exception as e:  # never crash on a bad drop-in
                    log.warning("drop-in %s skipped: %s", p, e)
        return found

    def refresh(s):
        with s.mutex:
            sig = s._signature()
            if sig != s.sig:
                s.dropins, s.sig = s._scan(), sig
                log.info("drop-in voices: %s", sorted(s.dropins) or "none")
            try:
                mt = s.file.stat().st_mtime_ns
            except FileNotFoundError:
                s._write(dict(DEFAULTS)); mt = s.file.stat().st_mtime_ns
            if mt != s.sel_mtime:
                try:
                    data = json.loads(s.file.read_text())
                    s.sel = {l: data.get(l, DEFAULTS[l]) for l in LANGS}
                    log.info("selection: %s", s.sel)
                except Exception as e:
                    log.warning("selection file %s unreadable (%s), keeping %s", s.file, e, s.sel)
                s.sel_mtime = mt

    def _write(s, sel):
        tmp = s.file.with_name(f".{s.file.name}.tmp")
        tmp.write_text(json.dumps(sel, indent=2) + "\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, s.file)

    def all(s):
        vs = {}
        for e in s.engines.values():
            for v in e.builtins.values():
                vs[v.id] = v
        vs.update(s.dropins)
        return vs

    def voice_for(s, lang):
        s.refresh()
        vs = s.all()
        v = vs.get(s.sel.get(lang))
        if v is None or lang not in v.langs:
            log.warning("selected %s voice %r unavailable, using %s", lang, s.sel.get(lang), DEFAULTS[lang])
            v = vs[DEFAULTS[lang]]
        return v

    def state(s):
        s.refresh()
        vs = list(s.all().values())
        return {"languages": {l: {"selected": s.sel.get(l), "voices": [v.json() for v in vs if l in v.langs]}
                              for l in LANGS},
                "selection": dict(s.sel), "file": str(s.file)}

    def put(s, body):
        s.refresh()
        if not isinstance(body, dict) or not body:
            raise ValueError('want an object like {"de": "supertonic/F2"}')
        vs, new = s.all(), dict(s.sel)
        for l, vid in body.items():
            if l not in LANGS:
                raise ValueError(f"unknown language {l!r}, want one of {list(LANGS)}")
            v = vs.get(vid)
            if v is None or l not in v.langs:
                raise ValueError(f"{vid!r} is not a voice for {l}")
            new[l] = vid
        with s.mutex:
            s._write(new)
        log.info("selection set via API: %s", new)
        return s.state()

    def synth(s, text, v, lang):
        with s.locks[v.engine]:
            return s.engines[v.engine].synth(text, v, lang)


# ---- Wyoming -------------------------------------------------------------

ATT = Attribution(name="local", url="https://github.com/DavHau")


def info(cat):
    voices = [TtsVoice(name=v.id, description=f"{v.label} ({v.engine})", attribution=ATT, installed=True,
                       version="1", languages=list(v.langs)) for v in cat.all().values()]
    return Info(tts=[TtsProgram(name="speech-tts",
                                description="Kokoro-82M (en), Supertonic 3 (de), Wayu Kokoro-Thai (th), CPU",
                                attribution=ATT, installed=True, version="2", voices=voices)])


class Handler(AsyncEventHandler):
    def __init__(s, cat, *a, **kw):
        super().__init__(*a, **kw)
        s.cat = cat

    async def handle_event(s, event: Event) -> bool:
        loop = asyncio.get_running_loop()
        if Describe.is_type(event.type):
            await loop.run_in_executor(None, s.cat.refresh)
            await s.write_event(info(s.cat).event())
            return True
        if not Synthesize.is_type(event.type):
            return True
        syn = Synthesize.from_event(event)
        text = " ".join(syn.text.split())
        lang = guess_lang(text)
        v = await loop.run_in_executor(None, s.cat.voice_for, lang)
        t0 = time.perf_counter()
        try:
            w, sr = await loop.run_in_executor(None, s.cat.synth, text, v, lang)
        except Exception:
            # Never leave the satellite silent: say that speaking failed
            # (the reply itself is in the agent's history and this log).
            log.exception("wyoming %s voice=%s synthesis failed: %s", lang, v.id, text)
            fb = {"de": "Entschuldige, die Antwort konnte ich nicht vorlesen.",
                  "th": "ขอโทษ อ่านคำตอบไม่ได้"}.get(lang, "Sorry, I couldn't read that answer out.")
            try:
                w, sr = await loop.run_in_executor(None, s.cat.synth, fb, v, lang)
            except Exception:
                fv = await loop.run_in_executor(None, s.cat.voice_for, "en")
                w, sr = await loop.run_in_executor(None, s.cat.synth, "Sorry, I couldn't read that answer out.", fv, "en")
        log.info("wyoming %s voice=%s %.2fs audio in %.3fs (HA voice %s): %s", lang, v.id, len(w) / sr,
                 time.perf_counter() - t0, syn.voice.name if syn.voice else None, text)
        pcm = (np.clip(w, -1, 1) * 32767).astype(np.int16).tobytes()
        await s.write_event(AudioStart(rate=sr, width=2, channels=1).event())
        step = sr * 2  # 1 s chunks
        for i in range(0, len(pcm), step):
            await s.write_event(AudioChunk(audio=pcm[i:i + step], rate=sr, width=2, channels=1).event())
        await s.write_event(AudioStop().event())
        return True


# ---- HTTP ----------------------------------------------------------------

def wav_bytes(w, sr):
    b = io.BytesIO()
    with wave.open(b, "wb") as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(sr)
        f.writeframes((np.clip(w, -1, 1) * 32767).astype(np.int16).tobytes())
    return b.getvalue()


def api(cat, page, translate_url=None):
    async def body(req):
        if req.content_type != "application/json":
            raise web.HTTPUnsupportedMediaType(text="Content-Type must be application/json")
        try:
            return await req.json()
        except Exception:
            raise web.HTTPBadRequest(text="invalid JSON")

    def run(f, *a):
        return asyncio.get_running_loop().run_in_executor(None, f, *a)

    async def index(req):
        return web.Response(text=page, content_type="text/html", headers={
            "Cache-Control": "no-store", "X-Frame-Options": "DENY",
            "Content-Security-Policy": "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
                                       "media-src blob: 'self'; frame-ancestors 'none'"})

    async def get_voices(req):
        return web.json_response(await run(cat.state), headers={"Cache-Control": "no-store"})

    async def put_voices(req):
        b = await body(req)
        try:
            return web.json_response(await run(cat.put, b))
        except ValueError as e:
            return web.json_response({"error": str(e)}, status=400)

    async def preview(req):
        b = await body(req)
        if not isinstance(b, dict):
            return web.json_response({"error": "want {lang, voice, text}"}, status=400)
        lang, vid, text = b.get("lang"), b.get("voice"), " ".join(str(b.get("text", "")).split())
        await run(cat.refresh)
        v = cat.all().get(vid)
        if lang not in LANGS or v is None or lang not in v.langs:
            return web.json_response({"error": f"{vid!r} is not a voice for {lang!r}"}, status=400)
        if not text or len(text) > MAX_TEXT:
            return web.json_response({"error": f"text must be 1..{MAX_TEXT} characters"}, status=400)
        t0 = time.perf_counter()
        try:
            w, sr = await run(cat.synth, text, v, lang)
        except Exception as e:
            log.exception("preview %s failed", vid)
            return web.json_response({"error": f"synthesis failed: {e}"}, status=500)
        log.info("preview %s voice=%s %.2fs audio in %.3fs: %s", lang, v.id, len(w) / sr,
                 time.perf_counter() - t0, text)
        return web.Response(body=wav_bytes(w, sr), content_type="audio/wav", headers={"Cache-Control": "no-store"})

    async def translate(req):
        # The picker's sample sentence -> en/de/th, by speech-translate
        # (translate.py, loopback; this unit may not reach the internet).
        b = await body(req)
        if not translate_url:
            return web.json_response({"error": "translation not configured"}, status=501)
        from aiohttp import ClientSession, ClientTimeout
        async with ClientSession(timeout=ClientTimeout(total=90)) as s:
            async with s.post(translate_url + "/translate", json=b) as r:
                return web.json_response(await r.json(), status=r.status)

    app = web.Application(client_max_size=64 * 1024)
    app.add_routes([web.get("/", index), web.get("/voices", get_voices), web.put("/voices", put_voices),
                    web.post("/preview", preview), web.post("/translate", translate)])
    return app


async def serve(a, cat):
    page = (Path(__file__).parent / "voices.html").read_text()
    runner = web.AppRunner(api(cat, page, a.translate_url), access_log=None)
    await runner.setup()
    for host in a.api_host:
        await web.TCPSite(runner, host, a.api_port).start()
        log.info("HTTP voice API on [%s]:%d", host, a.api_port)
    await AsyncServer.from_uri(a.uri).run(partial(Handler, cat))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--uri", required=True)
    ap.add_argument("--api-host", action="append", default=None, help="repeatable; default 127.0.0.1")
    ap.add_argument("--api-port", type=int, default=10201)
    ap.add_argument("--supertonic-dir", required=True)
    ap.add_argument("--kokoro-model", required=True)
    ap.add_argument("--kokoro-voices", required=True)
    ap.add_argument("--wayu-dir", required=True)
    ap.add_argument("--voices-dir", required=True)
    ap.add_argument("--selection-file", required=True)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--steps", type=int, default=8)
    ap.add_argument("--translate-url", default=None, help="speech-translate base URL for POST /translate")
    a = ap.parse_args()
    a.api_host = a.api_host or ["127.0.0.1"]
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    engines = [Kokoro82(a), Supertonic(a), WayuThai(a)]
    cat = Catalog(engines, a.voices_dir, a.selection_file)
    for lang, text in (("en", "ok"), ("de", "ok"), ("th", "สวัสดี")):  # warm-up
        cat.synth(text, cat.voice_for(lang), lang)
    log.info("ready on %s, %d threads per engine, %d voices", a.uri, a.threads, len(cat.all()))
    asyncio.run(serve(a, cat))


if __name__ == "__main__":
    main()
