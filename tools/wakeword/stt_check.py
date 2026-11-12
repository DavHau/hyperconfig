#!/usr/bin/env python3
"""Transcribe wavs through vit's Wyoming STT ([::1]:10300) and print speech span.
Usage: stt_check.py <wav>...  (quality check of generated positives)"""
import asyncio, json, sys
import numpy as np, soundfile as sf
from scipy.signal import resample_poly
from math import gcd


async def stt(pcm: bytes, host="::1", port=10300):
    r, w = await asyncio.open_connection(host, port)

    def ev(t, data=None, payload=b""):
        h = {"type": t, "data": data or {}}
        if payload:
            h["payload_length"] = len(payload)
        w.write((json.dumps(h) + "\n").encode() + payload)

    ev("transcribe", {"language": None})
    ev("audio-start", {"rate": 16000, "width": 2, "channels": 1})
    for i in range(0, len(pcm), 3200):
        ev("audio-chunk", {"rate": 16000, "width": 2, "channels": 1}, pcm[i:i + 3200])
    ev("audio-stop")
    await w.drain()
    while True:
        line = await r.readline()
        if not line:
            return None
        h = json.loads(line)
        n = h.get("data_length", 0) or 0
        d = json.loads(await r.readexactly(n)) if n else h.get("data", {})
        if h.get("payload_length"):
            await r.readexactly(h["payload_length"])
        if h["type"] == "transcript":
            w.close()
            return d.get("text")


for p in sys.argv[1:]:
    x, sr = sf.read(p, dtype="float32")
    if x.ndim > 1:
        x = x.mean(1)
    if sr != 16000:
        g = gcd(sr, 16000)
        x = resample_poly(x, 16000 // g, sr // g)
    e = np.abs(x)
    nz = np.flatnonzero(e > 0.05 * e.max())
    span = (nz[0] / 16000, nz[-1] / 16000) if len(nz) else (0, 0)
    t = asyncio.run(stt((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes()))
    print(f"{p}\t{len(x)/16000:.2f}s\tspeech {span[0]:.2f}-{span[1]:.2f}\t{t!r}", flush=True)
