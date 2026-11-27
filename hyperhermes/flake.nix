{
  description = "hyperhermes: NixOS modules that run hermes-agent for several agents on one host";

  inputs = {
    # A consumer that makes this follow its own nixpkgs builds against
    # that one instead.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    hermes-agent.url = "github:NousResearch/hermes-agent/v0.23.0";
    hermes-agent.inputs.nixpkgs.follows = "nixpkgs";
    # hermes-agent uses home-manager only for its own checks (its flake.nix
    # says so); pointing the input at this flake keeps home-manager out of
    # the lock file.
    hermes-agent.inputs.home-manager.follows = "";

    # The phone apps' builds (pkgs/android-apps) only: their gradle lock
    # files hold exactly the plugins this nixpkgs' gradle fetches, so it
    # moves only together with them (pkgs/android-apps/README.md), never
    # with a consumer's nixpkgs bump.
    nixpkgs-android-apps.url = "github:NixOS/nixpkgs/e21fec321d73511849707a7585e4ea155ee4bf40";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-android-apps,
      hermes-agent,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # core's default package (upstream with the wheel patches), which the
      # checks run: the dashboards' group check is one of the patches.
      hermesPackage = import ./modules/core/package.nix {
        inherit lib system hermes-agent;
      };
    in
    {
      # One module per feature; `default` imports all of them, each off
      # until enabled.
      nixosModules = {
        core = import ./modules/core { inherit hermes-agent; };
        exposure = ./modules/exposure.nix;
        sso = ./modules/sso.nix;
        browser = ./modules/browser;
        wallet = ./modules/wallet;
        rea = ./modules/rea;
        teamclaude = ./modules/teamclaude.nix;
        claude-auth = ./modules/claude-auth;
        # Not lib.modules.importApply: its wrapper module moves these
        # modules' definitions within list-typed options (PATH order,
        # ssh_config blocks) on every importer; each module names its own
        # file (`_file`) for error messages instead.
        desktop = import ./modules/desktop { inherit hermes-agent; };
        dashboards = ./modules/dashboards;
        publish = ./modules/publish;
        mail = ./modules/mail;
        vault-request = ./modules/vault-request;
        # Our signed builds of the Hermes phone apps, served for Obtainium.
        android-apps = ./modules/android-apps.nix;
        # Agent slots (a NixOS container per agent) on container-slots,
        # which is generic (not hermes-specific) and also usable alone;
        # slots imports it.
        container-slots = ./modules/container-slots.nix;
        slots = ./modules/slots;
        # For the system inside a container slot (not the host): what
        # every slot guest needs (nspawn, sshd with the host's keys), the
        # storage convention's tool defaults and scratch ~/.cache.
        slot = ./modules/slot;
        default = {
          imports = [
            self.nixosModules.core
            self.nixosModules.exposure
            self.nixosModules.sso
            self.nixosModules.browser
            self.nixosModules.wallet
            self.nixosModules.rea
            self.nixosModules.teamclaude
            self.nixosModules.claude-auth
            self.nixosModules.desktop
            self.nixosModules.dashboards
            self.nixosModules.publish
            self.nixosModules.mail
            self.nixosModules.vault-request
            self.nixosModules.android-apps
            self.nixosModules.slots
          ];
        };
        # Not a feature, so not in `default`: fills core's and the
        # features' secret paths from clan vars when the importing system
        # is a clan machine.
        clan = ./modules/clan.nix;
        # The local deployment on a workstation: hyperhermes (default) in a
        # NixOS container, forwarded to the host's loopback.
        local-container = lib.modules.importApply ./modules/local-container {
          hyperhermes = self.nixosModules.default;
        };
      };

      # A workstation with the local deployment (./example).
      nixosConfigurations.example = lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.local-container
          ./example/configuration.nix
        ];
      };

      packages.${system} = {
        tcp-owner-bridge = import ./pkgs/tcp-owner-bridge { inherit pkgs; };
        # The browser feature's own builds (the module calls them with the
        # host's pkgs): Camoufox, camofox-browser with its captcha plugin,
        # and the two Python libraries a consumer's own browser tooling
        # needs, built for pkgs.python3.
        camoufox = pkgs.callPackage ./pkgs/camoufox/browser.nix { };
        camofox-browser = pkgs.callPackage ./pkgs/camofox-browser { };
        camoufox-python = pkgs.python3Packages.callPackage ./pkgs/camoufox/python.nix { };
        captchakraken-python = pkgs.python3Packages.callPackage ./pkgs/captchakraken/python.nix { };
        hermes-desktop = import ./pkgs/hermes-desktop { inherit pkgs hermes-agent; };
        # REA, the CLI and MCP server of nixosModules.rea (which calls it
        # with the host's pkgs).
        rea-agents = pkgs.callPackage ./pkgs/rea-agents { };
      }
      # The Hermes phone apps with our patches, unsigned (pkgs/android-apps;
      # nixosModules.android-apps signs and serves them). The Android SDK
      # is unfree and wants its license accepted.
      // (import nixpkgs-android-apps {
        inherit system;
        config = {
          android_sdk.accept_license = true;
          # This instance builds only these two apps: the unfree parts are
          # the SDK's (meta.position is not set yet when the predicate runs).
          allowUnfree = true;
        };
      }).callPackages ./pkgs/android-apps { };

      # For consumers that must name an agent's paths, ports or units
      # without evaluating the host that runs it (lib/core.nix: stateDir,
      # workspace, agentUnits, chain, dashboardPortFor, ...), plus:
      #   mkAgentSkill pkgs { name; src; packages; }  one skill package,
      #   pythonVenv pkgs   the agents' writable venv unit factory, and
      #   pythonPackages    its default library set, for a host the agents
      #                     ssh into (e.g. built against CUDA there).
      lib = import ./lib/core.nix { inherit lib; } // {
        mkAgentSkill = import ./lib/agent-skill.nix;
        sso = import ./lib/sso.nix { inherit lib; };
        # Generator names of nixosModules.clan (teamclaudeGenerator, ...).
        clan = import ./lib/clan.nix;
        pythonVenv =
          pkgs:
          import ./lib/python-venv.nix {
            inherit (pkgs) lib;
            inherit pkgs;
          };
        pythonPackages = import ./lib/python-packages.nix;
      };

      checks.${system} = {
        core = import ./checks/core { inherit pkgs self; };
        # A systemd-nspawn container, no VM: the venv's wheel libraries
        # reach its interpreter only, not the gateway, its terminal
        # commands or a login shell.
        wheel-libs = import ./checks/wheel-libs { inherit pkgs self; };
        # A dashboard restart drains, keeps the interrupted chat turn and
        # continues it without a client; a user Stop is not continued.
        resume = import ./checks/resume { inherit pkgs self; };
        # Root's hermes-notify: a message from another agent into a chat
        # session, steered or as a new turn, never as the owner's.
        agent-notify = import ./checks/agent-notify { inherit pkgs self; };
        # Every agent and later profile gets a real compaction summary:
        # Opus 5.5 with an Anthropic credential, else the main model.
        compaction = import ./checks/compaction { inherit pkgs self; };
        # services.hyperhermes.hardening, with io_uring off host-wide.
        hardening = import ./checks/hardening { inherit pkgs self; };

        local-sso = import ./checks/local-sso {
          inherit pkgs self hermesPackage;
        };

        locked-config = import ./checks/locked-config {
          inherit pkgs self hermesPackage;
        };

        public = import ./checks/public {
          inherit pkgs self hermesPackage;
        };

        # Local mode: published ports behind the local dex, end to end.
        publish = import ./checks/publish { inherit pkgs self; };

        browser = import ./checks/browser { inherit pkgs self; };
        wallet = import ./checks/wallet { inherit pkgs self; };
        # nixosModules.android-apps: signs at runtime, serves /apps/
        # without the host's sign-in.
        android-apps = import ./checks/android-apps { inherit pkgs self; };
        mail = import ./checks/mail { inherit pkgs self; };
        # A request link, the signed-in owner saving a test card into the
        # agent's vault, and the refusals (reuse, cross-site, another
        # agent's owner).
        vault-request = import ./checks/vault-request { inherit pkgs self hermesPackage; };
        # The vault out of the agent's reach: migration, refusals, fills.
        vault-broker = import ./checks/vault-broker { inherit pkgs self; };
        slots = import ./checks/slots { inherit pkgs self; };
        slots-local = import ./checks/slots/local.nix { inherit pkgs self; };
        container-slots-storage = import ./checks/container-slots-storage { inherit pkgs self; };
        # Offline: every main model gets a working image path on the
        # patched package (native for vision-capable ones, p0's Qwen as
        # the describer for text-only ones).
        vision = import ./checks/vision { inherit pkgs hermesPackage; };
        # Offline: model_catalog.openrouter_all_models lists every
        # tool-capable OpenRouter model after the curated ones, on every
        # picker surface.
        openrouter-catalog = import ./checks/openrouter-catalog { inherit pkgs hermesPackage; };
        openrouter-native = import ./checks/openrouter-native { inherit pkgs hermesPackage; };
        openrouter-no-batch = import ./checks/openrouter-no-batch { inherit pkgs hermesPackage; };
        subagent-shell = import ./checks/subagent-shell { inherit pkgs hermesPackage; };
        # Offline: with HERMES_GATEWAY_MANAGED_UNIT, no client or
        # `gateway run` starts a gateway beside the agent's unit.
        managed-unit = import ./checks/managed-unit { inherit pkgs hermesPackage; };
        # Offline: memory.background_consolidation "auto" applies the
        # background review's patch/remove with a snapshot; "stage" stages.
        memory-consolidation = import ./checks/memory-consolidation { inherit pkgs hermesPackage; };
        # Offline: the history page revalidates (ETag, 304 when unchanged).
        messages-etag = import ./checks/messages-etag { inherit pkgs hermesPackage; };
        # Offline: browser_vault fills a card only into a known processor's
        # card frame embedded directly in the bound checkout (CDP and the
        # Camofox page backend), after consent.
        vault-payment-frames = import ./checks/vault-payment-frames {
          inherit pkgs hermesPackage;
          hermesSrc = hermes-agent;
        };
        # Evaluation only: teamclaude, claude-auth, desktop and rea on a
        # system without clan, secrets as runtime paths.
        client-features = import ./checks/client-features { inherit pkgs self; };
        # Evaluation only: nixosModules.clan's generator names and the
        # secret paths they fill, against a stub clan.core.vars.
        clan-eval = import ./checks/clan-eval { inherit pkgs self; };
        # nixosModules.local-container with the example's config, from the
        # host: dashboard sign-in, a published port, the agent's slot.
        local-deployment = import ./checks/local-deployment { inherit pkgs self; };
      };
    };
}
