/*
  Named agent spaces: NixOS containers like infra-space (../infra-space),
  each for one job, none of them a fleet admin. hyper.spaces.<name> on the
  machines ./registry.nix assigns it to produces container <name>, its
  user <name>, its home /var/lib/spaces/<name>/home here.

  The same core as infra-space (./instance.nix on ./host.nix: private
  veth, NAT, DNS from this host's resolved, sshd at [<this host's mesh
  address>]:<sshPort> through a socket proxy, nothing but this host into
  the guest and on this host only root and the proxy, the home persisted
  here, credentials as systemd credentials, the host key and afk keys, the
  sibling copies; and the same guest base, ./guest-base.nix: fish, jj,
  git, nix, tmux, afk, herdr), plus ./guest.nix. Dave's admin keys log in.

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
    whatever the space's own module adds (./geninf-space.nix),
                           each as a credential at
                           /run/<name>/secrets/<credential> (0400, the
                           user), never in the home on this host.
  Plus the p0, TeamClaude and OpenRouter keys for afk (the same shared vars as
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
  spaceInstance = import ./instance.nix { inherit config lib pkgs inputs; };
  machine = config.clan.core.settings.machine.name;
  meshAddress = vars.yggdrasil.files.address.value;
  publicSpaces = import ./public.nix {
    inherit lib;
    inherit (inputs.clan-core) clanLib;
    flake = config.clan.core.settings.directory;
  };

  # Over the registry, not over hyper.spaces: this sets options of
  # hyper.spaces itself.
  spaceConfig =
    name: r:
    let
      cfg = config.hyper.spaces.${name};

      # The copies of this space on its other machines (./registry.nix),
      # from the public clan vars (./public.nix), reached as
      # <name>-<machine> with the shared root-ssh key, the space's identity
      # on every machine, which is authorized here (./instance.nix
      # `siblings`). Only for a space with a shared space-<name>-root-ssh
      # var passed in as a credential.
      rootSsh = vars."space-${name}-root-ssh" or null;
      rootSshCredential =
        if rootSsh == null || !(rootSsh.share or false) then
          null
        else
          lib.findFirst (
            n: cfg.credentials.${n} == rootSsh.files.id_ed25519.path
          ) null (lib.attrNames cfg.credentials);
      siblings = lib.optionals (rootSshCredential != null) (
        lib.filter (s: s.space == name && s.machine != machine) (lib.attrValues publicSpaces)
      );
    in
    lib.mkIf cfg.enable (lib.mkMerge [
      {
        assertions = [
          {
            assertion = lib.elem machine r.machines;
            message = "hyper.spaces.${name}: ./registry.nix puts it on ${lib.concatStringsSep ", " r.machines}, not ${machine}";
          }
        ];
      }
      (spaceInstance {
        inherit name siblings;
        inherit (r) index uid sshPort proxyUid;
        user = name;
        description = "${name} space";
        proxyUser = "${name}-ssh";
        stateDir = "/var/lib/spaces/${name}";
        guestHome = "/home/${name}";
        inherit (cfg)
          address
          meshInterface
          tpm
          privateUsers
          credentials
          guestModules
          ;
        hostKeyGenerator = "space-${name}-hostkey";
        authorizedKeys =
          lib.attrValues cfg.adminKeys ++ lib.optional (siblings != [ ]) rootSsh.files."id_ed25519.pub".value;
        siblingIdentity = rootSshCredential;
        # Mesh, LANs, overlays, the other spaces and infra-space (./host.nix).
        confine = true;
        blockedDestinations = import ./blocked-destinations.nix;
        # this host's nginx into the published port window (./publish.nix)
        toGuestRules = lib.optionalString (cfg.publish.enable && config.services.nginx.enable) "meta skuid ${
          toString config.users.users.${config.services.nginx.user}.uid
        } tcp dport ${toString cfg.publish.from}-${toString cfg.publish.to} return";
        guest = ./guest.nix;
        guestSpace = {
          inherit (cfg) gitIdentity;
          publish = {
            inherit (cfg.publish)
              enable
              from
              to
              domain
              accounts
              ;
            address = "10.235.0.${toString (4 * r.index + 2)}";
          };
        };
      })
    ]);
in
{
  imports = [
    ./geninf-space.nix
    ./usb-ports.nix
  ];
  # The host's front of the published apps (nginx, login, TLS) is
  # ./publish.nix, imported where hyperhermes' publish runs (som).

  options.hyper.spaces = lib.mkOption {
    default = { };
    description = "Named agent spaces on this machine (./registry.nix assigns each its machines, port, subnet and ids).";
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
            privateUsers = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Run the guest in its own user namespace (./host.nix, privateUsers); false is the rollback.";
            };
            credentials = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Credential name -> path of a secret file here; installed at /run/${name}/secrets/<name> (0400, the space's user). The p0, TeamClaude and OpenRouter keys come on top (./instance.nix).";
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
            publish = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Publish the port window: an app the space's user listens on at 0.0.0.0:<port> is https://<port>.${name}.<domain>/ for `accounts` (this host's nginx in front, ./publish.nix; ./publish-guest.nix in the guest).";
              };
              from = lib.mkOption {
                type = lib.types.port;
                default = 8000;
                description = "First port of the published window.";
              };
              to = lib.mkOption {
                type = lib.types.port;
                default = 8099;
                description = "Last port of the published window.";
              };
              domain = lib.mkOption {
                type = lib.types.str;
                default = "davhau.fyi";
                description = "Apps are https://<port>.${name}.<domain>/ (som: the hermes agents' exposure domain).";
              };
              accounts = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = (import ./registry.nix).${name}.owners or [ "dave" ];
                defaultText = lib.literalMD "./registry.nix's `owners` (default `[ \"dave\" ]`)";
                description = "pocket-id accounts (preferred_username) that get through the login; the others get 403. Each must be in ./registry.nix's `owners` too: the clan inventory gives those the space's group.";
              };
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

  config = lib.mkMerge (lib.mapAttrsToList spaceConfig registry);
}
