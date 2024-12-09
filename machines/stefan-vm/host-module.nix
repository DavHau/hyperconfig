{lib, pkgs, self, ...}:
let
  machine = self.nixosConfigurations.stefan-vm;
  defaultDisk = import (pkgs.path + "/nixos/lib/make-disk-image.nix") {
    inherit lib;
    inherit (machine) config;
    inherit pkgs;
    diskSize = "50000";
    format = "qcow2";
  };
in
{
  # systemd.services.stefan-vm = {
  #   description = "Stefan's VM";
  #   wantedBy = [ "multi-user.target" ];
  #   after = [ "network-online.target" ];
  #   wants = [ "network-online.target" ];
  #   serviceConfig = {
  #     Type = "simple";
  #     Restart = "always";
  #     DynamicUser = true;
  #     StateDirectory = "stefan-vm";
  #   };
  #   path = [
  #     pkgs.qemu
  #   ];
  #   script = ''
  #     set -e
  #     cd $STATE_DIRECTORY
  #     diskFile=${defaultDisk}/nixos.*
  #     imgName="$(basename $diskFile)"
  #   ''
  #   + ''
  #     if [ ! -f "$imgName" ]; then
  #       cp "${defaultDisk}/$imgName" "$imgName"
  #       chmod +w "$imgName"
  #     fi
  #   ''
  #   + ''
  #     qemu-kvm \
  #       -nographic \
  #       -m 8192 \
  #       -smp 4 \
  #       -drive file="$imgName",if=virtio \
  #       -net nic,model=virtio \
  #       -net user,hostfwd=tcp::3333-:22
  #   '';
  # };
}
