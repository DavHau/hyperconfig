# Source me after any nix call (this LD_LIBRARY_PATH breaks nix itself):
# runtime env for the pip wheels under nixpkgs' python on vit.
# Nix's python is not run through nix-ld, so give the wheels the nix-ld
# library set (libstdc++, zlib, ...) and the NVIDIA driver (libcuda).
export WW=${WW:-/var/lib/wakeword}
export LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib:/run/opengl-driver/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export HF_HOME=$WW/.hf
export TF_CPP_MIN_LOG_LEVEL=1
# GPU memory: train.sh caps TF at GPU_MB (default 7000 MB): the GPU is shared.
