# Shared by the `spaces`, `infra-space` and `infra-space-agent-tools` VM
# tests (./test.nix, ../infra-space/test.nix,
# ../infra-space/agent-tools-test.nix, which uses only hostModule): a test
# host whose containers run in their own user namespaces (./host.nix,
# privateUsers) and still build through its
# nix-daemon, and the checks that they are untrusted clients of it.
#
# nspawn idmaps /nix/store (and the db, socket, profiles, gcroots) into
# such a container. The test driver's default store, an overlay on the
# host's virtiofs share, cannot be idmapped (overlayfs has no
# FS_ALLOW_IDMAP), and the read-only erofs image the slot tests use
# cannot be built into. So these hosts boot from a disk image whose ext4
# root holds the store, as som's and amy's zfs does.
{ pkgs }:
let
  inherit (pkgs) lib;
  cacheKey = ./test-keys/cache.sec;
  cachePub = lib.trim (builtins.readFile ./test-keys/cache.pub);
in
{
  hostModule = {
    virtualisation.useBootLoader = true;
    virtualisation.diskSize = 8192;
    boot.growPartition = true;
    virtualisation.fileSystems."/".autoResize = true;
    # the guests' builds and substitutions (a signed file cache below)
    nix.settings = {
      substituters = lib.mkForce [ "file:///var/lib/test-cache" ];
      trusted-public-keys = [ cachePub ];
      experimental-features = [ "nix-command" ];
    };
    environment.etc."test-cache.sec".source = cacheKey;
  };

  # check_untrusted(machine, container, user, busybox): from inside the
  # container, root and the user are both untrusted daemon clients, a
  # user's build works, a signed path is substituted, and an unsigned
  # import (injecting a store path) is refused, root's included.
  pythonHelpers = ''
    def check_untrusted(m, c, user, busybox):
        nix = "nix --extra-experimental-features nix-command"
        run = f"nixos-container run {c} -- "
        as_user = f"{run}runuser -u {user} -- "
        def drv(name, text):
            return shlex.quote(
                f'derivation {{ name = "{name}"; system = builtins.currentSystem; '
                f'builder = "''${{builtins.storePath "{busybox}"}}/bin/sh"; '
                f'args = [ "-c" "echo {text} > $out" ]; }}'
            )
        build = f"{nix} build --impure --no-link --print-out-paths --expr "

        for who in [run, as_user]:
            out = m.succeed(f"{who}{nix} store info --store daemon 2>&1")
            assert "Trusted: 0" in out, (c, who, out)

        # a build as the user
        out = m.succeed(f"{as_user}bash -lc " + shlex.quote(f"cd ~ && {build}{drv('untrusted-' + c, 'built')}")).strip()
        assert m.succeed(f"{as_user}cat {out}").strip() == "built", out

        # substitution: a path this host builds, signs into its file
        # cache and deletes; the guest's user realises it from the cache
        sub = m.succeed(build + drv("substituted-" + c, "cached")).strip()
        m.succeed(
            f"{nix} store sign -k /etc/test-cache.sec {sub}",
            f"{nix} copy --to file:///var/lib/test-cache {sub}",
            f"{nix} store delete {sub}",
        )
        m.fail(f"test -e {sub}")
        m.succeed(f"{as_user}nix-store -r {sub}")
        assert m.succeed(f"cat {sub}").strip() == "cached", sub

        # no injection: an unsigned export of a built path, imported by the
        # guest's root, is refused (it lacks a trusted signature)
        inj = m.succeed(build + drv("injected-" + c, "foreign")).strip()
        m.succeed(f"nix-store --export {inj} > /tmp/inject-{c}.nar", f"{nix} store delete {inj}")
        rc, out = m.execute(f"{run}env NIX_REMOTE=daemon nix-store --import < /tmp/inject-{c}.nar 2>&1")
        assert rc != 0 and "signature" in out, out
        m.fail(f"test -e {inj}")

        # the guest's uid 0 is no host root
        leader = m.succeed(f"machinectl show {c} -p Leader --value").strip()
        uid_map = m.succeed(f"cat /proc/{leader}/uid_map").split()
        assert uid_map[0] == "0" and uid_map[1] != "0" and uid_map[2] == "65536", (c, uid_map)

    # check_no_setuid(machine, container, user, host_home, guest_home):
    # the guest's root plants a setuid-root binary and one with a file
    # capability in the user's home (on disk: owner uid 0, the idmapped
    # bind), and makes the home world-readable. A host user reaches
    # neither (0700 root parents); handed the home anyway (a bind as
    # that user), and the guest's user in the guest, run them without
    # privileges (the home is nosuid). The guest's root cannot remount
    # the home suid. Needs a non-root host user `tenant`.
    def check_no_setuid(m, c, user, host_home, guest_home):
        run = f"nixos-container run {c} -- "
        idb = "${pkgs.coreutils}/bin/id"
        capsh = "${pkgs.libcap}/bin/capsh"
        m.succeed(
            f"{run}install -d -m 0755 {guest_home}/suid",
            # coreutils is one binary that runs as argv[0]'s name
            f"{run}install -m 4755 {idb} {guest_home}/suid/id",
            f"{run}install -m 0755 {capsh} {guest_home}/cap-capsh",
            f"{run}${pkgs.libcap}/bin/setcap cap_dac_override,cap_setuid+ep {guest_home}/cap-capsh",
            f"{run}chmod 0755 {guest_home}",
        )
        # the hole the locks close: here these are uid 0's
        assert m.succeed(f"stat -c '%u %a' {host_home}/suid/id").strip() == "0 4755"
        print(m.succeed(f"${pkgs.libcap}/bin/getcap {host_home}/cap-capsh"))
        # no host user reaches them
        m.fail(f"runuser -u tenant -- stat {host_home}/suid/id")
        m.fail(f"runuser -u tenant -- {host_home}/suid/id -u")
        assert m.succeed(f"stat -c %a {host_home.rsplit('/', 1)[0]}").strip() == "700"
        # nosuid,nodev here, and so in every bind of it (systemd-run checks
        # the command's path before its mounts: through a shell)
        opts = m.succeed(f"findmnt -n -o VFS-OPTIONS --mountpoint {host_home}").split(",")
        assert "nosuid" in opts and "nodev" in opts, opts
        out = m.succeed(
            f"systemd-run --uid=tenant -p BindReadOnlyPaths={host_home}:/run/probe --wait --pipe --quiet ${pkgs.bash}/bin/bash -c '/run/probe/suid/id -u'"
        ).strip()
        assert out == m.succeed("id -u tenant").strip(), out
        out = m.succeed(
            f"systemd-run --uid=tenant -p BindReadOnlyPaths={host_home}:/run/probe --wait --pipe --quiet ${pkgs.bash}/bin/bash -c '/run/probe/cap-capsh --print'"
        )
        assert "cap_setuid" not in out.split("Bounding")[0] and "cap_dac_override" not in out.split("Bounding")[0], out
        # in the guest too
        out = m.succeed(f"{run}runuser -u {user} -- {guest_home}/suid/id -u").strip()
        assert out == m.succeed(f"{run}id -u {user}").strip(), out
        out = m.succeed(f"{run}runuser -u {user} -- {guest_home}/cap-capsh --print")
        assert "cap_setuid" not in out.split("Bounding")[0], out
        # and its root cannot lift the flags: refused for the locked flags
        # (EPERM), not failing for some other reason
        rc, out = m.execute(f"{run}mount -o remount,bind,suid,dev {guest_home} 2>&1")
        assert rc != 0 and any(e in out.lower() for e in ("permission denied", "operation not permitted")), (rc, out)
        m.succeed(f"{run}rm -r {guest_home}/suid {guest_home}/cap-capsh", f"{run}chmod 0700 {guest_home}")
  '';
}
