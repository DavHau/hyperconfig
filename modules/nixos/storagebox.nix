# The Hetzner storage box (sub-account u632961-sub1) mounted read-only over
# sshfs at /mnt/storagebox — the shared depth archive that moneymaker's beast
# ships onto the box (its /mnt/storagebox/depth; moneymaker
# nix/modules/storagebox.nix is the writer side). These hosts only READ the
# archive; nobody local may write to the box, so the mount itself is
# read-only.
#
# Auth is the sub-account's SFTP password as a SHARED clan var (one password
# for the whole clan — same account from every host, one prompt, entered
# once):
#     clan vars generate <any-host> --generator storagebox
# sshfs reads the decrypted secret on stdin (password_stdin), so the password
# never appears in the unit file or process list.
#
# NOTE on throughput: parallel connections (-o max_conns=N) are NOT usable
# while this is password auth — sshfs exits with "password_stdin option
# cannot be specified with parallel connections" (sshfs.c:4439). Going
# parallel means switching this generator to an ed25519 keypair and
# installing the public half in the sub-account's authorized_keys.
#
# Throughput: measured on amy 2026-08-16, plain SFTP to this box sustained
# 6.3-7.7 MB/s while this mount managed 1.16 MB/s on the same file in the
# same minute. The mount was the bottleneck, not the link, and not the
# number of connections (8 parallel streams measured no better than 1).
# sshfs asks for at most 64 KB per read (sshfs.c:4489, default 32 KB) and
# keeps one chunk of readahead, so at ~200 ms RTT the in-flight bytes are
# what caps it. Hence max_read at the ceiling below, plus a much larger
# kernel readahead window applied once the mount exists.
{ config, pkgs, ... }:
let
  mountpoint = "/mnt/storagebox";
  # In-flight bytes = max_background x max_read, and throughput = that / RTT.
  # 64 requests x 64 KB = 4 MiB in flight; at 0.2 s that ceilings around
  # 20 MB/s, comfortably above the ~7 MB/s the path actually delivers. The
  # readahead window is sized to match: a larger window cannot help while
  # max_background throttles the requests, and vice versa.
  readAheadKb = 4096;
  maxBackground = 64;
  setReadahead = pkgs.writeShellApplication {
    name = "storagebox-readahead";
    runtimeInputs = [ pkgs.gawk pkgs.coreutils ];
    text = builtins.readFile ./storagebox-readahead.sh;
  };
  stopMount = pkgs.writeShellApplication {
    name = "storagebox-stop";
    runtimeInputs = [
      pkgs.gawk
      pkgs.coreutils
      pkgs.fuse3
    ];
    text = builtins.readFile ./storagebox-stop.sh;
  };
in
{
  clan.core.vars.generators.storagebox = {
    share = true;
    # A persisted prompt IS the file — no generator script, so the var holds
    # exactly the password and nothing else.
    prompts.password = {
      type = "hidden";
      persist = true;
      description = "SFTP password of the u632961-sub1 Hetzner storage-box sub-account (shared)";
    };
    files.password.neededFor = "services";
  };

  # Pin the box's host key (fetched via ssh-keyscan from beast, 2026-07-15) so
  # the first mount is not trust-on-first-use. The box speaks mod_sftp and
  # offers only an RSA host key — no ed25519 to pin instead.
  programs.ssh.knownHosts."u632961-sub1.your-storagebox.de".publicKey =
    "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA5EB5p/5Hp3hGW1oHok+PIOH9Pbn7cnUiGmUEBrCVjnAw+HrKyN8bYVV0dIGllswYXwkG/+bgiBlE6IVIBAq+JwVWu1Sss3KarHY3OvFJUXZoZyRRg/Gc/+LRCE7lyKpwWQ70dbelGRyyJFH36eNv6ySXoUYtGkwlU5IVaHPApOxe4LHPZa/qhSRbPo2hwoh0orCtgejRebNtW5nlx00DNFgsvn8Svz2cIYLxsPVzKgUxs8Zxsxgn+Q/UvR7uq4AbAhyBMLxv7DjJ1pc7PJocuTno2Rw9uMZi1gkjbnmiOh6TTXIEWbnroyIhwc8555uto9melEUmWNQ+C+PwAK+MPw==";

  systemd.tmpfiles.rules = [ "d ${mountpoint} 0755 root root -" ];

  # Every local user must be able to read through the mount. Without this the
  # kernel rejects allow_other, so sshfs falls back to mount-only access
  # (root could read, grmpf got EACCES) — the FUSE cap has to be on before
  # the service starts.
  boot.extraModprobeConfig = "options fuse user_allow_other=y";

  systemd.services.storagebox-mount = {
    description = "read-only sshfs mount of the Hetzner storage box at ${mountpoint}";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.sshfs
      pkgs.coreutils
      pkgs.openssh
    ];
    # -f keeps sshfs in the foreground so systemd supervises it; stopping the
    # unit terminates sshfs, which unmounts. reconnect + ServerAlive ride out
    # network blips.
    #
    # Read-only, by mount: -o ro makes every local user read-only at the
    # filesystem layer — no uid/gid remapping (files keep the sub-account's
    # ownership). allow_other is what grants the other users access in the
    # first place: a FUSE mount is visible only to the mounting user (root)
    # unless it is set, and with it on, default_permissions keeps the check at
    # plain POSIX — 0755 mountpoint + ro = world read, nobody writes.
    #
    # max_read is pinned to sshfs's own ceiling (it silently clamps anything
    # above 65536, sshfs.c:4489); the default is 32768, so this halves the
    # number of round trips per megabyte on a link where round trips are the
    # whole cost.
    script = ''
      exec sshfs -f \
        -o password_stdin,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 \
        -o allow_other,default_permissions \
        -o ro \
        -o max_read=65536 \
        u632961-sub1@u632961-sub1.your-storagebox.de: ${mountpoint}
    '';
    serviceConfig = {
      StandardInput = "file:${config.clan.core.vars.generators.storagebox.files.password.path}";
      Restart = "on-failure";
      RestartSec = 10;
      # Non-fatal (leading "-"): a mount that is merely slow beats a unit
      # that restart-loops because a sysfs knob moved.
      ExecStartPost = "-${setReadahead}/bin/storagebox-readahead ${mountpoint} ${toString readAheadKb} ${toString maxBackground}";
      # Stopping used to stall a switch for the full 90 s default timeout:
      # sshfs cannot finish unmounting while FUSE requests are in flight, so
      # systemd waited, then SIGKILLed. ExecStop detaches the tree lazily and
      # aborts the connection first, which makes sshfs exit at once.
      ExecStop = "-${stopMount}/bin/storagebox-stop ${mountpoint}";
      TimeoutStopSec = 20;
      # A crash can leave a stale fuse mountpoint behind ("transport endpoint
      # is not connected"); lazy-unmount it so the restarted sshfs can mount.
      ExecStopPost = "-${pkgs.fuse3}/bin/fusermount3 -uz ${mountpoint}";
    };
  };
}
