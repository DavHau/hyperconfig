#!/usr/bin/env python3
"""Drop generated positives the local STT does not hear as 'okay diggi'.

  filter_positives.py <dir> <rejected_dir> [hey]

Low-quality Piper voices sometimes mumble ('Okay, Titi', 'So fettig ist').
Keeps a clip when the transcript has an 'ok' word (with `hey`: hey/hei/hi/high/
hay) and a d+vowel+g/k/c word.
"""
import asyncio, os, re, shutil, sys, glob
sys.argv, args = sys.argv[:1], sys.argv[1:]
import importlib.util
spec = importlib.util.spec_from_file_location("stt", os.path.join(os.path.dirname(__file__), "stt_check.py"))
import numpy as np, soundfile as sf
src = open(spec.origin).read().split("\nfor p in sys.argv[1:]:")[0]
ns = {}; exec(src, ns)
OK = re.compile(r"\bo\s*-?\s*k|\bokay|\boke", re.I)
if args[2:] == ["hey"]:
    OK = re.compile(r"\b(hey|hei|hay|hi|high)\b", re.I)
DIG = re.compile(r"d[iíeéyä]+[gkc]", re.I)
d, rej = args[:2]
os.makedirs(rej, exist_ok=True)
kept = dropped = 0
for p in sorted(glob.glob(os.path.join(d, "*.wav"))):
    x, sr = sf.read(p, dtype="float32")
    assert sr in (16000, 22050), sr
    if sr != 16000:
        from scipy.signal import resample_poly
        x = resample_poly(x, 320, 441)
    t = asyncio.run(ns["stt"]((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())) or ""
    if OK.search(t) and DIG.search(t):
        kept += 1
    else:
        dropped += 1; shutil.move(p, os.path.join(rej, os.path.basename(p)))
        print("drop", os.path.basename(p), repr(t), flush=True)
print(f"kept {kept} dropped {dropped}")
