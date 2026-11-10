# nas' encrypted-dataset guard (./enc-guard.nix) on a small ZFS pool, with
# a tang server of its own and a JWE made by nas' own binding script
# (./tang-bind.nix), offline, against the pinned advertisement:
#   - boot with tang up: both roots unlock, the guarded services start;
#   - restarting automount with the keys loaded is a no-op, even without tang;
#   - boot with tang down: automount fails loudly, no guarded service runs,
#     the borg forced command refuses, nothing can be created under the
#     bare mountpoints (immutable), no home is created there; once tang is
#     back, automount retries by itself and brings the services up;
#   - the manual fallback (zfs load-key by hand, restart automount);
#   - the dry-run enc-unlock-selftest: passes with tang up, fails with
#     tang down or a JWE of another passphrase, changes nothing;
#   - files under a bare mountpoint fail enc-underlay-guard.
{ pkgs }:
let
  lib = pkgs.lib;
  passphrase = "enc-guard-test-passphrase";
  sshKeys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;

  # A tang server's keys, and the advertisement it serves for them (as
  # modules/nixos/esphome-secrets.nix makes them for the plug).
  tangKeys = pkgs.runCommand "tang-test-keys" { nativeBuildInputs = [ pkgs.jose ]; } ''
    mkdir $out
    jose jwk gen -i '{"alg":"ECMR"}' -o $out/exc.jwk
    jose jwk gen -i '{"alg":"ES512"}' -o $out/sig.jwk
  '';
  advFile = pkgs.runCommand "tang-test-adv" { } ''
    printf 'GET /adv HTTP/1.1\r\n\r\n' | ${pkgs.tang}/libexec/tangd ${tangKeys} |
      ${pkgs.gnused}/bin/sed '1,/^\r$/d' > $out
  '';

  # nas' generator script, run as clan would (minus bwrap): $in holds the
  # dependency's files, $out receives the JWE. No network in the sandbox.
  bind = import ./tang-bind.nix {
    inherit pkgs advFile;
    url = "http://tang:7654";
  };
  mkJwe =
    name: pass:
    pkgs.runCommand name { nativeBuildInputs = bind.runtimeInputs; } ''
      result=$out
      export in=$PWD/in out=$PWD/out
      mkdir -p $in/zfs-passphrase $out
      printf %s ${pass} > $in/zfs-passphrase/passphrase
      (${bind.script}) < /dev/null
      cp $out/jwe $result
    '';
  jwe = mkJwe "enc-guard-test-jwe" passphrase;
  # Bound to tang fine, but not the roots' passphrase (a passphrase
  # changed without re-binding).
  wrongJwe = mkJwe "enc-guard-test-wrong-jwe" "not-the-passphrase";
in
pkgs.testers.runNixOSTest {
  name = "nas-enc-guard";

  nodes.tang = {
    services.tang = {
      enable = true;
      ipAddressAllow = [ "192.168.1.0/24" ];
    };
    systemd.services."tangd@".serviceConfig.ExecStart =
      lib.mkForce "${pkgs.tang}/libexec/tangd ${tangKeys}";
    networking.firewall.allowedTCPPorts = [ 7654 ];
  };

  nodes.nas = { config, ... }: {
    imports = [ ./enc-guard.nix ];
    virtualisation.memorySize = 2048;
    virtualisation.emptyDiskImages = [ 1024 ];
    boot.supportedFilesystems = [ "zfs" ];
    networking.hostId = "5e0c3a71";
    boot.zfs.extraPools = [ "tank" ];
    boot.zfs.devNodes = "/dev";
    boot.zfs.requestEncryptionCredentials = false;

    environment.etc."enc-test.jwe" = {
      source = jwe;
      mode = "0400";
    };

    encGuard = {
      roots = [
        "tank/enc"
        "tank/enc2"
      ];
      mounts = {
        "/tank/enc" = "tank/enc";
        "/tank/enc/data" = "tank/enc/data";
        "/tank/enc2" = "tank/enc2";
      };
      jweFile = "/etc/enc-test.jwe";
      docs = "test.nix";
      unlock = {
        attempts = 2;
        maxDelay = 1;
        restartSec = 15;
      };
      services.writer = [ "/tank/enc/data" ];
    };

    # Stands in for filebrowser & co.
    systemd.services.writer = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Restart = "always";
      serviceConfig.RestartSec = 1;
      script = ''
        echo "$(date) written" >> /tank/enc/data/writer.log
        exec sleep infinity
      '';
    };

    services.openssh.enable = true;
    services.borgbackup.repos.client = {
      path = "/tank/enc/backup/client";
      authorizedKeys = [ sshKeys.snakeOilPublicKey ];
    };
    environment.etc."borg-client-key" = {
      source = sshKeys.snakeOilPrivateKey;
      mode = "0400";
    };
    environment.etc."enc-test-wrong.jwe".source = wrongJwe;
    environment.systemPackages = [ pkgs.borgbackup pkgs.e2fsprogs ];

    users.users.testuser = {
      isNormalUser = true;
      home = "/tank/enc/data/home/testuser";
      createHome = false;
    };

    # The pool, made once before its first import, keys unloaded after.
    systemd.services.make-tank = {
      requiredBy = [ "zfs-import-tank.service" ];
      before = [ "zfs-import-tank.service" ];
      requires = [ "dev-vdb.device" ];
      after = [ "dev-vdb.device" ];
      unitConfig.DefaultDependencies = false;
      unitConfig.ConditionPathExists = "!/var/lib/tank-made";
      serviceConfig.Type = "oneshot";
      path = [ config.boot.zfs.package ];
      script = ''
        zpool create -O mountpoint=/tank tank /dev/vdb
        for r in enc enc2; do
          printf '%s\n' ${passphrase} | zfs create -o encryption=on \
            -o keyformat=passphrase -o keylocation=prompt tank/$r
        done
        zfs create tank/enc/data
        mkdir -p /tank/enc/data/home/testuser /tank/enc/backup
        chown testuser /tank/enc/data/home/testuser
        zpool export tank
        mkdir -p /var/lib && touch /var/lib/tank-made
      '';
    };
  };

  testScript = ''
    borg = ("BORG_PASSPHRASE=x BORG_RSH='ssh -i /etc/borg-client-key "
            "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' borg")
    # The parent dataset alone, as the guard sees it.
    def underlay(cmd):
        return nas.succeed(
            "mkdir -p /mnt/u && mount --bind /tank /mnt/u && "
            f"({cmd}); rc=$?; umount /mnt/u; exit $rc"
        )

    # nixpkgs' borg repo service is a oneshot without RemainAfterExit.
    def repo_service_ran():
        nas.wait_until_succeeds(
            "systemctl show -P Result borgbackup-repo-client.service | grep -qx success"
            " && test -d /tank/enc/backup/client"
        )

    def lock():
        nas.succeed("systemctl stop writer automount")
        nas.succeed("zfs unmount tank/enc/data && zfs unmount tank/enc && zfs unmount tank/enc2")
        nas.succeed("zfs unload-key tank/enc && zfs unload-key tank/enc2")

    tang.start()
    tang.wait_for_unit("sockets.target")

    with subtest("tang up: both roots unlock at boot, guarded services start"):
        nas.start()
        nas.wait_for_unit("automount.service")
        for ds in ["tank/enc", "tank/enc/data", "tank/enc2"]:
            assert nas.succeed(f"zfs get -H -o value mounted {ds}").strip() == "yes", ds
        nas.wait_for_unit("writer.service")
        repo_service_ran()
        nas.wait_for_unit("sshd.service")
        nas.succeed("test -s /tank/enc/data/writer.log")
        nas.succeed("systemctl is-active enc-underlay-guard.service")
        nas.succeed(f"{borg} init -e repokey borg@localhost:.")
        nas.succeed(f"{borg} list borg@localhost:.")

    with subtest("enc-unlock-selftest: dry run, passes only while tang unlocks"):
        nas.succeed("systemctl list-timers enc-unlock-selftest.timer | grep -q enc-unlock-selftest")
        nas.succeed("systemctl start enc-unlock-selftest.service")
        out = nas.succeed("journalctl -b -u enc-unlock-selftest.service")
        assert "tank/enc: passphrase from tang is correct" in out, out
        assert "tank/enc2: passphrase from tang is correct" in out, out
        # A JWE of another passphrase: decrypts, but ZFS rejects it.
        nas.succeed("mount --bind /etc/enc-test-wrong.jwe $(readlink -f /etc/enc-test.jwe)")
        nas.fail("systemctl start enc-unlock-selftest.service")
        nas.succeed("umount $(readlink -f /etc/enc-test.jwe)")
        out = nas.succeed("journalctl -b -u enc-unlock-selftest.service")
        assert "does not unlock it" in out, out
        # tang down.
        tang.succeed("systemctl stop tangd.socket")
        nas.fail("systemctl start enc-unlock-selftest.service")
        out = nas.succeed("journalctl -b -u enc-unlock-selftest.service -n 5")
        assert "could not decrypt" in out, out
        tang.succeed("systemctl start tangd.socket")
        # Nothing changed: keys loaded, everything mounted, writer running.
        out = nas.succeed("zfs get -H -o value keystatus tank/enc tank/enc2 | sort -u")
        assert out.strip() == "available", out
        nas.succeed("findmnt /tank/enc/data && systemctl is-active writer.service automount.service")

    with subtest("restarting automount with keys loaded is a no-op, tang not needed"):
        tang.succeed("systemctl stop tangd.socket")
        nas.succeed("systemctl restart automount.service")
        out = nas.succeed("journalctl -b -u automount.service -n 10")
        assert "key already loaded" in out, out
        nas.succeed("systemctl is-active writer.service")
        tang.succeed("systemctl start tangd.socket")

    with subtest("tang down at boot: everything stays off, loudly"):
        tang.succeed("systemctl stop tangd.socket")
        nas.shutdown()
        nas.start()
        nas.wait_for_unit("multi-user.target")
        nas.wait_until_succeeds("journalctl -b -u automount.service | grep -q 'could not decrypt'")
        nas.fail("systemctl is-active automount.service")
        assert nas.succeed("zfs get -H -o value keystatus tank/enc").strip() == "unavailable"
        nas.wait_until_succeeds("systemctl is-failed writer.service")
        nas.succeed("journalctl -b -u writer.service | grep -q 'enc-guard: /tank/enc is not mounted'")
        nas.wait_until_succeeds("systemctl show -P Result borgbackup-repo-client.service | grep -qx exit-code")
        nas.wait_for_unit("sshd.service")
        nas.succeed("test ! -e /tank/enc/data/writer.log")
        nas.succeed("test ! -e /tank/enc/backup")
        nas.succeed("test ! -e /tank/enc/data/home/testuser")
        out = nas.fail(f"{borg} init -e repokey borg@localhost:. 2>&1")
        assert "enc-guard" in out, out
        nas.succeed("test ! -e /tank/enc/backup")
        # Root cannot create anything there either.
        nas.fail("mkdir /tank/enc/backup")
        nas.fail("touch /tank/enc/f /tank/enc2/f")
        nas.succeed("lsattr -d /tank/enc | grep -q -- '-i-'")
        assert nas.succeed("find /tank/enc /tank/enc2 -mindepth 1 | wc -l").strip() == "0"

    with subtest("tang back: automount retries by itself, services follow"):
        tang.succeed("systemctl start tangd.socket")
        nas.wait_for_unit("automount.service", timeout=120)
        nas.wait_for_unit("writer.service")
        repo_service_ran()
        nas.succeed(f"{borg} list borg@localhost:.")

    with subtest("manual fallback: load-key by hand, then restart automount"):
        lock()
        tang.succeed("systemctl stop tangd.socket")
        nas.succeed("printf '%s\\n' ${passphrase} | zfs load-key tank/enc")
        nas.succeed("printf '%s\\n' ${passphrase} | zfs load-key tank/enc2")
        nas.succeed("systemctl restart automount.service")
        nas.wait_for_unit("writer.service")
        nas.succeed("findmnt /tank/enc/data")

    with subtest("files under a bare mountpoint fail enc-underlay-guard"):
        lock()
        underlay("chattr -i /mnt/u/enc && touch /mnt/u/enc/leftover")
        nas.fail("systemctl restart enc-underlay-guard.service")
        out = nas.succeed("journalctl -u enc-underlay-guard.service -n 20")
        assert "leftover" in out, out
        nas.succeed("lsattr -d /tank/enc | grep -q -- '-i-'")
  '';
}
