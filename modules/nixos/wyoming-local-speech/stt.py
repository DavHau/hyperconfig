"""Wyoming STT server: Whisper large-v3-turbo int8 (OpenVINO, Intel iGPU) +
Pathumma Thai FastConformer-RNNT (ONNX via OpenVINO, CPU).

Per utterance: ONE Whisper encoder pass on the iGPU, one decoder step from
<|startoftranscript|> gives the language logits; softmax over en/de/th only.
P(th) >= SPEECH_TH_THRESHOLD -> Pathumma transcribes (CPU); otherwise the
same encoder output and decoder state continue to a greedy Whisper decode in
the detected language (en or de). Argmax is deliberately not used: Whisper
labels short Thai clips as English.

Derived from dave-hermes's ~/jobs/speechbench (adapters/ov_whisper.py,
adapters/ov_pathumma.py, lid.py). Env: see wyoming-local-speech.nix.
"""
import argparse, asyncio, json, logging, os, time
from functools import partial

import numpy as np
import librosa
import openvino as ov
from tokenizers import Tokenizer
from wyoming.asr import Transcribe, Transcript
from wyoming.audio import AudioChunk, AudioChunkConverter, AudioStart, AudioStop
from wyoming.event import Event
from wyoming.info import AsrModel, AsrProgram, Attribution, Describe, Info
from wyoming.server import AsyncEventHandler, AsyncServer

log = logging.getLogger("speech-stt")
LANGS = ["en", "de", "th"]
SR = 16000


def mel_whisper(a, fb):
    """openai-whisper log-mel: 30 s window, n_fft 400, hop 160, 128 mels."""
    a = a[: 30 * SR]
    a = np.pad(a, (0, 30 * SR - len(a)))
    S = librosa.stft(a, n_fft=400, hop_length=160, window="hann", center=True, pad_mode="reflect")
    P = np.abs(S[:, :-1]) ** 2
    m = np.log10(np.maximum(fb @ P, 1e-10))
    m = np.maximum(m, m.max() - 8.0)
    return ((m + 4.0) / 4.0).astype(np.float32)[None]


class Whisper:
    def __init__(s, d, dev, cache, check_clip=None):
        s.d, s.dev, s.cache = d, dev, cache
        c = ov.Core()
        c.set_property({"CACHE_DIR": cache})
        log.info("OpenVINO devices: %s; %s = %s", c.available_devices, dev,
                 c.get_property(dev, "FULL_DEVICE_NAME"))
        s.enc = c.compile_model(f"{d}/openvino_encoder_model.xml", dev)
        s.dec = c.compile_model(f"{d}/openvino_decoder_model.xml", dev)
        s.rq = s.dec.create_infer_request()
        s._init_tokens()
        if check_clip and dev != "CPU":
            s.self_check(check_clip)

    def self_check(s, clip, tries=5):
        """The iGPU decoder compile is nondeterministic on this host: some
        compiles (2 of 9 fresh ones in testing) are off by a token on a
        known clip and then loop ("Dies nen nen nen ..."), and CACHE_DIR keeps
        that compile for every later start. Greedy-decode a real clip on the
        iGPU and on the CPU decoder; recompile without the cache until the
        token sequences are identical (good compiles always matched)."""
        import shutil, soundfile as sf
        a, _ = sf.read(clip, dtype="float32")
        h = s.enc(mel_whisper(a, s.fb))[0]
        prefix = [s.sot, s.lang_ids[1], s.transcribe, s.notime]

        def greedy(rq):
            rq.reset_state(); out = []; ids = prefix
            for _ in range(96):
                rq.infer({"input_ids": np.array([ids], np.int64), "encoder_hidden_states": h,
                          "beam_idx": np.array([0], np.int32)})
                k = int(np.argmax(rq.get_tensor("logits").data[0, -1]))
                if k == s.eos:
                    break
                out.append(k); ids = [k]
            return out

        ref = greedy(ov.Core().compile_model(f"{s.d}/openvino_decoder_model.xml", "CPU").create_infer_request())
        for i in range(tries):
            got = greedy(s.rq)
            log.info("decoder self-check %d: %s (%d tokens)", i, "match" if got == ref else "MISMATCH", len(ref))
            if got == ref:
                return
            log.warning("bad %s decoder compile (%r), recompiling without cache", s.dev, s.tok.decode(got)[:60])
            shutil.rmtree(s.cache, ignore_errors=True)
            c = ov.Core(); c.set_property({"CACHE_DIR": s.cache})
            s.enc = c.compile_model(f"{s.d}/openvino_encoder_model.xml", s.dev)
            s.dec = c.compile_model(f"{s.d}/openvino_decoder_model.xml", s.dev)
            s.rq = s.dec.create_infer_request()
            h = s.enc(mel_whisper(a, s.fb))[0]
        raise SystemExit("Whisper decoder self-check failed %d times" % tries)

    def _init_tokens(s):
        d = s.d
        s.tok = Tokenizer.from_file(f"{d}/tokenizer.json")
        g = json.load(open(f"{d}/generation_config.json"))
        s.sot = g["decoder_start_token_id"]
        s.eos = g["eos_token_id"]
        s.transcribe = g["task_to_id"]["transcribe"]
        s.notime = g["no_timestamps_token_id"]
        s.lang_ids = [g["lang_to_id"][f"<|{l}|>"] for l in LANGS]
        s.suppress = np.array(g["suppress_tokens"], np.int64)
        s.begin_suppress = np.array(g["begin_suppress_tokens"], np.int64)
        s.fb = librosa.filters.mel(sr=SR, n_fft=400, n_mels=128).astype(np.float32)

    def _step(s, ids, h):
        s.rq.infer({"input_ids": np.array([ids], np.int64), "encoder_hidden_states": h,
                    "beam_idx": np.array([0], np.int32)})
        return s.rq.get_tensor("logits").data[0, -1].astype(np.float32)

    def encode_lid(s, a):
        h = s.enc(mel_whisper(a, s.fb))[0]
        s.rq.reset_state()
        lo = s._step([s.sot], h)[s.lang_ids].astype(np.float64)
        p = np.exp(lo - lo.max()); p /= p.sum()
        return h, dict(zip(LANGS, p.tolist()))

    def decode(s, h, lang, max_new=224):
        """Greedy decode continuing the decoder state left by encode_lid."""
        lo = s._step([s.lang_ids[LANGS.index(lang)], s.transcribe, s.notime], h)
        out = []
        for i in range(max_new):
            lo[s.suppress] = -np.inf
            if i == 0:
                lo[s.begin_suppress] = -np.inf
            k = int(np.argmax(lo))
            if k == s.eos:
                break
            out.append(k)
            lo = s._step([k], h)
        return s.tok.decode([t for t in out if t < s.eos]).strip()


class Pathumma:
    """Numpy NeMo mel frontend + greedy RNNT (adapters/ov_pathumma.py)."""

    def __init__(s, d, dev, cache, threads):
        s.info = json.load(open(f"{d}/info.json"))
        s.vocab = json.load(open(f"{d}/vocab.json"))
        s.blank = s.info["blank"]
        c = ov.Core()
        c.set_property({"CACHE_DIR": cache})
        s.enc = c.compile_model(f"{d}/encoder-model.onnx", dev, {"INFERENCE_NUM_THREADS": threads})
        s.dj = c.compile_model(f"{d}/decoder_joint-model.onnx", "CPU", {"INFERENCE_NUM_THREADS": 2})
        s.fb = librosa.filters.mel(sr=SR, n_fft=512, n_mels=80, fmin=0, fmax=8000, norm="slaney",
                                   htk=False).astype(np.float32)
        s.win = np.hanning(400 + 1)[:-1].astype(np.float32)

    def feats(s, a):
        a = np.concatenate([a[:1], a[1:] - 0.97 * a[:-1]]).astype(np.float32)
        S = librosa.stft(a, n_fft=512, hop_length=160, win_length=400, window=s.win, center=True,
                         pad_mode="constant")
        m = np.log(s.fb @ (np.abs(S) ** 2) + 2**-24)
        n = 1 + len(a) // 160
        m = m[:, :n]
        mu = m.mean(1, keepdims=True); sd = m.std(1, ddof=1, keepdims=True) + 1e-5
        return ((m - mu) / sd).astype(np.float32)[None], n

    def transcribe(s, a):
        x, n = s.feats(a)
        r = s.enc([x, np.array([n], np.int64)])
        enc = r[s.enc.outputs[0]]
        T = min(int(r[s.enc.outputs[1]][0]), enc.shape[2])
        h = np.zeros((1, 1, 640), np.float32); c = np.zeros((1, 1, 640), np.float32)
        last = s.blank; out = []
        for t in range(T):
            f = enc[:, :, t:t + 1]
            for _ in range(10):
                r = s.dj([f, np.array([[last]], np.int32), np.array([1], np.int32), h, c])
                k = int(np.argmax(r[s.dj.outputs[0]][0, 0, 0]))
                if k == s.blank:
                    break
                out.append(k); last = k; h = r[s.dj.outputs[2]]; c = r[s.dj.outputs[3]]
        return "".join(s.vocab[i] for i in out).replace("\u2581", " ").strip()


class Engine:
    def __init__(s, args):
        s.th_threshold = args.th_threshold
        s.last_lang_file = args.last_lang_file
        s.whisper = Whisper(args.whisper_dir, args.whisper_device, args.whisper_cache, args.check_clip)
        s.pathumma = Pathumma(args.pathumma_dir, "CPU", args.pathumma_cache, args.pathumma_threads)
        s.run(np.zeros(SR, np.float32))  # warm-up: first inference compiles kernels

    def run(s, a):
        t0 = time.perf_counter()
        h, p = s.whisper.encode_lid(a)
        t1 = time.perf_counter()
        if p["th"] >= s.th_threshold:
            lang, text = "th", s.pathumma.transcribe(a)
        else:
            lang = "de" if p["de"] > p["en"] else "en"
            text = s.whisper.decode(h, lang)
        t2 = time.perf_counter()
        log.info("audio %.2fs p=%s -> %s | encode+lid %.3fs, %s %.3fs, total %.3fs (1 encode): %s",
                 len(a) / SR, {k: round(v, 4) for k, v in p.items()}, lang, t1 - t0,
                 "pathumma" if lang == "th" else "whisper-decode", t2 - t1, t2 - t0, text)
        if s.last_lang_file:
            # The language Dave just spoke: speech-tts' tie-breaker when the
            # reply text alone doesn't say en or de (same host, same user).
            try:
                tmp = s.last_lang_file + ".tmp"
                with open(tmp, "w") as f:
                    f.write(lang)
                os.replace(tmp, s.last_lang_file)
            except OSError as e:
                log.warning("last-lang file: %s", e)
        return lang, text


class Handler(AsyncEventHandler):
    def __init__(s, info, engine, lock, *a, **kw):
        super().__init__(*a, **kw)
        s.info, s.engine, s.lock = info, engine, lock
        s.conv = AudioChunkConverter(rate=SR, width=2, channels=1)
        s.buf = bytearray()

    async def handle_event(s, event: Event) -> bool:
        if Describe.is_type(event.type):
            await s.write_event(s.info.event())
            return True
        if Transcribe.is_type(event.type):
            # HA passes the pipeline language; routing is automatic regardless.
            log.debug("requested language %s (ignored)", Transcribe.from_event(event).language)
            return True
        if AudioStart.is_type(event.type):
            s.buf = bytearray()
            return True
        if AudioChunk.is_type(event.type):
            s.buf += s.conv.convert(AudioChunk.from_event(event)).audio
            return True
        if AudioStop.is_type(event.type):
            a = np.frombuffer(bytes(s.buf), np.int16).astype(np.float32) / 32768.0
            s.buf = bytearray()
            async with s.lock:
                lang, text = await asyncio.get_running_loop().run_in_executor(
                    None, partial(s.engine.run, a))
            await s.write_event(Transcript(text=text, language=lang).event())
            return False
        return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--uri", required=True)
    ap.add_argument("--whisper-dir", required=True)
    ap.add_argument("--whisper-cache", required=True)
    ap.add_argument("--whisper-device", default="GPU")
    ap.add_argument("--check-clip", help="16 kHz mono German speech for the decoder self-check")
    ap.add_argument("--pathumma-dir", required=True)
    ap.add_argument("--pathumma-cache", required=True)
    ap.add_argument("--pathumma-threads", type=int, default=8)
    ap.add_argument("--last-lang-file", default=None, help="write the last utterance's language here (for speech-tts)")
    ap.add_argument("--th-threshold", type=float, required=True)
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s")
    engine = Engine(args)
    att = Attribution(name="local", url="https://github.com/DavHau")
    info = Info(asr=[AsrProgram(
        name="speech-stt", description="Whisper large-v3-turbo (iGPU) + Pathumma Thai (CPU), auto en/de/th",
        attribution=att, installed=True, version="1",
        models=[AsrModel(name="whisper-pathumma", description="auto en/de/th", attribution=att,
                         installed=True, languages=LANGS, version="1")])])
    lock = asyncio.Lock()
    log.info("ready on %s, Thai threshold P(th) >= %s", args.uri, args.th_threshold)
    asyncio.run(AsyncServer.from_uri(args.uri).run(partial(Handler, info, engine, lock)))


if __name__ == "__main__":
    main()
