#!/usr/bin/env bash
# Set up the microWakeWord training environment on vit (x86_64, NVIDIA GPU).
# Runs as root in $WW (default /var/lib/wakeword). Idempotent.
# Python wheels run through nix-ld (vit has programs.nix-ld enabled).
set -euo pipefail
WW=${WW:-/var/lib/wakeword}
MWW_REV=4665173cd35f1cff9a61e06fc427f124766c488e   # kahrendt/microWakeWord
PSG_REV=2971426a55072f7d22fec416ca7800df8bd23207   # rhasspy/piper-sample-generator (v3.2.0)
UV=$(nix build --no-link --print-out-paths nixpkgs#uv)/bin/uv
PY=$(nix build --no-link --print-out-paths nixpkgs#python312)/bin/python3
export PATH=$(nix build --no-link --print-out-paths nixpkgs#ffmpeg-headless.bin nixpkgs#unzip nixpkgs#wget nixpkgs#git | sed 's|$|/bin|' | tr '\n' ':')$PATH
export UV_CACHE_DIR=$WW/.uv-cache
mkdir -p "$WW" && cd "$WW"

[ -d mww ] || git clone https://github.com/kahrendt/microWakeWord.git mww
git -C mww checkout -q $MWW_REV
[ -d psg ] || git clone https://github.com/rhasspy/piper-sample-generator.git psg
git -C psg checkout -q $PSG_REV

# Sample generation venv (torch with sm_120 / Blackwell support: cu128 wheels)
if [ ! -x venv-psg/bin/python ]; then
  $UV venv -p "$PY" venv-psg
  VIRTUAL_ENV=$WW/venv-psg $UV pip install --index-strategy unsafe-best-match \
    --extra-index-url https://download.pytorch.org/whl/cu128 \
    'torch==2.9.1' 'torchaudio==2.9.1' 'piper-tts==1.3.0' 'audiomentations==0.33.0' \
    'numpy>=2,<3' webrtcvad soundfile scipy requests
  VIRTUAL_ENV=$WW/venv-psg $UV pip install --no-deps -e ./psg
fi
[ -f psg/models/en_US-libritts_r-medium.pt ] || wget -q -O psg/models/en_US-libritts_r-medium.pt \
  https://github.com/rhasspy/piper-sample-generator/releases/download/v2.0.0/en_US-libritts_r-medium.pt

# Training venv. TF 2.20/2.21 wheels cannot use the RTX 5080 (sm_120);
# the nightly JIT-compiles PTX for it (first steps are slow).
if [ ! -x venv-tfn/bin/python ]; then
  $UV venv -p "$PY" venv-tfn
  VIRTUAL_ENV=$WW/venv-tfn $UV pip install -c <(grep -v '^-e' $WW/requirements-train.txt) 'tf-nightly[and-cuda]==2.23.0.dev20261111' \
    audiomentations 'git+https://github.com/whatsnowplaying/audio-metadata@d4ebb238e6a401bb1a5aaaac60c9e2b3cb30929f' \
    'datasets<4' tb-nightly mmap_ninja pymicro-features pyyaml webrtcvad-wheels ai-edge-litert soundfile scipy tqdm
  # microWakeWord's own deps would pull the stable tensorflow wheel.
  VIRTUAL_ENV=$WW/venv-tfn $UV pip install --no-deps -e ./mww
fi
# The versions of the trained model: requirements-{train,psg}.txt here.
VIRTUAL_ENV=$WW/venv-tfn $UV pip freeze > "$WW/freeze-tfn.txt"
VIRTUAL_ENV=$WW/venv-psg $UV pip freeze > "$WW/freeze-psg.txt"
echo setup-done
