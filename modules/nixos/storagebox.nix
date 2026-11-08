# The Hetzner storage box (sub-account u632961-sub1) mounted read-only over
# sshfs at /mnt/storagebox — the shared depth archive that moneymaker's beast
# ships onto the box (its /mnt/storagebox/depth; moneymaker
# nix/modules/storagebox.nix is the writer side). Only bam mounts it (via
# storagebox-sync.nix); it only READS the archive, so the mount is
# read-only.
#
# Never hang the host on it. vit once wedged PID1: a deploy stopped
# NetworkManager, the always-on sshfs mount hung, and the next daemon-reload
# never finished. So the mount is lazy and every wait on it is bounded:
#   - automount: nothing is mounted until something touches the path, and
#     it is unmounted again after idleTimeout. Only the .automount unit is
#     wanted (by remote-fs.target, Wants not Requires = nofail); nothing
#     orders local-fs.target, multi-user.target or a switch after the mount.
#   - plain systemd units, not fileSystems: no fstab line, so the fstab
#     generator (the code that ran during the wedge) never sees it. systemd
#     still treats fuse.sshfs as a network fs (_netdev): After
#     network-online.target, Before remote-fs.target, stopped before the
#     network on shutdown.
#   - mountTimeout bounds a mount attempt, ConnectTimeout the TCP/ssh
#     handshake, so an access while the box is unreachable fails (EHOSTDOWN
#     / ENODEV from the automount) instead of blocking.
#   - ServerAliveInterval x ServerAliveCountMax: a link that dies under a
#     live mount kills ssh within ~30 s; sshfs then fails the pending
#     requests (EIO) and reconnects on the next access.
#   - fs.fuse.default_request_timeout: the kernel's own backstop (Linux
#     >= 6.14). If sshfs itself stops answering, the kernel aborts the
#     connection after that long, so no reader stays in D state.
#   - stop = lazy + forced unmount (umount -l -f): detaches the tree and
#     aborts the FUSE connection, so stopping never waits on in-flight
#     requests (what storagebox-stop.sh used to do for the old service).
#
# Auth is the sub-account's SFTP password as a SHARED clan var (one password
# for the whole clan — same account from every host, one prompt, entered
# once):
#     clan vars generate <any-host> --generator storagebox
# sshfs reads the decrypted secret through sshpass (ssh_command wrapper), so
# the password never appears in the unit file or process list — and a
# reconnect can authenticate again, which password_stdin could not.
#
# NOTE on throughput: parallel connections (-o max_conns=N) used to be
# blocked by password_stdin ("cannot be specified with parallel
# connections", sshfs.c:4439). sshpass lifts that, but it buys nothing on
# this route (see below), and each connection costs one of the account's
# ten concurrent slots.
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
  host = "u632961-sub1.your-storagebox.de";
  idleTimeout = "10min";
  mountTimeout = "30s";
  connectTimeoutSec = 10;
  # sshfs's ceiling; see the max_read note on the options below.
  maxRead = 65536;
  # In-flight bytes = max_background x max_read, and throughput = that / RTT.
  # 64 requests x 64 KB = 4 MiB in flight; at 0.2 s that ceilings around
  # 20 MB/s, comfortably above the ~7 MB/s the path actually delivers. The
  # readahead window is sized to match: a larger window cannot help while
  # max_background throttles the requests, and vice versa.
  readAheadKb = 4096;
  maxBackground = 64;
  # Seconds a single FUSE request may stay unanswered before the kernel
  # aborts the connection. Well above the worst legitimate wait: a dead link
  # is noticed by ServerAlive in ~30 s plus one ConnectTimeout reconnect.
  fuseRequestTimeoutSec = 120;
  setReadahead = pkgs.writeShellApplication {
    name = "storagebox-readahead";
    runtimeInputs = [ pkgs.gawk pkgs.coreutils ];
    text = builtins.readFile ./storagebox-readahead.sh;
  };
  # sshfs runs this instead of ssh. sshpass gives ssh a pty to answer the
  # password prompt from the clan var on every (re)connect.
  sshCommand = pkgs.writeShellApplication {
    name = "storagebox-ssh";
    runtimeInputs = [ pkgs.sshpass pkgs.openssh ];
    text = ''
      exec sshpass -f ${config.clan.core.vars.generators.storagebox.files.password.path} ssh "$@"
    '';
  };
  mountUnit = "mnt-storagebox.mount";
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
  programs.ssh.knownHosts.${host}.publicKey =
    "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA5EB5p/5Hp3hGW1oHok+PIOH9Pbn7cnUiGmUEBrCVjnAw+HrKyN8bYVV0dIGllswYXwkG/+bgiBlE6IVIBAq+JwVWu1Sss3KarHY3OvFJUXZoZyRRg/Gc/+LRCE7lyKpwWQ70dbelGRyyJFH36eNv6ySXoUYtGkwlU5IVaHPApOxe4LHPZa/qhSRbPo2hwoh0orCtgejRebNtW5nlx00DNFgsvn8Svz2cIYLxsPVzKgUxs8Zxsxgn+Q/UvR7uq4AbAhyBMLxv7DjJ1pc7PJocuTno2Rw9uMZi1gkjbnmiOh6TTXIEWbnroyIhwc8555uto9melEUmWNQ+C+PwAK+MPw==";

  # mount -t fuse.sshfs execs mount.fuse.sshfs from /run/current-system/sw/bin.
  system.fsPackages = [ pkgs.sshfs ];

  # The request-timeout sysctls only exist once fuse is loaded, and
  # systemd-sysctl runs after systemd-modules-load, so load it at boot.
  boot.kernelModules = [ "fuse" ];
  boot.kernel.sysctl."fs.fuse.default_request_timeout" = fuseRequestTimeoutSec;

  systemd.automounts = [
    {
      where = mountpoint;
      wantedBy = [ "remote-fs.target" ];
      automountConfig.TimeoutIdleSec = idleTimeout;
    }
  ];

  # ControlMaster=no: ssh.nix turns on multiplexing fleet-wide with
  # ControlPath ~/.ssh/control/%C. If root has no such directory, the ssh
  # under sshfs fails ("unix_listener: cannot bind" and then "read:
  # Connection reset by peer"). A mount needs its own connection anyway.
  # It must not be a mux master that interactive root ssh piggybacks on.
  #
  # Read-only, by mount: ro makes every local user read-only at the
  # filesystem layer — no uid/gid remapping (files keep the sub-account's
  # ownership). allow_other is what grants the other users access in the
  # first place: a FUSE mount is visible only to the mounting user (root)
  # unless it is set, and with it on, default_permissions keeps the check at
  # plain POSIX — world-readable box root + ro = world read, nobody writes.
  # root mounts it, so allow_other needs no user_allow_other (fuse.conf);
  # the old "options fuse user_allow_other=y" modprobe line was ignored by
  # the kernel ("unknown parameter") and is gone.
  #
  # max_read is pinned to sshfs's own ceiling (it silently clamps anything
  # above 65536, sshfs.c:4489); the default is 32768, so this halves the
  # number of round trips per megabyte on a link where round trips are the
  # whole cost.
  systemd.mounts = [
    {
      description = "read-only sshfs mount of the Hetzner storage box at ${mountpoint}";
      what = "u632961-sub1@${host}:";
      where = mountpoint;
      type = "fuse.sshfs";
      options = builtins.concatStringsSep "," [
        "ro"
        "allow_other"
        "default_permissions"
        "max_read=${toString maxRead}"
        "reconnect"
        "ssh_command=${sshCommand}/bin/storagebox-ssh"
        "ConnectTimeout=${toString connectTimeoutSec}"
        "ServerAliveInterval=10"
        "ServerAliveCountMax=3"
        "ControlMaster=no"
        "StrictHostKeyChecking=yes"
        "NumberOfPasswordPrompts=1"
      ];
      mountConfig = {
        TimeoutSec = mountTimeout;
        LazyUnmount = true;
        ForceUnmount = true;
      };
    }
  ];

  # Kernel readahead and FUSE queue depth for a high-latency link, applied
  # each time the automount mounts. Wanted by the mount, PartOf it (not
  # BindsTo/Requires): it never pulls the mount in on its own, so a switch
  # that restarts it cannot trigger a mount attempt. Failure only leaves the
  # mount untuned.
  systemd.services.storagebox-readahead = {
    description = "tune readahead of ${mountpoint}";
    wantedBy = [ mountUnit ];
    after = [ mountUnit ];
    partOf = [ mountUnit ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${setReadahead}/bin/storagebox-readahead ${mountpoint} ${toString readAheadKb} ${toString maxBackground}";
      TimeoutStartSec = 30;
    };
  };
}
