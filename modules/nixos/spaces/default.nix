/*
  Named agent spaces: NixOS containers like infra-space (../infra-space),
  each for one job, none of them a fleet admin. hyper.spaces.<name> on the
  machine ./registry.nix assigns it to produces container <name>, its
  user <name>, its home /var/lib/spaces/<name>/home here.

  The same host side as infra-space (./host.nix: private veth, NAT,
  DNS from this host's resolved, sshd at [<this host's mesh
  address>]:<sshPort> through a socket proxy, nothing but this host into
  the guest and on this host only root and the proxy, the home persisted
  here, credentials as systemd credentials), and the same guest base
  (./guest.nix on ./guest-base.nix: fish, jj, git, nix, tmux, afk, herdr).
  Dave's admin keys log in.

  What a space does NOT get, unlike infra-space: the infra-space key (root
  on this clan), the hyperconfig deploy keys, the clan-secrets key, this
  clan's age identity, the fleet's /etc/hosts names or CA. It is confined
  (./host.nix `confine`): its traffic to the mesh (yggdrasil, retiolum),
  to private and ULA ranges (the LANs, zerotier, hyprspace, the other
  spaces and infra-space) and to every service of this host but DNS is
  refused. It reaches the internet, and through it what its own keys open.

  Its identities are clan vars of its machine, generated without prompts
  (`clan vars generate <machine>`; until then every `clan machines
  update` stops at them, so generate right after adding a space):
    space-<name>-hostkey   the guest's ssh host key; the desktops pin it
                           (./client.nix)
    whatever the space's own module adds (./gi-infra.nix, ./agave.nix),
                           each as a credential at
                           /run/<name>/secrets/<credential> (0400, the
                           user), never in the home on this host.
  Plus the p0 and TeamClaude keys for afk (the same shared vars as
  infra-space and the desktops). nspawn copies credentials in at
  container start only, so a rotation of any of them (and every change
  of the container's .conf: bind mounts, nspawn flags, addresses)
  restarts the space; a change of its guest alone switches it in place
  (`switch-to-configuration test` inside, as `nixos-rebuild switch`
  would), its users' sessions and processes kept (./host.nix).

  `tpm`: this host's /dev/tpmrm0 for an age identity sealed to it, made
  in the guest (`age-plugin-tpm --generate -o ~/.config/age/identities`),
  whose recipient the space's own clan adds; it decrypts nothing of this
  clan (not in ../infra-space/age-recipients.nix). The TPM is shared
  with infra-space: each identity file is only a handle, usable with the
  TPM, so infra-space's handle must never reach the space (it lives in
  /var/lib/infra-space/home, 0700 to infra-space's uid, bound nowhere
  else).

  Teardown: `nixos-container destroy <name>`; /var/lib/spaces/<name> stays.
*/
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  vars = config.clan.core.vars.generators;
  registry = import ./registry.nix;
  spaceHost = import ./host.nix { inherit config lib pkgs; };
  machine = config.clan.core.settings.machine.name;
  meshAddress = vars.yggdrasil.files.address.value;

  # Mesh, LANs, overlays, the other spaces and infra-space (./host.nix).
  blockedDestinations = {
    v4 = [
      "10.0.0.0/8"
      "100.64.0.0/10"
      "169.254.0.0/16"
      "172.16.0.0/12"
      "192.168.0.0/16"
    ];
    v6 = [
      # yggdrasil
      "200::/7"
      # retiolum
      "42::/16"
      "fc00::/7"
      "fe80::/10"
    ];
  };

  hostKeyCredential = "ssh-host-key";

  # Over the registry, not over hyper.spaces: this sets options of
  # hyper.spaces itself.
  spaceConfig =
    name: r:
    let
      cfg = config.hyper.spaces.${name};
      containerUnit = "container@${name}.service";
      stateDir = "/var/lib/spaces/${name}";
      guestHome = "/home/${name}";
      v4 = n: "10.235.0.${toString (4 * r.index + n)}";
      v6 = n: "fd23:5ace:0:${toString r.index}::${toString n}";
    in
    lib.mkIf cfg.enable (lib.mkMerge [
      {
        assertions = [
          {
            assertion = r.machine == machine;
            message = "hyper.spaces.${name}: ./registry.nix puts it on ${r.machine}, not ${machine}";
          }
          {
            assertion = !(cfg.credentials ? ${hostKeyCredential});
            message = "hyper.spaces.${name}.credentials: `${hostKeyCredential}` is the guest's ssh host key";
          }
        ];

        clan.core.vars.generators = {
          # nspawn reads credentials only at container start: a rotation
          # restarts it.
          inference-api-key.files.token.restartUnits = [ containerUnit ];
          teamclaude-api-key.files.key.restartUnits = [ containerUnit ];
          "space-${name}-hostkey" = {
            files.ssh_host_ed25519_key.restartUnits = [ containerUnit ];
            files."ssh_host_ed25519_key.pub".secret = false;
            runtimeInputs = [ pkgs.openssh ];
            script = ''
              ssh-keygen -q -t ed25519 -N "" -C "" -f "$out"/ssh_host_ed25519_key
            '';
          };
        };

      }
      (spaceHost {
        inherit name stateDir guestHome;
        inherit (r) uid sshPort proxyUid;
        proxyUser = "${name}-ssh";
        hostAddress = v4 1;
        localAddress = v4 2;
        hostAddress6 = v6 1;
        localAddress6 = v6 2;
        homeDir = "${stateDir}/home";
        address = cfg.address;
        inherit (cfg) meshInterface tpm;
        credentials = cfg.credentials // {
          ${hostKeyCredential} = vars."space-${name}-hostkey".files.ssh_host_ed25519_key.path;
        };
        confine = true;
        inherit blockedDestinations;
        specialArgs = { inherit inputs; };
        guestConfig = {
          imports = [
            ./guest.nix
            (import ./afk.nix "/run/${name}/secrets")
          ]
          ++ cfg.guestModules;
          space = {
            inherit name hostKeyCredential;
            user = name;
            inherit (r) uid;
            home = guestHome;
            description = "${name} space";
            credentials = lib.attrNames cfg.credentials;
            authorizedKeys = lib.attrValues cfg.adminKeys;
            resolver = v4 1;
            hostAddress = v4 1;
            hostAddress6 = v6 1;
            inherit (cfg) tpm gitIdentity;
          };
        };
      })
    ]);
in
{
  imports = [
    ./gi-infra.nix
    ./agave.nix
  ];

  options.hyper.spaces = lib.mkOption {
    default = { };
    description = "Named agent spaces on this machine (./registry.nix assigns each its machine, port, subnet and ids).";
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            enable = lib.mkEnableOption "the ${name} space";
            tpm = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Bind this host's TPM into the guest, for an age identity sealed to it.";
            };
            credentials = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Credential name -> path of a secret file here; installed at /run/${name}/secrets/<name> (0400, the space's user).";
            };
            guestModules = lib.mkOption {
              type = lib.types.listOf lib.types.deferredModule;
              default = [ ];
              description = "Extra modules of the container's system.";
            };
            adminKeys = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = import ../../admin-ssh-keys.nix;
              defaultText = lib.literalExpression "import modules/admin-ssh-keys.nix";
              description = "Keys authorized for the space's user: Dave's.";
            };
            gitIdentity = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {
                name = "${name} space (${config.clan.core.settings.machine.name})";
                email = "${name}-space@${config.clan.core.settings.machine.name}.d";
              };
              defaultText = lib.literalExpression ''{ name = "<name> space (<machine>)"; email = "<name>-space@<machine>.d"; }'';
              description = "Author of the space's git and jj commits.";
            };
            address = lib.mkOption {
              type = lib.types.str;
              default = meshAddress;
              defaultText = lib.literalMD "this machine's yggdrasil address (its public clan var)";
              description = "Address the guest's sshd is reached at.";
            };
            meshInterface = lib.mkOption {
              type = lib.types.str;
              default = "ygg";
              description = "Interface `address` lives on (firewall opening for the sshd port).";
            };
          };
        }
      )
    );
  };

  config = lib.mkMerge (
    lib.mapAttrsToList spaceConfig registry
    # Not under the `enable` above: defining hyper.spaces.<name> under its
    # own enable would recurse. Inert while the space is off.
    ++ lib.mapAttrsToList (name: _: {
      hyper.spaces.${name}.credentials = {
        p0-api-key = vars.inference-api-key.files.token.path;
        teamclaude-api-key = vars.teamclaude-api-key.files.key.path;
      };
    }) registry
  );
}
