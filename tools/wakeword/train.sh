#!/usr/bin/env bash
# Augment clips into features, then train + export the streaming int8 model.
#   train.sh            all steps (each skipped when its output exists)
#   MODEL=<name>        trained_models/<name>, config <name>.yaml (default okay_diggi)
#   POS="<sets>"        positive sets (default "positives"; "Hey Diggi":
#                       MODEL=hey_diggi POS=positives_hey; both in one model:
#                       POS="positives positives_hey", worse, see README)
# Positive sets: data/positives ("Okay Diggi"), data/positives_hey ("Hey
# Diggi"); each: EN LibriTTS-R generator, DE Piper voices, vit's
# Kokoro/Supertonic API voices. Adversarial near-misses: data/adversarial.
set -euo pipefail
WW=${WW:-/var/lib/wakeword}
. "$WW/env.sh"
cd "$WW"
PY=$WW/venv-tfn/bin/python
F=$WW/features
mkdir -p $F
MODEL=${MODEL:-okay_diggi}
POS=${POS:-positives}
for p in $POS; do
  [ -f $F/$p/.done ] || { $PY features.py data/$p $F/$p --train-repeat 2 && touch $F/$p/.done; }
done
[ -f $F/adversarial/.done ] || { $PY features.py data/adversarial $F/adversarial --train-repeat 1 && touch $F/adversarial/.done; }

# Positive sets share a sampling weight of 3 (2 for a single set).
w=$(awk -v n="$(echo $POS | wc -w)" 'BEGIN { print (n > 1 ? 3.0 / n : 2.0) }')
{ printf 'window_step_ms: 10\ntrain_dir: %s\nfeatures:\n' "$WW/trained_models/$MODEL"
for p in $POS; do
  echo "  - {features_dir: $F/$p, sampling_weight: $w, penalty_weight: 1.0, truth: true, truncation_strategy: truncate_start, type: mmap}"
done
cat <<EOF
  - {features_dir: $F/adversarial, sampling_weight: 3.0, penalty_weight: 1.0, truth: false, truncation_strategy: truncate_start, type: mmap}
  - {features_dir: $WW/data/negative_datasets/speech, sampling_weight: 10.0, penalty_weight: 1.0, truth: false, truncation_strategy: random, type: mmap}
  - {features_dir: $WW/data/negative_datasets/dinner_party, sampling_weight: 10.0, penalty_weight: 1.0, truth: false, truncation_strategy: random, type: mmap}
  - {features_dir: $WW/data/negative_datasets/no_speech, sampling_weight: 5.0, penalty_weight: 1.0, truth: false, truncation_strategy: random, type: mmap}
  - {features_dir: $WW/data/negative_datasets/dinner_party_eval, sampling_weight: 0.0, penalty_weight: 1.0, truth: false, truncation_strategy: split, type: mmap}
training_steps: [${STEPS:-20000}]
positive_class_weight: [1]
negative_class_weight: [20]
learning_rates: [0.001]
batch_size: 128
time_mask_max_size: [0]
time_mask_count: [0]
freq_mask_max_size: [0]
freq_mask_count: [0]
eval_step_interval: 500
clip_duration_ms: 1500
target_minimization: 0.9
minimization_metric: null
maximization_metric: average_viable_recall
EOF
} > $MODEL.yaml

# The model of the official v2 models (okay_nabu): mixednet, 4 blocks.
# Wrapper: fixed seeds (microWakeWord sets none) and a hard GPU memory cap
# (the GPU is shared with other users' jobs).
$PY -c '
import os, sys, random, runpy, numpy as np, tensorflow as tf
s = int(os.environ.get("SEED", "1234"))
random.seed(s); np.random.seed(s); tf.random.set_seed(s)
g = tf.config.list_physical_devices("GPU")
if g:
    tf.config.set_logical_device_configuration(g[0], [tf.config.LogicalDeviceConfiguration(memory_limit=int(os.environ.get("GPU_MB", "7000")))])
sys.argv = ["model_train_eval"] + sys.argv[1:]
runpy.run_module("microwakeword.model_train_eval", run_name="__main__")
' \
  --training_config=$MODEL.yaml \
  --train ${TRAIN:-1} --restore_checkpoint 1 \
  --test_tf_nonstreaming 0 --test_tflite_nonstreaming 0 --test_tflite_nonstreaming_quantized 0 \
  --test_tflite_streaming 0 --test_tflite_streaming_quantized 1 \
  --use_weights best_weights \
  mixednet --pointwise_filters "64,64,64,64" --repeat_in_block "1, 1, 1, 1" \
  --mixconv_kernel_sizes '[5], [7,11], [9,15], [23]' --residual_connection "0,0,0,0" \
  --first_conv_filters 32 --first_conv_kernel_size 5 --stride 3
echo train-done
