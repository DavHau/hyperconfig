/*
  The agave-host space: Dave's self-hosted Agave (docs/agave-self-hosted.md,
  H5-H8), agave's server (`services.agave`, the flake input `agave`'s
  nixosModules.default) in a named space on som, at https://agave.davhau.com.
  Every fleet machine's tunnel dials it (../agave-tunnel.nix).

  Reached through som's SNI passthrough (hyperhermes' slots.sniBackends):
  the public IPv4's 443 for agave.davhau.com and *.agave.davhau.com (the
  apps' default addresses, appsDomain = host) passes through unterminated
  to the guest's 443, so Agave ends TLS itself (tunnelTls: the tunnels'
  ssh rides the same port with ALPN agave-tunnel), and port 80 goes to the
  guest's 80 for its own ACME HTTP-01. Not behindProxy: that would hold 443
  on a proxy, which tunnelTls refuses. The front connects as som's nginx
  from the host's veth address: `frontPorts` (./default.nix) lets nginx's
  uid into 80 and 443, the guest admits the host's address
  (./guest-base.nix). Agave sees som as every client's address. DNS: an A
  record for both names at the public IPv4 (porkbun-records), no AAAA: som's
  IPv6 443 is its own nginx, which has no route by name to the guest.

  Outbound through Mullvad (`hyper.mullvadEgress.sources`, ../mullvad-egress,
  its DNS too), except what som's nix-daemon fetches for the guest. Its
  upstreams are public names: TeamClaude (teamclaude.davhau.com) and
  Dave's PDS (pds.davhau.com) are som's own services, reached the public
  way (Mullvad, sgp's IPv4, back to som), since `confine` (./host.nix)
  refuses this host's services but DNS.

  The one space whose tenant is a fleet admin: Agave's tenant (t-infra)
  logs in as root on every fleet machine, som included (../agave-tunnel.nix,
  H10). Dave's decision; it deploys with `clan machines update`. The login
  user `agave-host` (Dave's keys, afk) never holds that key.

  Its own keys, each revocable alone, clan vars without prompts (`clan vars
  generate som`):
    space-agave-host-teamclaude  its TeamClaude client key
                           (hyper.teamclaudeGateway.clientKeys.agave-host,
                           which names the generator: no prefix is
                           load-bearing); credential `teamclaude-key`,
                           Agave's anthropic keyFile.
    agave-geninf-ro        shared, infra-space's (../infra-space/default.nix):
                           read-only on agave's repositories; credential
                           `agave-geninf-ro`, copied for the tenant
                           (t-infra) to /run/agave-host/tenant, ssh's key for
                           git.geninf.io: the tenant's evaluation of
                           hyperconfig fetches the private input `agave`.
    space-agave-host-github      GitHub deploy key of DavHau/hyperconfig,
                           with write access; system credential `github`.
                           Manual: Dave adds its public value on GitHub as
                           a deploy key.
    space-agave-host-tenant-ssh  the tenant's ssh identity, which root on
                           every fleet machine trusts (../agave-tunnel.nix,
                           through ../infra-space/fleet-access.nix); system
                           credential `tenant-ssh`.
  The first two are the login user's too, at
  /run/agave-host/secrets/<credential> (0400 agave-host). github and
  tenant-ssh are `systemCredentials` only: the guest's
  /run/credentials/@system/<credential>, root's, never the login user's.
  Agave's repo mode (below, commented out) hands them to its own units
  with LoadCredential (repository.keyFile, sshKeyFile); until then nothing
  reads them.
  The guest's ssh host key (space-agave-host-hostkey, ./instance.nix) is
  also the key every tunnel pins; Agave reads its public half at
  /etc/ssh/ssh_host_ed25519_key.pub, derived from the credential at each
  start.

  Agave's own users moved below the guest's 65536 ids (its own user
  namespace, ./host.nix privateUsers): t-infra/t-infra-tun 59000/59001,
  below systemd-homed's 60001-60513 and DynamicUser's 61184-65519, above
  nixbld's 30000s. The tunnel login
  t-infra-tun is the second user sshd lets in (guest-base's AllowUsers).

  Dave stays in control: no marketplace, no VM host (rented machines are
  off until the last step), no registry, no use reports, no installer
  image. Agave never deploys on its own.
*/
{
  config,
  lib,
  pkgs,
  inputs,
  options,
  ...
}:
let
  name = "agave-host";
  cfg = config.hyper.spaces.${name};
  vars = config.clan.core.vars.generators;
  containerUnit = "container@${name}.service";
  secretsDir = "/run/${name}/secrets";
  r = (import ./registry.nix).${name};
  guestV4 = "10.235.0.${toString (4 * r.index + 2)}";
  host = "agave.davhau.com";
  hostnames = [
    host
    "*.${host}"
  ];
  # derived from the host key credential by the guest's secrets unit
  hostKeyPub = "/run/${name}/ssh_host_ed25519_key.pub";
  # Agave's tenant's own copies of credentials it needs (0400 t-infra)
  tenantDir = "/run/${name}/tenant";
  # root's only (`systemCredentials`, ./default.nix)
  systemCredentialsDir = "/run/credentials/@system";

  sshKey = comment: {
    files.id_ed25519.restartUnits = [ containerUnit ];
    files."id_ed25519.pub".secret = false;
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -q -t ed25519 -N "" -C ${lib.escapeShellArg comment} -f "$out"/id_ed25519
    '';
  };
in
{
  config = lib.mkMerge [
    # Its own definitions not under its `enable` (that would recurse, as
    # ./geninf-space.nix says); inert while the space is off.
    {
      hyper.spaces.${name} = {
        credentials = {
          teamclaude-key = vars.space-agave-host-teamclaude.files.key.path;
          agave-geninf-ro = vars.agave-geninf-ro.files.id_ed25519.path;
        };
        # Agave's backend only, never the login user (the header)
        systemCredentials = {
          github = vars.space-agave-host-github.files.id_ed25519.path;
          tenant-ssh = vars.space-agave-host-tenant-ssh.files.id_ed25519.path;
        };
        # the SNI router's passthrough (below)
        frontPorts = [
          80
          443
        ];
        # nothing to publish: Agave answers on its own name
        publish.enable = false;
        guestModules = [
          inputs.agave.nixosModules.default
          (
            { pkgs, ... }:
            {
              services.agave = {
                enable = true;
                inherit host;
                tunnelTls = true;
                acme.email = "info@davhau.com";
                signup = "allowlist";
                admins = [ "did:web:dave.davhau.com" ];
                defaultPds = "https://pds.davhau.com";
                anthropic = {
                  upstream = "https://teamclaude.davhau.com";
                  keyFile = "${secretsDir}/teamclaude-key";
                  oauthToken = true;
                };
                vmHost = null;
                marketplace = null;
                registry = null;
                reportUses = false;
                installerIso = null;

                # Repo mode (agave PRs A2/A3/A5, branches repo-mode-*):
                # ~/fleet becomes a clone of hyperconfig's main, pushed to
                # with the deploy key. Enabled by uncommenting once the
                # input is re-locked to a branch with
                # `services.agave.repository`. Both keys are root's system
                # credentials; Agave's units take them with LoadCredential,
                # the agent's unit sees neither.
                #
                # repository = {
                #   url = "git@github.com:DavHau/hyperconfig.git";
                #   branch = "main";
                #   keyFile = "${systemCredentialsDir}/github";
                #   knownHosts = lib.concatMapStrings (k: "github.com ${k}\n") (
                #     import ../../github-host-keys.nix
                #   );
                #   sshKeyFile = "${systemCredentialsDir}/tenant-ssh";
                # };
              };

              # Below the guest's 65536 ids (the header).
              users.users.t-infra.uid = lib.mkForce 59000;
              users.users.t-infra-tun.uid = lib.mkForce 59001;
              users.groups.t-infra.gid = lib.mkForce 59000;

              # The computers' tunnels log in as t-infra-tun, through an
              # always-running sshd, as on agave's own instances (not
              # socket-activated: one daemon for every tunnel and probe).
              services.openssh.settings.AllowUsers = [ "t-infra-tun" ];
              services.openssh.startWhenNeeded = false;

              # The host key's public half where Agave reads it, from the
              # credential sshd serves (./guest-base.nix); the units that
              # read it or the TeamClaude key wait for the credentials.
              environment.etc."ssh/ssh_host_ed25519_key.pub".source = hostKeyPub;
              systemd.services =
                lib.genAttrs
                  [
                    "agave"
                    "agave-setup"
                    "agave-llm-anthropic"
                  ]
                  (_: {
                    requires = [ "${name}-secrets.service" ];
                    after = [ "${name}-secrets.service" ];
                  })
                // {
                  "${name}-secrets".serviceConfig.ExecStartPost = toString (
                    pkgs.writeShellScript "${name}-host-key-pub" ''
                      set -eu
                      ${pkgs.openssh}/bin/ssh-keygen -y -f /run/${name}/ssh_host_ed25519_key > ${hostKeyPub}.tmp
                      chmod 0644 ${hostKeyPub}.tmp
                      mv ${hostKeyPub}.tmp ${hostKeyPub}
                      # the tenant's copy of the read-only agave key (below)
                      install -d -m 0500 -o t-infra -g t-infra ${tenantDir}
                      install -m 0400 -o t-infra -g t-infra ${secretsDir}/agave-geninf-ro ${tenantDir}/agave-geninf-ro
                    ''
                  );
                };

              # The tenant evaluates hyperconfig, whose input `agave` is
              # private: git.geninf.io with the read-only key, pinned host
              # key (../infra-space/guest.nix does the same for infra).
              programs.ssh.knownHosts = { inherit (import ./forge-host-keys.nix) git-geninf-io; };
              programs.ssh.extraConfig = ''
                Host git.geninf.io
                  User gitea
                  IdentityFile ${tenantDir}/agave-geninf-ro
                  IdentitiesOnly yes
              '';
            }
          )
        ];
      };
    }

    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          clan.core.vars.generators = {
            space-agave-host-github = sshKey "agave-host@DavHau/hyperconfig";
            space-agave-host-tenant-ssh = sshKey "agave-host tenant (root on the fleet)";
            # The `sk-ant-oat01-` prefix is load-bearing, as for every
            # gateway key (../provider-keys.nix): Agave presents as Claude
            # Code (oauthToken) only with a key that looks like a
            # subscription token.
            space-agave-host-teamclaude = {
              files.key.restartUnits = [ containerUnit ];
              runtimeInputs = [ pkgs.openssl ];
              script = ''
                printf 'sk-ant-oat01-%s' "$(openssl rand -hex 32)" > "$out/key"
              '';
            };
            agave-geninf-ro.files.id_ed25519.restartUnits = [ containerUnit ];
          };
        }

        # som's front, egress, gateway client and DNS (options of som's
        # modules only)
        (lib.optionalAttrs (options ? services.hyperhermes.slots.sniBackends) {
          services.hyperhermes.slots.sniBackends.${name} = {
            inherit hostnames;
            https = "${guestV4}:443";
            http = "http://${guestV4}:80";
          };
        })
        (lib.optionalAttrs (options ? hyper.mullvadEgress.sources) {
          hyper.mullvadEgress.sources = [ "ve-${name}" ];
        })
        (lib.optionalAttrs (options ? hyper.teamclaudeGateway.clientKeys) {
          hyper.teamclaudeGateway.clientKeys.${name} = "space-agave-host-teamclaude";
        })
        (lib.optionalAttrs (options ? hyper.porkbunRecords.records) {
          hyper.porkbunRecords.records = lib.genAttrs hostnames (_: {
            A = config.services.hyperhermes.exposure.publicIPv4;
          });
        })
      ]
    ))
  ];
}
