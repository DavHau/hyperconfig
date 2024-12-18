{config, lib, inputs, ...}: {

  # acceept unfree license only for these packages
  nixpkgs.config = {
    allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
      "steam"
      "steam-original"
      "steam-runtime"
      "steam-run"
      "steam-unwrapped"
      "teamspeak-client"
      "teamviewer"
      "vagrant"
      "vscode"
      "vscode-extension-ms-vscode-cpptools"
      "vscode-extension-github-copilot"
      "vscode-extension-github-copilot-chat"
      # "vscode-extension-MS-python-vscode-pylance"
      # "vscode-extension-ms-python-vscode-pylance"
      "vscode-extension-ms-vsliveshare-vsliveshare"
      "zerotierone"
      "Oracle_VM_VirtualBox_Extension_Pack"
    ];
  };

  nixpkgs.overlays = [
    (curr: prev: let
      nixpkgsUnstable = import inputs.nixpkgs-unstable {
        config = config.nixpkgs.config;
        system = curr.system;
      };
    in
      (lib.genAttrs
        [
          "alejandra"
          "comma"
          "cura"
          "jetbrains"
          "ledger-live-desktop"
          "nix-direnv"
          "nix-tree"
          "steam"
          "tdesktop"
          "znapzend"
          "vscode-extensions"
          "ferdium"
        ]
        (pname: nixpkgsUnstable."${pname}")))
  ];
}
