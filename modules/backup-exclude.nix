[
  "/home/**/cache/"
  "/home/*/.cabal"
  "/home/*/.cache"
  "/home/*/.cargo"
  "/home/*/.config/Ferdium/Cache"
  "/home/*/.config/Ferdium/Partitions"
  "/home/*/.config/Mullvad VPN"
  "/home/*/.config/VSCodium"
  "/home/*/.local/share/containers"
  "/home/*/.local/share/Steam/steamapps/common"
  "/home/*/.local/share/TelegramDesktop"
  "/home/*/.local/share/TelegramDesktop/tdata/user_data/cache"
  "/home/*/.local/state/wireplumber"
  "/home/*/.nix-portable"
  "/home/*/.node-gyp"
  "/home/*/.npm"
  "/home/*/.platformio"
  "/home/*/.stack"
  "/home/*/.vagrant.d"
  "/home/*/.youtube-dl-gui"
  "/home/*/**/DawnCache"  # electron
  "/home/*/**/GPUCache"  # electron
  "/home/*/temp"
  "/home/*/VirtualBox VMs"
  "/home/*/.local/share/clan/"

  # filter out nix dev-shell builds
  "/home/**/*.o"
  "/home/**/nix/outputs"

  # invokeai models
  "/home/**/invokeai/models"
  "/home/*/.ollama"

  # localai models (manually specified via CLI args)
  "/home/*/.local/share/localai/"
]
