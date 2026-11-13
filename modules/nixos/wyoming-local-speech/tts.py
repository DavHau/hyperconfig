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
  GET  /output   {output, effective, sink: {...}|null}: where replies play
  PUT  /output   {"output": "soundbar"|"voice-pe"} (also: the --output-file)

Bluetooth speaker (--bt-mac, see bt-speaker.nix): with output "soundbar"
and the A2DP sink connected in bluealsa, each reply plays locally (aplay on
the bluealsa PCM, fed sentence by sentence as soon as each is synthesized)
and the Wyoming client gets silence of the same length, so the satellite
stays "responding" and doesn't reopen its mic over the soundbar. Sink not
connected or the first write failing -> the real audio goes to the client.
PUT/POST need Content-Type: application/json, which a cross-origin page
cannot send without a CORS preflight this server never answers.
"""
import argparse, asyncio, concurrent.futures, fcntl, io, json, logging, os, queue, re, subprocess, sys
import threading, time, wave
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
# Common function words: guess_lang compares hits (German vs English).
DE_WORDS = set("""
der die das den dem des ein eine einen einem einer eines und oder aber doch denn weil wenn dass ob als wie
ist sind war waren bin bist sein hat habe hast haben hatte wird werden wurde kann kannst können muss musst
soll sollst will willst möchte mag darf ich du er sie es wir ihr mich dich mir dir uns euch ihn ihm ihnen
mein dein sein unser euer kein keine nicht nichts noch schon auch nur sehr mal jetzt hier dort heute morgen
gestern immer wieder gerade bitte danke ja nein gern gerne alles klar okay sag sagt mach macht gib gibt
zu zum zur im in am an auf aus bei mit nach von vor über unter um durch für gegen ohne bis seit
was wer wo wann warum wieso welche welcher welches viel mehr etwas einfach eben genau leider natürlich
bescheid stimmt fehler licht wohnzimmer schlafzimmer küche grad uhr minuten stunden tag
""".split())
EN_WORDS = set("""
the a an and or but because if that whether as how is are was were be been am has have had will would
can could must should shall may might do does did i you he she it we they me him her us them my your his
its our their no not nothing still already also only very now here there today tomorrow yesterday always
again just please thanks yes sure okay ok let lets tell give make to of in on at from by with for about
into over under through without until since what who where when why which much more something simply
exactly unfortunately of course right sorry light living room bedroom kitchen time minutes hours day
""".split())
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
MAX_TEXT = 2000


def guess_lang(text, spoken=None):
    """Reply language: Thai script -> th; else German vs English function
    words (umlauts count triple); a tie goes to the language Dave just
    spoke (speech-stt's last utterance), then en."""
    if THAI.search(text):
        return "th"
    low = text.lower()
    w = re.findall(r"[a-zäöüß]+", low)
    de = sum(x in DE_WORDS for x in w) + 3 * len(re.findall("[äöüß]", low))
    en = sum(x in EN_WORDS for x in w)
    if de != en:
        return "de" if de > en else "en"
    return spoken if spoken in ("de", "en") else "en"


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
    def __init__(s, engines, voices_dir, selection_file, last_lang_file=None):
        s.last_lang_file = last_lang_file
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

    def last_spoken(s):
        """speech-stt's language of the latest utterance, if recent (5 min)."""
        if not s.last_lang_file:
            return None
        try:
            if time.time() - os.path.getmtime(s.last_lang_file) > 300:
                return None
            return Path(s.last_lang_file).read_text().strip()
        except OSError:
            return None

    def synth(s, text, v, lang):
        with s.locks[v.engine]:
            return s.engines[v.engine].synth(text, v, lang)


# ---- Bluetooth speaker -----------------------------------------------------

OUTPUTS = ("soundbar", "voice-pe")
SENTENCE = re.compile(r"(?<=[.!?…;:])\s+")


def pieces(text, first_min=12, min_len=40):
    """Sentences, short ones merged into the next, so the first audio is
    ready early; the first piece may be shorter than the rest."""
    out, cur = [], ""
    for p in SENTENCE.split(text):
        cur = f"{cur} {p}".strip()
        if len(cur) >= (min_len if out else first_min):
            out.append(cur); cur = ""
    if cur:
        if out and len(cur) < 12:
            out[-1] += " " + cur
        else:
            out.append(cur)
    return out or [text]


class BtSink:
    """One writer thread owns a long-lived aplay on the bluealsa PCM. Between
    replies it pads the stream with paced silence for `hold` seconds (no
    AVDTP restart, no lead-in for follow-ups), then closes it."""
    F_SETPIPE_SZ = 1031

    def __init__(s, a):
        s.mac = a.bt_mac.upper()
        s.dev = "dev_" + s.mac.replace(":", "_")
        s.aplay, s.busctl, s.file = a.bt_aplay, a.bt_busctl, Path(a.output_file)
        s.hold, s.lead = a.bt_hold, a.bt_lead
        s.buffer_us, s.period_us = a.bt_buffer_us, a.bt_period_us
        s.q = queue.Queue()
        s.proc = s.fmt = None
        s.t_start = s.frames = s.reply_end = 0.0
        threading.Thread(target=s.run, name="bt-sink", daemon=True).start()

    def output(s):
        try:
            v = s.file.read_text().strip()
        except OSError:
            return "soundbar"
        return v if v in OUTPUTS else "soundbar"

    def set_output(s, v):
        if v not in OUTPUTS:
            raise ValueError(f"output must be one of {list(OUTPUTS)}")
        tmp = s.file.with_name(f".{s.file.name}.tmp")
        tmp.write_text(v + "\n"); os.chmod(tmp, 0o644); os.replace(tmp, s.file)
        log.info("output set to %s", v)

    def pcm(s):
        """bluealsa's A2DP playback PCM for the speaker, or None."""
        try:
            r = subprocess.run([s.busctl, "--system", "--json=short", "call", "org.bluealsa", "/org/bluealsa",
                                "org.freedesktop.DBus.ObjectManager", "GetManagedObjects"],
                               capture_output=True, text=True, timeout=2)
            if r.returncode:
                return None
            for path, ifaces in json.loads(r.stdout)["data"][0].items():
                p = ifaces.get("org.bluealsa.PCM1")
                if p and s.dev in path and "a2dp" in path and p.get("Mode", {}).get("data") == "sink":
                    return {"path": path, **{k: v["data"] for k, v in p.items()}}
        except Exception as e:
            log.warning("bluealsa query failed: %s", e)
        return None

    def state(s):
        pcm = s.pcm()
        out = s.output()
        return {"output": out, "effective": "soundbar" if out == "soundbar" and pcm else "voice-pe",
                "mac": s.mac, "file": str(s.file), "stream_open": s.proc is not None,
                "sink": pcm and {k: pcm.get(k) for k in ("path", "Running", "Rate", "Channels", "Codec",
                                                         "Format", "Delay", "Volume") if k in pcm}}

    def use(s):
        return s.output() == "soundbar" and s.pcm() is not None

    def play(s, w, sr, t0=None):
        """Queue audio; the future resolves once its first frames are written."""
        f = concurrent.futures.Future()
        s.q.put((w, sr, t0, f))
        return f

    # -- writer thread --
    def _open(s):
        pcm = s.pcm()
        if not pcm:
            raise RuntimeError("speaker not connected")
        rate, ch = int(pcm.get("Rate") or pcm.get("Sampling") or 44100), int(pcm.get("Channels") or 2)
        t = time.perf_counter()
        s.proc = subprocess.Popen([s.aplay, "-q", "-D", f"bluealsa:DEV={s.mac},PROFILE=a2dp", "-t", "raw",
                                   "-f", "S16_LE", "-c", str(ch), "-r", str(rate),
                                   f"--buffer-time={s.buffer_us}", f"--period-time={s.period_us}"],
                                  stdin=subprocess.PIPE)
        try:
            fcntl.fcntl(s.proc.stdin.fileno(), s.F_SETPIPE_SZ, 4096)
        except OSError:
            pass
        s.fmt = (rate, ch)
        s.t_start, s.frames = time.perf_counter(), 0
        log.info("bt stream opened: %d Hz, %d ch, codec %s (%.0f ms)", rate, ch, pcm.get("Codec"),
                 (time.perf_counter() - t) * 1000)

    def _close(s):
        if s.proc:
            try:
                s.proc.stdin.close(); s.proc.wait(timeout=3)
            except Exception:
                s.proc.kill()
        s.proc = s.fmt = None

    def _write(s, pcm16):
        s.proc.stdin.write(pcm16); s.proc.stdin.flush()
        s.frames += len(pcm16) // (2 * s.fmt[1])

    def _silence(s, sec=None, frames=None):
        """Near-silence: +-1 LSB dither (-90 dBFS). Digital zero lets some
        soundbars power down their amp, which then clips the first word."""
        n = int(frames if frames is not None else sec * s.fmt[0]) * s.fmt[1]
        return np.random.randint(-1, 2, n, dtype=np.int16).tobytes()

    def _convert(s, w, sr):
        rate, ch = s.fmt
        if sr != rate:
            import soxr
            w = soxr.resample(w, sr, rate)
        x = (np.clip(w, -1, 1) * 32767).astype(np.int16)
        return np.repeat(x[:, None], ch, axis=1).tobytes() if ch > 1 else x.tobytes()

    def _idle(s):
        if s.proc is None:
            return
        if s.proc.poll() is not None:
            log.warning("bt aplay exited (%s)", s.proc.returncode); s.proc = s.fmt = None
            return
        rate = s.fmt[0]
        now = time.perf_counter()
        if now > s.reply_end + s.hold:
            log.info("bt stream idle %ds, closing", s.hold); s._close()
            return
        pos = (now - s.t_start) * rate
        if s.frames - pos < 0.04 * rate:  # keep ~60 ms of silence queued
            if s.frames < pos:
                s.frames = pos
            s._write(s._silence(frames=pos + 0.06 * rate - s.frames))

    def run(s):
        while True:
            try:
                w, sr, t0, fut = s.q.get(timeout=0.01)
            except queue.Empty:
                try:
                    s._idle()
                except Exception as e:
                    log.warning("bt idle write failed: %s", e); s._close()
                continue
            try:
                fresh = s.proc is None or s.proc.poll() is not None
                if fresh:
                    s._close(); s._open()
                    s._write(s._silence(s.lead))  # BT sinks clip the first syllable
                data = s._convert(w, sr)
                first = data[: 2 * s.fmt[1] * int(0.02 * s.fmt[0])]
                s._write(first)
                if t0 is not None:
                    log.info("bt first frame written %.0f ms after the request (%s stream, +%d ms lead-in)",
                             (time.perf_counter() - t0) * 1000, "new" if fresh else "open",
                             s.lead * 1000 if fresh else 0)
                fut.set_result(True)
                s._write(data[len(first):])
                s.reply_end = s.t_start + s.frames / s.fmt[0]
            except Exception as e:
                log.warning("bt playback failed: %s", e)
                if not fut.done():
                    fut.set_exception(e)
                s._close()


# ---- Wyoming -------------------------------------------------------------

ATT = Attribution(name="local", url="https://github.com/DavHau")


def info(cat):
    voices = [TtsVoice(name=v.id, description=f"{v.label} ({v.engine})", attribution=ATT, installed=True,
                       version="1", languages=list(v.langs)) for v in cat.all().values()]
    return Info(tts=[TtsProgram(name="speech-tts",
                                description="Kokoro-82M (en), Supertonic 3 (de), Wayu Kokoro-Thai (th), CPU",
                                attribution=ATT, installed=True, version="2", voices=voices)])


class Handler(AsyncEventHandler):
    def __init__(s, cat, bt, *a, **kw):
        super().__init__(*a, **kw)
        s.cat, s.bt = cat, bt

    async def handle_event(s, event: Event) -> bool:
        loop = asyncio.get_running_loop()
        if Describe.is_type(event.type):
            await loop.run_in_executor(None, s.cat.refresh)
            await s.write_event(info(s.cat).event())
            return True
        if not Synthesize.is_type(event.type):
            return True
        t_req = time.perf_counter()
        syn = Synthesize.from_event(event)
        text = " ".join(syn.text.split())
        lang = guess_lang(text, s.cat.last_spoken())
        v = await loop.run_in_executor(None, s.cat.voice_for, lang)
        bt = s.bt is not None and await loop.run_in_executor(None, s.bt.use)
        sr, total, sent = None, 0, False
        # Sentence by sentence only for the soundbar (its first audio starts
        # after the first sentence); the satellite gets one synthesis as before.
        for i, piece in enumerate(pieces(text) if bt else [text]):
            try:
                w, psr = await loop.run_in_executor(None, s.cat.synth, piece, v, lang)
            except Exception:
                log.exception("wyoming %s voice=%s synthesis failed: %s", lang, v.id, piece)
                if i:
                    continue  # the rest of the reply still plays
                # Never leave the satellite silent: say that speaking failed
                # (the reply itself is in the agent's history and this log).
                fb = {"de": "Entschuldige, die Antwort konnte ich nicht vorlesen.",
                      "th": "ขอโทษ อ่านคำตอบไม่ได้"}.get(lang, "Sorry, I couldn't read that answer out.")
                try:
                    w, psr = await loop.run_in_executor(None, s.cat.synth, fb, v, lang)
                except Exception:
                    fv = await loop.run_in_executor(None, s.cat.voice_for, "en")
                    w, psr = await loop.run_in_executor(None, s.cat.synth, "Sorry, I couldn't read that answer out.", fv, "en")
            if sr is None:
                sr = psr
            elif psr != sr:
                import soxr
                w = soxr.resample(w, psr, sr)
            if i:
                w = np.concatenate([np.zeros(int(0.12 * sr), np.float32), w])  # sentence gap
            out = w
            if bt and i == 0:
                # Wait for the first frames to reach the sink; later pieces
                # queue behind the playing audio.
                try:
                    await asyncio.wait_for(asyncio.wrap_future(s.bt.play(w, sr, t_req)), 3)
                    out = np.zeros(len(w) + int(s.bt.lead * sr), np.float32)
                except Exception as e:
                    log.warning("soundbar unavailable (%r): reply goes to the satellite", e)
                    bt = False
            elif bt:
                s.bt.play(w, sr)
                out = np.zeros(len(w), np.float32)
            if not sent:
                await s.write_event(AudioStart(rate=sr, width=2, channels=1).event())
                sent = True
            pcm = (np.clip(out, -1, 1) * 32767).astype(np.int16).tobytes()
            step = sr * 2  # 1 s chunks
            for j in range(0, len(pcm), step):
                await s.write_event(AudioChunk(audio=pcm[j:j + step], rate=sr, width=2, channels=1).event())
            total += len(w)
        log.info("wyoming %s voice=%s %.2fs audio in %.3fs -> %s (HA voice %s): %s", lang, v.id,
                 total / (sr or 1), time.perf_counter() - t_req, "soundbar" if bt else "satellite",
                 syn.voice.name if syn.voice else None, text)
        if not sent:
            await s.write_event(AudioStart(rate=24000, width=2, channels=1).event())
        await s.write_event(AudioStop().event())
        return True


# ---- HTTP ----------------------------------------------------------------

def wav_bytes(w, sr):
    b = io.BytesIO()
    with wave.open(b, "wb") as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(sr)
        f.writeframes((np.clip(w, -1, 1) * 32767).astype(np.int16).tobytes())
    return b.getvalue()


def api(cat, page, translate_url=None, bt=None):
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
        st = await run(cat.state)
        if bt is not None:
            st["output"] = await run(bt.state)
        return web.json_response(st, headers={"Cache-Control": "no-store"})

    async def get_output(req):
        if bt is None:
            return web.json_response({"output": "voice-pe", "effective": "voice-pe", "sink": None})
        return web.json_response(await run(bt.state), headers={"Cache-Control": "no-store"})

    async def put_output(req):
        b = await body(req)
        if bt is None:
            return web.json_response({"error": "no Bluetooth speaker configured"}, status=501)
        try:
            await run(bt.set_output, b.get("output") if isinstance(b, dict) else None)
        except ValueError as e:
            return web.json_response({"error": str(e)}, status=400)
        return web.json_response(await run(bt.state))

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
                    web.post("/preview", preview), web.post("/translate", translate),
                    web.get("/output", get_output), web.put("/output", put_output)])
    return app


async def serve(a, cat, bt):
    page = (Path(__file__).parent / "voices.html").read_text()
    runner = web.AppRunner(api(cat, page, a.translate_url, bt), access_log=None)
    await runner.setup()
    for host in a.api_host:
        await web.TCPSite(runner, host, a.api_port).start()
        log.info("HTTP voice API on [%s]:%d", host, a.api_port)
    await AsyncServer.from_uri(a.uri).run(partial(Handler, cat, bt))


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
    ap.add_argument("--last-lang-file", default=None, help="speech-stt's last utterance language (tie-breaker)")
    ap.add_argument("--bt-mac", default=None, help="A2DP speaker (bluealsa) for the replies")
    ap.add_argument("--bt-aplay", default="aplay")
    ap.add_argument("--bt-busctl", default="busctl")
    ap.add_argument("--bt-hold", type=float, default=30, help="s of silence keeping the stream open after a reply")
    ap.add_argument("--bt-lead", type=float, default=0.7,
                    help="s of near-silence before audio on a fresh stream (the soundbar wakes its amp)")
    ap.add_argument("--bt-buffer-us", type=int, default=100000)
    ap.add_argument("--bt-period-us", type=int, default=20000)
    ap.add_argument("--output-file", default=None, help='"soundbar" (default) or "voice-pe"')
    a = ap.parse_args()
    a.api_host = a.api_host or ["127.0.0.1"]
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    engines = [Kokoro82(a), Supertonic(a), WayuThai(a)]
    cat = Catalog(engines, a.voices_dir, a.selection_file, a.last_lang_file)
    for lang, text in (("en", "ok"), ("de", "ok"), ("th", "สวัสดี")):  # warm-up
        cat.synth(text, cat.voice_for(lang), lang)
    log.info("ready on %s, %d threads per engine, %d voices", a.uri, a.threads, len(cat.all()))
    bt = BtSink(a) if a.bt_mac and a.output_file else None
    if bt:
        log.info("bluetooth speaker %s, output %s", bt.mac, bt.state())
    asyncio.run(serve(a, cat, bt))


if __name__ == "__main__":
    main()
