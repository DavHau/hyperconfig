---
name: gpu-host
description: Run compute-heavy work (model training, batch inference, embeddings, anything torch/CUDA) on the GPU machine vit.d over ssh, as your own user. Use it whenever a job would be slow on CPU.
---

# GPU jobs on vit.d

`vit.d` has an NVIDIA RTX 5080 (16 GB VRAM). You have an account there with
your own user name. `ssh vit.d` logs you in with your key; no password,
no host-key prompt.

## What is already there

- `python3` in a login shell is your venv `~/.venv` with CUDA builds of
  torch, transformers, numpy, pandas, polars, pyarrow, duckdb, scikit-learn
  and friends. Check with
  `ssh vit.d 'python3 -c "import torch; print(torch.cuda.is_available())"'`.
- Extra Python packages: `ssh vit.d 'pip install <pkg>'` goes into that
  venv. Do not pip-install torch or CUDA libraries: the provided build is
  the one that matches the driver.
- Anything that is not a Python package: `nix shell nixpkgs#<pkg> -c ...`
  on vit.
- `/vault` is mounted there too (read-only for you). Read data in place,
  never copy datasets over.

## Workflow

1. Check the GPU is free: `ssh vit.d nvidia-smi`. Another user's job may
   hold the memory; wait or run on CPU instead of killing it.
2. Ship code, not data or environments:
   `rsync -a --mkpath --delete --exclude .venv --exclude out ./ vit.d:jobs/<name>/`
3. Run detached, so the job survives the ssh session (`bash -l` gives the
   job the same `python3` as your login shell):
   `ssh vit.d 'cd jobs/<name> && systemd-run --user --same-dir --unit job-<name> bash -lc "python3 run.py"'`
4. Follow: `ssh vit.d 'journalctl --user -u job-<name> -f'`;
   state: `ssh vit.d 'systemctl --user status job-<name>'`.
5. Fetch results: `rsync -a vit.d:jobs/<name>/out/ ./out/`.

Short interactive checks can run in the foreground: `ssh vit.d 'cd jobs/<name> && python3 check.py'`.

## Rules

- Your files on vit are yours only; leave other users' jobs alone.
- Write results under `~/jobs/<name>/out`, never into `/vault`.
- Clean up finished job directories you no longer need.
