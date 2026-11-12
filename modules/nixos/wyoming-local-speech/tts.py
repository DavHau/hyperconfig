"""Wyoming TTS server (CPU only): Supertonic 3 for en/de (built-in voices,
8 flow steps), Kokoro-Thai Q8 ONNX with the FastThaiG2P frontend for th
(voice thai_som). Derived from dave-hermes's
~/jobs/speechbench/adapters/cpu_tts_mix.py.

Engine selection: Thai script in the text -> Kokoro-Thai, whatever voice
or language HA asks for (an Assist pipeline pins one voice, but its replies
can be Thai). Otherwise Supertonic, language = the requested one, else de
if the text looks German, else en; voice = the requested Supertonic voice,
else the per-language default.
"""
import argparse, asyncio, logging, os, re, time
from functools import partial

import numpy as np
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.event import Event
from wyoming.info import Attribution, Describe, Info, TtsProgram, TtsVoice
from wyoming.server import AsyncEventHandler, AsyncServer
from wyoming.tts import Synthesize

log = logging.getLogger("speech-tts")
THAI = re.compile("[\u0e00-\u0e7f]")
DE_WORDS = set("der die das und ist nicht ich ein eine zu im mit auf den dem es sie wir ihr "
               "habe hat wird werden kann bitte danke ja nein licht".split())


def guess_lang(text):
    if THAI.search(text):
        return "th"
    w = re.findall(r"[a-zäöüß]+", text.lower())
    if re.search("[äöüß]", text.lower()) or sum(x in DE_WORDS for x in w) >= max(1, len(w) // 5):
        return "de"
    return "en"


class Engine:
    def __init__(s, a):
        from supertonic import TTS as ST
        from fastthaig2p.tts import TTS as THTTS

        s.steps = a.steps
        s.default = {"en": a.voice_en, "de": a.voice_de}
        s.st = ST(model="supertonic-3", model_dir=a.supertonic_dir, auto_download=False,
                  intra_op_num_threads=a.threads, inter_op_num_threads=1)
        s.st_voices = sorted(s.st.voice_style_names)
        s.styles = {v: s.st.get_voice_style(voice_name=v) for v in s.st_voices}
        k = a.kokoro_dir
        s.th = THTTS(f"{k}/kokoro_thai_q8.onnx", f"{k}/thai_som.npy", config_path=f"{k}/config.json",
                     intra_op_threads=a.threads)
        for lang in ("en", "de", "th"):  # warm-up
            s.synth("ok" if lang != "th" else "สวัสดี", None, lang)

    def synth(s, text, voice, lang):
        if THAI.search(text) or voice == "thai_som" or lang == "th":
            return "th", "thai_som", s.th.generate(text).astype(np.float32).reshape(-1), s.th.sample_rate
        if lang not in ("en", "de"):
            lang = "en"
        v = voice if voice in s.styles else s.default[lang]
        w, _ = s.st.synthesize(text, voice_style=s.styles[v], lang=lang, total_steps=s.steps)
        return lang, v, np.asarray(w, np.float32).reshape(-1), s.st.sample_rate


class Handler(AsyncEventHandler):
    def __init__(s, info, engine, lock, *a, **kw):
        super().__init__(*a, **kw)
        s.info, s.engine, s.lock = info, engine, lock

    async def handle_event(s, event: Event) -> bool:
        if Describe.is_type(event.type):
            await s.write_event(s.info.event())
            return True
        if not Synthesize.is_type(event.type):
            return True
        syn = Synthesize.from_event(event)
        text = " ".join(syn.text.split())
        name = syn.voice.name if syn.voice else None
        lang = (syn.voice.language if syn.voice else None) or guess_lang(text)
        lang = lang.split("-")[0].split("_")[0].lower()
        t0 = time.perf_counter()
        async with s.lock:
            lang, v, w, sr = await asyncio.get_running_loop().run_in_executor(
                None, partial(s.engine.synth, text, name, lang))
        dt = time.perf_counter() - t0
        log.info("%s/%s %.2fs audio in %.3fs: %s", lang, v, len(w) / sr, dt, text)
        pcm = (np.clip(w, -1, 1) * 32767).astype(np.int16).tobytes()
        await s.write_event(AudioStart(rate=sr, width=2, channels=1).event())
        step = sr * 2  # 1 s chunks
        for i in range(0, len(pcm), step):
            await s.write_event(AudioChunk(audio=pcm[i:i + step], rate=sr, width=2, channels=1).event())
        await s.write_event(AudioStop().event())
        return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--uri", required=True)
    ap.add_argument("--supertonic-dir", required=True)
    ap.add_argument("--kokoro-dir", required=True)
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--steps", type=int, default=8)
    ap.add_argument("--voice-en", default="F1")
    ap.add_argument("--voice-de", default="M1")
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    engine = Engine(a)
    att = Attribution(name="local", url="https://github.com/DavHau")
    voices = [TtsVoice(name=v, description=f"Supertonic 3 {v}", attribution=att, installed=True,
                       version="1", languages=["en", "de"]) for v in engine.st_voices]
    voices.append(TtsVoice(name="thai_som", description="Kokoro-Thai thai_som", attribution=att,
                           installed=True, version="1", languages=["th"]))
    info = Info(tts=[TtsProgram(name="speech-tts", description="Supertonic 3 (en/de) + Kokoro-Thai (th), CPU",
                                attribution=att, installed=True, version="1", voices=voices)])
    log.info("ready on %s, %d threads per engine", a.uri, a.threads)
    asyncio.run(AsyncServer.from_uri(a.uri).run(partial(Handler, info, engine, asyncio.Lock())))


if __name__ == "__main__":
    main()
