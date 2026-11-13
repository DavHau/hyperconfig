#!/usr/bin/env bash
# Generate positive ("Okay Diggi") and adversarial negative clips.
#   positives/en_libritts  Piper LibriTTS-R generator (.pt, ~900 speakers mixed)
#   positives/de_single    German Piper voices (.onnx; thorsten_emotional = 8
#                          speakers). de_DE-mls-medium is left out: its output
#                          is garbled even for plain German (checked via STT).
#   positives/tts_api      vit's Kokoro/Supertonic voices (tts_samples.py)
#   adversarial/*          near-miss phrases, same voices (trained as negatives)
set -euo pipefail
WW=${WW:-/var/lib/wakeword}
# nix itself must run before env.sh (its LD_LIBRARY_PATH breaks nix's libcurl)
export PATH=$(nix build --no-link --print-out-paths nixpkgs#wget)/bin:$PATH
. "$WW/env.sh"
cd "$WW/psg"
PY=$WW/venv-psg/bin/python
G="$PY -m piper_sample_generator"
D=$WW/data
mkdir -p $D/voices

# German Piper voices (pinned by HF revision)
HF=https://huggingface.co/rhasspy/piper-voices/resolve/${PIPER_VOICES_REV:-main}/de/de_DE
for v in thorsten/medium thorsten_emotional/medium kerstin/low ramona/low karlsson/low pavoque/low eva_k/x_low; do
  n=de_DE-${v%/*}-${v#*/}
  for ext in onnx onnx.json; do
    [ -s $D/voices/$n.$ext ] || wget -q -O $D/voices/$n.$ext "$HF/$v/$n.$ext"
  done
done

gen_pt() { # out text n
  [ -f "$1/.done" ] || { $G "$2" --model models/en_US-libritts_r-medium.pt --max-samples $3 \
    --batch-size 50 --max-speakers 800 --output-dir "$1" \
    --length-scales 0.8 0.9 1.0 1.1 1.25 --noise-scales 0.667 0.8 0.98 --noise-scale-ws 0.6 0.8 1.0 \
    --slerp-weights 0.2 0.5 0.8 && touch "$1/.done"; }
}
gen_onnx() { # out textfile n models...
  local out=$1 txt=$2 n=$3; shift 3
  [ -f "$out/.done" ] || { $G "$txt" $(printf -- '--model %s ' "$@") --max-samples $n \
    --output-dir "$out" --length-scales 0.85 1.0 1.15 1.3 --noise-scales 0.5 0.667 0.9 \
    --noise-scale-ws 0.6 0.8 1.0 && touch "$out/.done"; }
}

# English generator: phonetic spellings of DIG-gi (short i, hard g)
P=$D/positives
gen_pt $P/en_libritts/a "okay diggy" 1200
gen_pt $P/en_libritts/b "okay, diggy" 800
gen_pt $P/en_libritts/c "okay diggie" 600
gen_pt $P/en_libritts/d "okey diggy" 400

printf '%s\n' "Okay Diggi" "Okay, Diggi" "Okeh Diggi" "Okee Diggi" "Okay Diggi!" > $D/de_pos.txt
gen_onnx $P/de_single $D/de_pos.txt 1500 $D/voices/*.onnx

# Second phrase "Hey Diggi" (own model hey_diggi, train.sh POS=positives_hey):
# positives_hey (features/positives_hey), same voices and recipe.
PH=$D/positives_hey
gen_pt $PH/en_libritts/a "hey diggy" 1200
gen_pt $PH/en_libritts/b "hey, diggy" 800
gen_pt $PH/en_libritts/c "hey diggie" 600
gen_pt $PH/en_libritts/d "hay diggy" 400
printf '%s\n' "Hey Diggi" "Hey, Diggi" "Hei Diggi" "Hey Diggy" "Hey Diggi!" > $D/de_pos_hey.txt
gen_onnx $PH/de_single $D/de_pos_hey.txt 1500 $D/voices/*.onnx

# Adversarial negatives: partial phrases and similar-sounding words.
# Not "Hey Diggi"/"hey diggy": those are positives now.
A=$D/adversarial
printf '%s\n' "okay" "okay nabu" "okay google" "hey siri" "okay so" "okay did he" \
  "diggy" "okay ricky" "okay vicky" "okay dicky" "okay biggie" "oh kay digger" \
  "okay ziggy" "okay dig it" "okay, tiggy" "diggy diggy" "okay doggy" \
  "okay kitty" "okay dicky dig" "I digged it" "okay, did he go" > $D/en_adv.txt
printf '%s\n' "Okay" "Diggi" "Digga" "Alter Diggi" "Okay Digga" "Okay, Dicke" "Okay Ricky" \
  "Okay Nabu" "Okay Tiki" "Okay, gib mir" "Oh, die Kiste" "Okay, wie geht es dir" \
  "Ok, dicker" "Okay, Dichter" "Okay, Dieter" "Okay Biggi" "Okay, mit dir" \
  "Dicke Luft" "okay, ich gehe" > $D/de_adv.txt
[ -f $A/en/.done ] || { mkdir -p $A/en; i=0; while read -r t; do
  $G "$t" --model models/en_US-libritts_r-medium.pt --max-samples 60 --batch-size 60 \
    --max-speakers 800 --output-dir $A/en/$i; i=$((i+1)); done < $D/en_adv.txt; touch $A/en/.done; }
gen_onnx $A/de_single $D/de_adv.txt 1200 $D/voices/*.onnx
# near misses of "Hey Diggi"
printf '%s\n' "hey" "hey jarvis" "hey mycroft" "hey google" "hey ricky" "hey kitty" \
  "hey biggie" "hey there" "hey did he" "hey, dig it" > $D/en_adv_hey.txt
printf '%s\n' "Hey" "Hey Digga" "Hey, Dicke" "Hey du" "Hey Siri" "Hey, gib mir" "Hey Ricky" \
  "Hey, die Kiste" "Hey, mit dir" "Hey Biggi" > $D/de_adv_hey.txt
[ -f $A/hey_en/.done ] || { mkdir -p $A/hey_en; i=0; while read -r t; do
  $G "$t" --model models/en_US-libritts_r-medium.pt --max-samples 60 --batch-size 60 \
    --max-speakers 800 --output-dir $A/hey_en/$i; i=$((i+1)); done < $D/en_adv_hey.txt; touch $A/hey_en/.done; }
gen_onnx $A/hey_de_single $D/de_adv_hey.txt 600 $D/voices/*.onnx

# TTS API voices (CPU service on vit; sequential, modest rate)
[ -f $P/tts_api/.done ] || { $PY $WW/tts_samples.py $P/tts_api && touch $P/tts_api/.done; }
[ -f $PH/tts_api/.done ] || { $PY $WW/tts_samples.py $PH/tts_api hey && touch $PH/tts_api/.done; }

# Hold out 6 API voices entirely (unseen speakers) for eval_tflite.py
held() { # tts_dir heldout_dir
  [ -d $2 ] && return
  mkdir -p $2
  for v in kokoro82-af_sky kokoro82-am_echo kokoro82-bf_lily kokoro82-bm_lewis supertonic-F3 supertonic-M4; do
    mv $1/*_${v}__*.wav $2/
  done
}
held $P/tts_api $D/heldout_pos
held $PH/tts_api $D/heldout_pos_hey
echo generate-done
