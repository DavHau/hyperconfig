{ lib, ... }:
# systemd-oomd on the user slices, tuned to act within seconds.
#
# Without a monitored cgroup oomd is idle and a leaking process only dies
# to the kernel OOM killer once RAM *and* the RAM-sized zram are full —
# minutes of a frozen desktop while the kernel thrashes through zram.
# Here oomd kills the user cgroup whose memory pressure stays above 50%
# for 10s (upstream/NixOS defaults: 80% per slice, 30s).
#
# oomd kills whole cgroups: everything sharing the leaking process's scope
# (e.g. a terminal, or the herdr server and all of its panes) goes with it.
let
  limit = "50%";
in
{
  systemd.oomd = {
    enableUserSlices = true;
    settings.OOM.DefaultMemoryPressureDurationSec = "10s";
  };

  # enableUserSlices sets 80% with mkDefault on user.slice ...
  systemd.slices.user.sliceConfig.ManagedOOMMemoryPressureLimit = limit;
  # ... and hardcodes it in the user manager's slice drop-in.
  systemd.user.units."slice".text = lib.mkForce ''
    [Slice]
    ManagedOOMMemoryPressure=kill
    ManagedOOMMemoryPressureLimit=${limit}
  '';
}
