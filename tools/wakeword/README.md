# Custom wake words "Okay Diggi" and "Hey Diggi" (microWakeWord)

The Voice PE in Dave's home (`locations/home/esphome/voice-pe.yaml`) runs
two models: "Okay Diggi" in wake word slot 1, "Hey Diggi" in slot 2
("Okay Nabu" stays selectable). Models and manifests live next to the
device config, in `locations/home/esphome/{okay,hey}_diggi/` (~60 KB each).

## One model or two (2026-11-13)

Both trained with the same recipe, seed and 20k steps, then
`eval_tflite.py` (window 5) on 48 held-out clips per phrase (6 unseen API
voices) and 500 held-out AudioSet clips (1.37 h):

| model | cutoff | Okay recall | Hey recall | FA/h |
|---|---|---|---|---|
| combined (`POS="positives positives_hey"`) | 0.5 | 46/48 | 37/48 | 0 |
| combined | 0.3 | 47/48 | 38/48 | 2.9 |
| `okay_diggi` (unchanged) | 0.6 | 47/48 | 6/48 | 2.2 |
| `hey_diggi` (`POS=positives_hey`) | 0.9 | 5/48 | 48/48 | 0 |
| `hey_diggi` | 0.85 | | 48/48 | 1.5 |

The combined model misses whole voices (Kokoro am_echo, bm_lewis: max
score < 0.65 on every "Hey" clip); the separate model hears all of them.
Cost of the second model: one more ~60 KB model in flash and, while it
is active, a ~37 KB tensor arena plus inference per 30 ms stride
(disabled models are unloaded; the factory firmware runs okay_nabu,
hey_jarvis, hey_mycroft, stop and vad the same way). FA/h of two active
models add up: ~2.2/h at 0.6 + 0/h at 0.9 on this set.

## Pipeline (vit, root, `/var/lib/wakeword`)

Copy this directory to `/var/lib/wakeword` on vit and run the steps in
order, each one detached (`systemd-run --unit=ww-<step> ... bash <step>.sh`
with `PATH=/run/current-system/sw/bin`). Every step skips what is done.

| step | what |
|---|---|
| `setup.sh` | clones microWakeWord and piper-sample-generator at pinned commits, venvs from nixpkgs' python 3.12 + uv |
| `download.sh` | microWakeWord negative feature sets (HF `kahrendt/microwakeword`), MIT RIRs, 2 AudioSet shards, FMA xs (all 16 kHz); a third AudioSet shard as held-out eval audio |
| `generate.sh` | positives and adversarial negatives (below), holds out 6 API voices |
| `filter_positives.py data/positives/de_single data/rejected/de_single` | drops German Piper clips the local Whisper does not hear as "okay diggi" (kept 503 of 1500); for "Hey Diggi": `data/positives_hey/de_single data/rejected/hey_de_single hey` (kept 260) |
| `train.sh` | augmentation -> feature mmaps (`features.py`), then microWakeWord's trainer: mixednet like the official v2 models, 20k steps, int8 streaming export + eval; `MODEL=hey_diggi POS=positives_hey` for the second model |
| `eval_tflite.py` | the exported model run the way ESPHome runs it, on held-out clips (`data/heldout_pos`, `data/heldout_pos_hey`); several cutoffs comma-separated |

Versions that matter: microWakeWord `4665173c`, piper-sample-generator
`2971426a` (v3.2.0), torch 2.9.1+cu128, **tf-nightly 2.23.0.dev20261111**:
TF 2.20 and 2.21 cannot run on the RTX 5080 (sm_120: `CUDA_ERROR_INVALID_HANDLE`
or no GPU); the nightly JIT-compiles PTX for it. Full pins of the trained
model: `requirements-train.txt` / `requirements-psg.txt` (setup.sh uses the
first as constraints). Seeds: split 10, training 1234 (`SEED`).
Run the offline check:
`venv-tfn/bin/python eval_tflite.py <tflite> 0.8 5 data/heldout_pos data/heldout_neg`.
`env.sh` gives the pip wheels the nix-ld library set; source it only after
any `nix` call (its `LD_LIBRARY_PATH` breaks nix's own libcurl). GPU memory
is capped at `GPU_MB` (7000): the GPU is shared.

## Data

- Positives: Piper's LibriTTS-R generator (~800 speakers mixed, spellings
  "okay diggy/diggie", "okey diggy"), German Piper voices (thorsten,
  thorsten_emotional (8 speakers), kerstin, ramona, karlsson, pavoque,
  eva_k; "Okay Diggi", "Okeh Diggi", ...), and vit's own TTS API
  (`127.0.0.1:10201/preview`: 38 EN voices, 10 Supertonic, 6 spellings each;
  `tts_samples.py`, one request at a time, it also serves HA).
  `de_DE-mls-medium` is left out: its output is garbled even for plain German.
- "Hey Diggi" positives (`data/positives_hey`): the same voices with
  "hey diggy/diggie", "hay diggy", "Hey Diggi", "Hei Diggi", "Hey Diggy".
- Adversarial negatives: "okay", "okay nabu", "diggy", "okay ricky/vicky/
  biggie/ziggy/doggy", "Digga", "Okay Dieter", "hey siri/jarvis/mycroft",
  "Hey Digga", "Hey du", ... (`generate.sh`). "Hey Diggi" was an
  adversarial until 2026-11-13 (`okay_diggi` was trained that way, which
  keeps the two models apart); it is a positive now.
- Negatives: microWakeWord's speech / dinner party / no-speech sets;
  false accepts are validated on its `dinner_party_eval` ambient set.

## Result "Hey Diggi" (model of 2026-11-13, seed 1234, 20k steps)

`hey_diggi.tflite` (63 KB, sha256 `b8a31a36…`), cutoff 0.90 in
voice-pe.yaml. Held-out: 0.90 -> recall 48/48, 0/h; 0.85 -> 48/48,
1.46/h; 0.80 -> 48/48, 2.20/h; 0.70 -> 48/48, 4.39/h. Trainer on
`dinner_party_eval`: 0.89 -> 8.9 % FRR, 0.75 FA/h; 0.95 -> 11 %, 0.38/h.

## Result "Okay Diggi" (model of 2026-11-12, seed 1234, 20k steps, best weights)

`okay_diggi.tflite` (63 KB, int8 streaming, sha256 `08c53148…`), manifest
cutoff 0.80, sliding window 5.

- Trainer, `dinner_party_eval` ambient set (`eval-roc.txt`): cutoff 0.88
  -> 20 % false rejects, 0 false accepts/h; 0.61 -> 13 % FRR, 0.19 FA/h;
  0.58 -> 12 % FRR, 0.56 FA/h.
- `eval_tflite.py` on held-out data (6 unseen API voices, 48 clips; 500
  AudioSet clips = 1.37 h never trained on): cutoff 0.80/window 5 ->
  recall 47/48, 1 false accept (0.73/h); 0.93 -> 45/48, 0.73/h;
  0.97 -> 43/48, 0/h. AudioSet is harder than a living room (dense
  speech, music), and 1.37 h is a small sample: ±1 accept moves it a lot.
- If it fires falsely at home, raise `probability_cutoff` (0.9-0.95);
  if it under-triggers, lower it or retrain with Dave's takes (below).

## Retraining with Dave's own voice (if it under-triggers)

Record 30-50 takes of "Okay Diggi" in the room where the device stands,
different distances (0.5-4 m), speeds and loudness, some with the TV or
music on. Any phone recorder works; then on vit:

    mkdir -p /var/lib/wakeword/data/positives/dave
    # copy the files there, then convert to 16 kHz mono wav:
    for f in *.m4a; do ffmpeg -i "$f" -ac 1 -ar 16000 "${f%.*}.wav"; done
    rm -r /var/lib/wakeword/features/positives /var/lib/wakeword/trained_models
    systemd-run --unit=ww-train ... bash /var/lib/wakeword/train.sh

Each take gets augmented (noise, room impulse responses) like the
synthetic ones. Then copy the new `.tflite` into
`locations/home/esphome/okay_diggi/`, set the cutoff from the trainer's
table, bump the firmware `version` and flash (`voice-pe.yaml` header).
