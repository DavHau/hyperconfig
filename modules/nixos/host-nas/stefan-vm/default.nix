{config, lib, pkgs, modulesPath, inputs, ...}:
let
  defaultDisk = import ./default-disk.nix {
    inherit lib;
    pkgs = import pkgs.path {
      system = "x86_64-linux";
      config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
        "zerotierone"
      ];
    };
  };
in
{
  systemd.services.stefan-vm = {
    description = "Stefan's VM";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      DynamicUser = true;
      StateDirectory = "stefan-vm";
    };
    path = [
      pkgs.qemu
    ];
    script = ''
      cd $STATE_DIRECTORY
      diskFile=${defaultDisk}/nixos.*
      imgName="$(basename $diskFile)"
      if [ ! -f "$imgName" ]; then
        cp "${defaultDisk}/$imgName" "$imgName"
        chmod +w "$imgName"
      fi;
      qemu-kvm \
        -nographic \
        -m 1024 \
        -drive file="$imgName",if=virtio \
        -net nic,model=virtio \
        -net user,hostfwd=tcp::3333-:22
    '';
  };
}
