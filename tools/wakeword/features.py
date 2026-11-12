#!/usr/bin/env python3
"""Augment a directory of clips and write microWakeWord feature mmaps.

  features.py <clips_dir> <out_features_dir> [--train-repeat N]

Follows the microWakeWord notebook: 80/10/10 split (seed 10), training and
validation spectrograms slid by 10 frames (simulates streaming), testing
unslid. Output: <out>/{training,validation,testing}/wakeword_mmap.
"""
import argparse, os, random
import numpy as np
from mmap_ninja.ragged import RaggedMmap
from microwakeword.audio.augmentation import Augmentation
from microwakeword.audio.clips import Clips
from microwakeword.audio.spectrograms import SpectrogramGeneration

ap = argparse.ArgumentParser()
ap.add_argument("clips"); ap.add_argument("out")
ap.add_argument("--train-repeat", type=int, default=2)
ap.add_argument("--split", default="training,validation,testing")
ap.add_argument("--seed", type=int, default=10)
a = ap.parse_args()
random.seed(a.seed); np.random.seed(a.seed)
D = os.environ.get("WW", "/var/lib/wakeword") + "/data"

clips = Clips(input_directory=a.clips, file_pattern="**/*.wav", max_clip_duration_s=None,
              remove_silence=False, random_split_seed=a.seed, split_count=0.1)
aug = Augmentation(
    augmentation_duration_s=3.2,
    augmentation_probabilities={"SevenBandParametricEQ": 0.1, "TanhDistortion": 0.1, "PitchShift": 0.1,
                                "BandStopFilter": 0.1, "AddColorNoise": 0.1, "AddBackgroundNoise": 0.75,
                                "Gain": 1.0, "RIR": 0.5},
    impulse_paths=[f"{D}/mit_rirs"],
    background_paths=[f"{D}/fma_16k", f"{D}/audioset_16k"],
    background_min_snr_db=-5, background_max_snr_db=10,
    min_jitter_s=0.195, max_jitter_s=0.205)

for split in a.split.split(","):
    od = os.path.join(a.out, split); os.makedirs(od, exist_ok=True)
    name, rep, slide = {"training": ("train", a.train_repeat, 10),
                        "validation": ("validation", 1, 10),
                        "testing": ("test", 1, 1)}[split]
    sg = SpectrogramGeneration(clips=clips, augmenter=aug, slide_frames=slide, step_ms=10)
    RaggedMmap.from_generator(out_dir=os.path.join(od, "wakeword_mmap"),
                              sample_generator=sg.spectrogram_generator(split=name, repeat=rep),
                              batch_size=100, verbose=True)
print("features-done", a.clips, flush=True)
