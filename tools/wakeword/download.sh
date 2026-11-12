#!/usr/bin/env bash
# Download the negative feature sets (pre-computed microWakeWord spectrograms)
# and the raw augmentation audio (MIT RIRs, AudioSet balanced-train shards,
# FMA xs), converted to 16 kHz mono 16-bit wavs.
set -euo pipefail
WW=${WW:-/var/lib/wakeword}
export PATH=$(nix build --no-link --print-out-paths nixpkgs#unzip nixpkgs#wget nixpkgs#ffmpeg-headless.bin | sed 's|$|/bin|' | tr '\n' ':')$PATH
. "$WW/env.sh"
PY=$WW/venv-tfn/bin/python
mkdir -p "$WW/data/negative_datasets" "$WW/data/audioset" "$WW/data/fma"
cd "$WW/data"
root=https://huggingface.co/datasets/kahrendt/microwakeword/resolve/main
for f in dinner_party.zip dinner_party_eval.zip no_speech.zip speech.zip; do
  [ -f negative_datasets/.$f.done ] && continue
  wget -q -c -O negative_datasets/$f $root/$f
  unzip -q -o negative_datasets/$f -d negative_datasets && rm negative_datasets/$f
  touch negative_datasets/.$f.done
done

# MIT impulse responses
if [ ! -f mit_rirs/.done ]; then
  mkdir -p mit_rirs
  $PY - <<'P'
import datasets, numpy as np, scipy.io.wavfile, os
ds = datasets.load_dataset("davidscripka/MIT_environmental_impulse_responses", split="train", streaming=True)
for row in ds:
    name = row["audio"]["path"].split("/")[-1]
    scipy.io.wavfile.write(os.path.join("mit_rirs", name), 16000, (row["audio"]["array"] * 32767).astype(np.int16))
P
  touch mit_rirs/.done
fi

# AudioSet (agkphysics/AudioSet now ships parquet shards with embedded audio)
mkdir -p audioset_16k
for s in 00 07; do
  [ -f audioset/.$s.done ] && continue
  wget -q -c -O audioset/$s.parquet https://huggingface.co/datasets/agkphysics/AudioSet/resolve/main/data/bal_train/$s.parquet
  $PY - audioset/$s.parquet <<'P'
import sys, io, os, numpy as np, soundfile as sf, pyarrow.parquet as pq, subprocess
t = pq.read_table(sys.argv[1])
col = [c for c in t.column_names if "audio" in c.lower()][0]
for i, a in enumerate(t.column(col).to_pylist()):
    out = f"audioset_16k/{os.path.basename(sys.argv[1])[:2]}_{i}.wav"
    if os.path.exists(out): continue
    b = a["bytes"] if isinstance(a, dict) else a
    r = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", "pipe:0", "-ac", "1", "-ar", "16000",
                        "-sample_fmt", "s16", "-y", out], input=b)
P
  rm audioset/$s.parquet; touch audioset/.$s.done
done
# One more shard, never used for training: held-out background audio for
# eval_tflite.py's false-accept count (~1000 clips of 10 s).
if [ ! -f audioset/.heldout.done ]; then
  wget -q -c -O audioset/20.parquet https://huggingface.co/datasets/agkphysics/AudioSet/resolve/main/data/bal_train/20.parquet
  mkdir -p heldout_neg && (cd heldout_neg && mkdir -p audioset_16k && $PY - ../audioset/20.parquet <<'P'
import sys, os, subprocess, pyarrow.parquet as pq
t = pq.read_table(sys.argv[1])
col = [c for c in t.column_names if "audio" in c.lower()][0]
for i, a in enumerate(t.column(col).to_pylist()):
    b = a["bytes"] if isinstance(a, dict) else a
    subprocess.run(["ffmpeg", "-loglevel", "error", "-i", "pipe:0", "-ac", "1", "-ar", "16000",
                    "-sample_fmt", "s16", "-y", f"audioset_16k/20_{i}.wav"], input=b)
P
  )
  rm audioset/20.parquet; touch audioset/.heldout.done
fi

# Free Music Archive, extra-small subset
if [ ! -f fma/.done ]; then
  wget -q -c -O fma/fma_xs.zip https://huggingface.co/datasets/mchl914/fma_xsmall/resolve/main/fma_xs.zip
  (cd fma && unzip -q -o fma_xs.zip && rm fma_xs.zip)
  mkdir -p fma_16k
  find fma -name '*.mp3' -print0 | xargs -0 -P 8 -I{} sh -c 'ffmpeg -loglevel error -i "$1" -ac 1 -ar 16000 -sample_fmt s16 -y "fma_16k/$(basename "$1" .mp3).wav"' _ {}
  touch fma/.done
fi
echo download-done
