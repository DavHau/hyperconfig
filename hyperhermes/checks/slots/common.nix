# What both slots tests share: test-only keys, the stub of core's agent
# registry, a responder for the slots' services, and the host settings a
# VM needs to run container slots at all.
{ pkgs }:
let
  inherit (pkgs) lib;

  # `nix-env -p <profile> --set <path>` as symlinks: <profile>-<n>-link to
  # the path, <profile> to the newest link (see slotHost's nix.package).
  profileSet = pkgs.writeShellScript "nix-env" ''
    if [ "$#" -ne 4 ] || [ "$1" != -p ] || [ "$3" != --set ]; then
      echo "nix-env stand-in: only -p <profile> --set <path>" >&2
      exit 1
    fi
    p=$2
    n=1
    while [ -e "$p-$n-link" ] || [ -L "$p-$n-link" ]; do n=$((n + 1)); done
    ${pkgs.coreutils}/bin/ln -s "$4" "$p-$n-link"
    ${pkgs.coreutils}/bin/ln -sfn "$(${pkgs.coreutils}/bin/basename "$p")-$n-link" "$p"
  '';
in
{
  # Test-only keys.
  sshKeys = {
    alice = {
      pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC48uSUhvbKLmlJkJ7/GN6oqJsnCfwS1I+G/4EN45Dpq alice@test";
      priv = ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACAuPLklIb2yi5pSZCe/xjeqKibJwn8EtSPhv+BDeOQ6agAAAJDYDATc2AwE
        3AAAAAtzc2gtZWQyNTUxOQAAACAuPLklIb2yi5pSZCe/xjeqKibJwn8EtSPhv+BDeOQ6ag
        AAAECoo8ej+H46tA9S9hBEfAzwYk87SiqBE5o6cg4062uGnC48uSUhvbKLmlJkJ7/GN6oq
        JsnCfwS1I+G/4EN45DpqAAAACmFsaWNlQHRlc3QBAgM=
        -----END OPENSSH PRIVATE KEY-----
      '';
    };
    bob = {
      pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJFXatIXf1FCzdfJMe5d58yYJ8adZmrmL6ls7AcqrIVF bob@test";
      priv = ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACCRV2rSF39RQs3XyTHuXefMmCfGnWZq5i+pbOwHKqyFRQAAAJDNhluazYZb
        mgAAAAtzc2gtZWQyNTUxOQAAACCRV2rSF39RQs3XyTHuXefMmCfGnWZq5i+pbOwHKqyFRQ
        AAAECjOpnJjIFCoi8WnQd31Kjs6MgkjMvmJWvJXG+8AYNfaJFXatIXf1FCzdfJMe5d58yY
        J8adZmrmL6ls7AcqrIVFAAAACGJvYkB0ZXN0AQIDBAU=
        -----END OPENSSH PRIVATE KEY-----
      '';
    };
  };
  adminKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM7ptVA/R16UvtWJD3VfJUWdEL2nzonoFRz2Na6lg+UU admin@test";

  # core's agent registry and collection points, as far as slots uses them:
  # the tests run no hermes.
  agentsStub =
    { lib, ... }:
    {
      options.services.hyperhermes = {
        agents = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options.uid = lib.mkOption { type = lib.types.int; };
              options.sshKeyFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
            }
          );
        };
        extraPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
        };
        skillDirs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
      };
    };

  # Answers one HTTP request with its tag, the peer it saw and the
  # X-Forwarded-For it got (socat sets SOCAT_PEERADDR).
  responder = pkgs.writeShellScript "responder" ''
    xff=""
    while IFS= read -r line; do
      line=''${line%$'\r'}
      [ -z "$line" ] && break
      case "$line" in [Xx]-[Ff]orwarded-[Ff]or:*) xff=''${line#*: } ;; esac
    done
    printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n%s peer=%s xff=%s\n' "$1" "$SOCAT_PEERADDR" "$xff"
  '';

  # A host that can run container slots in a test VM.
  slotHost = {
    networking.useNetworkd = true;
    networking.useDHCP = false;
    systemd.network.wait-online.enable = false;
    # nspawn idmaps /nix/store into a slot with its own user namespace;
    # neither the host's virtiofs share nor the writable overlay on it
    # allows that, a read-only store image (erofs) does (a real host: zfs,
    # ext4, ...).
    virtualisation.useNixStoreImage = true;
    virtualisation.writableStore = false;
    # nix cannot open that store at all (LocalStore creates
    # /nix/store/.links even in read-only mode), so the seed's
    # `nix-env -p <profile> --set <system>` gets a stand-in that writes
    # the same generation symlinks; on a real host the real one runs.
    nix.package = pkgs.symlinkJoin {
      inherit (pkgs.nix) pname version;
      passthru = pkgs.nix.passthru;
      paths = [ pkgs.nix ];
      postBuild = ''
        rm $out/bin/nix-env
        cp ${profileSet} $out/bin/nix-env
      '';
    };
    # nspawn binds the db into every slot; nothing here ever opens it.
    systemd.tmpfiles.rules = [ "d /nix/var/nix/db 0755 root root -" ];
  };

  # The test driver's MAC of a node on vlan 1 (the slots' uplink).
  uplinkMacOf =
    config:
    "52:54:00:12:01:${lib.fixedWidthString 2 "0" (lib.toHexString config.virtualisation.test.nodeNumber)}";
}
