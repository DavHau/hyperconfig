#!/usr/bin/env python3
"""Offline check of the exported streaming int8 model, as the device runs it.

  eval_tflite.py <model.tflite> <cutoff> <window> <positives_dir> [<negative wavs dir>...]

Streams each wav through pymicro-features (the same frontend as ESPHome),
feeds the int8 model stride-by-stride, averages the last <window> outputs,
and reports recall (positives that trigger) and false triggers per hour on
the negatives (cooldown 1 s after an accept).
"""
import sys, glob, os
import numpy as np, soundfile as sf
from ai_edge_litert.interpreter import Interpreter
from pymicro_features import MicroFrontend


def features(x16):
    fe = MicroFrontend(); out = []
    b = (np.clip(x16, -1, 1) * 32767).astype("<i2").tobytes()
    i = 0
    while i + 320 <= len(b):  # 10 ms chunks of 16 kHz 16-bit
        r = fe.process_samples(b[i:i + 320]); i += r.samples_read * 2
        if r.features:
            out.append(r.features)
    return np.array(out, dtype=np.float32)


class Stream:
    def __init__(s, path):
        s.it = Interpreter(model_path=path); s.it.allocate_tensors()
        s.inp = s.it.get_input_details()[0]; s.out = s.it.get_output_details()[0]
        s.stride = s.inp["shape"][1]
        s.isc, s.izp = s.inp["quantization"]; s.osc, s.ozp = s.out["quantization"]

    def probs(s, feats):
        s.it.reset_all_variables()
        p = []
        for j in range(0, len(feats) - s.stride + 1, s.stride):
            q = np.round(feats[j:j + s.stride] / s.isc + s.izp).clip(-128, 127).astype(np.int8)
            s.it.set_tensor(s.inp["index"], q[None]); s.it.invoke()
            o = s.it.get_tensor(s.out["index"])[0][0]
            p.append((float(o) - s.ozp) * s.osc)
        return np.array(p)


def load(p):
    x, sr = sf.read(p, dtype="float32")
    if x.ndim > 1: x = x.mean(1)
    assert sr == 16000, p
    return x


def detections(p, cutoff, win, cooldown):
    n, last = 0, -10**9
    if len(p) < win: return 0
    avg = np.convolve(p, np.ones(win) / win, "valid")
    for k, v in enumerate(avg):
        if v > cutoff and k - last >= cooldown:
            n += 1; last = k
    return n


m = Stream(sys.argv[1]); cutoff = float(sys.argv[2]); win = int(sys.argv[3])
step_s = m.stride * 0.01
pos = sorted(glob.glob(os.path.join(sys.argv[4], "**/*.wav"), recursive=True))
hits = 0
for f in pos:
    x = np.concatenate([np.zeros(8000, np.float32), load(f), np.zeros(8000, np.float32)])
    hits += detections(m.probs(features(x)), cutoff, win, 10**9) > 0
print(f"recall {hits}/{len(pos)} = {hits/max(1,len(pos)):.3f} (cutoff {cutoff}, window {win})")
fa, dur = 0, 0.0
for d in sys.argv[5:]:
    for f in sorted(glob.glob(os.path.join(d, "**/*.wav"), recursive=True)):
        x = load(f); dur += len(x) / 16000
        fa += detections(m.probs(features(x)), cutoff, win, int(1.0 / step_s))
if dur:
    print(f"false accepts {fa} in {dur/3600:.2f} h = {fa/(dur/3600):.2f}/h")
