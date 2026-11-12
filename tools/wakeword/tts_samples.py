#!/usr/bin/env python3
"""Extra 'Okay Diggi' speakers from vit's local TTS API (Kokoro EN, Supertonic DE/EN).

Writes 16 kHz mono wavs to <out>/<voice>__<n>.wav. Sequential requests with a
short pause: the same service answers Home Assistant.
"""
import io, json, sys, time, urllib.request, pathlib
import numpy as np, soundfile as sf
from scipy.signal import resample_poly
from math import gcd

API = "http://127.0.0.1:10201"
TEXTS = ["Okay Diggi", "Okay, Diggi", "Okeh Diggi", "Okay Diggi!", "Okay Diggi?", "Okay, Diggi."]
out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
voices = json.load(urllib.request.urlopen(API + "/voices"))["languages"]
jobs = []
for lang in ("en", "de"):
    for v in voices[lang]["voices"]:
        if v["engine"] not in ("kokoro82", "supertonic"):
            continue
        for i, t in enumerate(TEXTS):
            jobs.append((lang, v["id"], i, t))
print(len(jobs), "requests", flush=True)
for lang, vid, i, t in jobs:
    p = out / f"{lang}_{vid.replace('/', '-')}__{i}.wav"
    if p.exists():
        continue
    req = urllib.request.Request(API + "/preview", method="POST",
                                 data=json.dumps({"lang": lang, "voice": vid, "text": t}).encode(),
                                 headers={"content-type": "application/json"})
    try:
        w, sr = sf.read(io.BytesIO(urllib.request.urlopen(req, timeout=60).read()), dtype="float32")
    except Exception as e:
        print("fail", vid, t, e, flush=True); continue
    if w.ndim > 1:
        w = w.mean(1)
    g = gcd(sr, 16000)
    w = resample_poly(w, 16000 // g, sr // g)
    # trim leading/trailing near-silence, keep 100 ms margin
    nz = np.flatnonzero(np.abs(w) > 0.01 * np.abs(w).max())
    if len(nz):
        w = w[max(0, nz[0] - 1600): nz[-1] + 1600]
    sf.write(p, (np.clip(w, -1, 1) * 32767).astype(np.int16), 16000)
    time.sleep(0.3)
print("tts-done", flush=True)
