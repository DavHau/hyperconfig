# Evaluation-only check of nixosModules.clan, on a system whose
# clan.core.vars.generators is a stub option (clan-core's own module is
# not an input of this flake): the generator names and file attributes
# the clan's vars store holds, and the secret paths they fill in. A
# renamed generator orphans its stored secret, so the names are pinned
# exactly. Also: core imported twice (default plus core) evaluates. Fails
# at evaluation, naming every expectation that does not hold.
{ pkgs, self }:
let
  inherit (pkgs) lib;

  # The part of clan-core's vars module that nixosModules.clan reads and
  # writes: generators with free-form attributes, and files whose path
  # defaults to a runtime location outside the store.
  clanStub =
    { lib, ... }:
    let
      inherit (lib) mkOption types;
      freeform = types.attrsOf types.anything;
    in
    {
      options.clan.core.vars.generators = mkOption {
        default = { };
        type = types.attrsOf (
          types.submodule (
            { name, ... }:
            let
              gen = name;
            in
            {
              freeformType = freeform;
              options.files = mkOption {
                default = { };
                type = types.attrsOf (
                  types.submodule (
                    { name, ... }:
                    {
                      freeformType = freeform;
                      options.path = mkOption {
                        type = types.str;
                        default = "/run/vars/${gen}/${name}";
                      };
                    }
                  )
                );
              };
            }
          )
        );
      };
    };

  base = {
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
    };
  };

  evalWith =
    modules:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        base
        clanStub
        self.nixosModules.clan
      ]
      ++ modules;
    };

  failedAssertions = sys: map (a: a.message) (lib.filter (a: !a.assertion) sys.config.assertions);
  # Forces the whole system without building it: unmet assertions throw.
  evaluates = sys: lib.isString (builtins.unsafeDiscardStringContext sys.config.system.build.toplevel.drvPath);

  sshHost = "gpu.example";
  agents = {
    services.hyperhermes = {
      agents = {
        alice.uid = 1001;
        bob.uid = 1002;
      };
      sshKeyHosts = [ sshHost ];
    };
  };

  # Every feature imported, none enabled: core's generators only.
  idle = evalWith [
    self.nixosModules.default
    agents
  ];

  # Every feature with a generator enabled.
  enabled = evalWith [
    self.nixosModules.default
    agents
    {
      users.users.carol.isNormalUser = true;
      services.hyperhermes = {
        wallet.enable = true;
        teamclaude.gatewayUrl = "https://teamclaude.example.org";
        agents.alice.teamclaude.enable = true;
        desktop = {
          enable = true;
          host = "agents.example.org";
          hostLabel = "agents";
          agents.alice = "Alice";
          primary = "alice";
          users = [ "carol" ];
        };
      };
    }
  ];

  # The published ports (local mode, so no issuer to name): their cookie
  # secret from clan, the client secret's restart.
  published = evalWith [
    self.nixosModules.default
    agents
    {
      services.hyperhermes = {
        exposure.enable = true;
        sso = {
          enable = true;
          accounts = {
            alice = "alice";
            bob = "bob";
          };
          clients = lib.genAttrs [ "hermes-alice" "hermes-bob" "hermes-serve" ] (id: {
            secretFile = "/run/secrets/${id}";
          });
          dex.users = lib.genAttrs [ "alice" "bob" ] (account: {
            passwordHashFile = "/run/secrets/${account}.hash";
          });
        };
        dashboards.enable = true;
        publish.enable = true;
      };
    }
  ];

  # nixosModules.default already imports core.
  coreTwice = evalWith [
    self.nixosModules.default
    self.nixosModules.core
    agents
  ];

  gens = sys: sys.config.clan.core.vars.generators;
  genNames = sys: lib.sort lib.lessThan (lib.attrNames (gens sys));
  aliceGen = sys: (gens sys).hermes-agent-ssh-alice;
  aliceKey = sys: (aliceGen sys).files.key.path;
  sshConfig = sys: sys.config.environment.etc."ssh/ssh_config".text;
  hyper = sys: sys.config.services.hyperhermes;

  expectations = {
    idle-evaluates = evaluates idle && failedAssertions idle == [ ];
    idle-core-generators-only =
      genNames idle == [
        "hermes-agent-ssh-alice"
        "hermes-agent-ssh-bob"
      ];
    agent-key-owned-by-agent =
      (aliceGen idle).files.key.owner == "alice" && (aliceGen idle).files.key.secret;
    agent-pubkey-public = !(aliceGen idle).files."key.pub".secret;
    agent-sshKeyFile-default = (hyper idle).agents.alice.sshKeyFile == aliceKey idle;
    agent-ssh-config =
      lib.hasInfix "Match host ${sshHost} localuser alice\n  IdentityFile ${aliceKey idle}\n" (sshConfig idle)
      && lib.hasInfix "IdentityFile ${(gens idle).hermes-agent-ssh-bob.files.key.path}\n" (sshConfig idle);

    enabled-evaluates = evaluates enabled && failedAssertions enabled == [ ];
    enabled-generator-names =
      genNames enabled == [
        "hermes-agent-ssh-alice"
        "hermes-agent-ssh-bob"
        "hermes-desktop-ssh"
        "phoenixd-api"
        "phoenixd-seed"
        "teamclaude-hermes-alice"
      ];
    wallet-files =
      (hyper enabled).wallet.seedFile == (gens enabled).phoenixd-seed.files.seed.path
      && (hyper enabled).wallet.apiConfigFile == (gens enabled).phoenixd-api.files."phoenix.conf".path
      && (gens enabled).phoenixd-seed.files.seed.owner == "phoenixd";
    teamclaude-key-file =
      (hyper enabled).agents.alice.teamclaude.keyFile
      == (gens enabled).teamclaude-hermes-alice.files.key.path;
    desktop-key-file =
      (hyper enabled).desktop.sshKeyFile == (gens enabled).hermes-desktop-ssh.files.key.path
      && (gens enabled).hermes-desktop-ssh.share;

    published-evaluates = evaluates published && failedAssertions published == [ ];
    published-generator-names =
      genNames published == [
        "hermes-agent-ssh-alice"
        "hermes-agent-ssh-bob"
        "hermes-serve-oauth2-proxy"
        "oidc-client-hermes-alice"
        "oidc-client-hermes-bob"
        "oidc-client-hermes-serve"
      ];
    publish-cookie-secret-file =
      (hyper published).publish.cookieSecretFile
      == (gens published).hermes-serve-oauth2-proxy.files.cookie_secret.path
      && (gens published).hermes-serve-oauth2-proxy.files.cookie_secret.restartUnits == [
        "oauth2-proxy-serve.service"
      ];
    publish-client-secret-restarts =
      (gens published).oidc-client-hermes-serve.files.secret.restartUnits == [
        "oauth2-proxy-serve.service"
      ];

    core-imported-twice-evaluates = evaluates coreTwice && failedAssertions coreTwice == [ ];
  };

  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) expectations);
in
if failed != [ ] then
  throw "hyperhermes clan-eval: failed expectations: ${lib.concatStringsSep ", " failed}"
else
  pkgs.runCommand "hyperhermes-clan-eval" { } ''
    echo ${lib.escapeShellArg (lib.concatStringsSep "\n" (lib.attrNames expectations))} > $out
  ''
