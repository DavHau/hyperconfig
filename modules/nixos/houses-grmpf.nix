/*
  grmpf's nix-housing houses (see houses.nix): `house-slop` for coding agents,
  `house-secure` for key-touching ops (deploys, sops, clan vars).

  Each house has its own HOME (~/houses/<name>) and XDG_RUNTIME_DIR, so the
  real files and sockets a house needs are symlinked into it at launch and
  granted by their real path (Landlock checks the resolved inode). A separate
  HOME also means an empty direnv allow-list: no .envrc auto-loads in a house.
*/
{ config, lib, pkgs, ... }:
let
  home = config.users.users.grmpf.home;
  houseHome = "$NIX_HOUSING_HOUSE_HOME";
  houseRuntime = "$NIX_HOUSING_HOUSE_XDG_RUNTIME_DIR";
  realRuntime = "$NIX_HOUSING_REAL_XDG_RUNTIME_DIR";
  nixDaemonSocket = "/nix/var/nix/daemon-socket/socket";
  profile = "${config.environment.etc.profile.source}";

  # Shared by both houses: PATH and the system environment, plus symlinks.
  base = { lib, config, housingLib, ... }: {
    options.symlinks = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Link path -> target, created outside the sandbox before it starts.
        Both may reference the NIX_HOUSING_* variables set by dirSetup.
      '';
    };

    config = {
      # nix-housing v0.4's NixOS module only sources /etc/profile for
      # home-manager houses, leaving NixOS-module houses with no PATH.
      profilePaths = [ profile ];

      # v0.4 grants only /proc/self, which Landlock pins to the runner's own
      # pid, so every child (bun/omp, python, nix) is denied its /proc/self.
      # The house has a private PID-namespace /proc; the /sys entries are the
      # runtime probes bun aborts without.
      landlock.roDirs = [ "/proc" "/sys/devices/system/cpu" "/sys/kernel/mm/transparent_hugepage" ];

      execWrappers.symlinks = housingLib.dag.entryBetween [ "namespacing" ] [ "dirSetup" ] ''
        link() {
          if [ -e "$1" ] && [ ! -L "$1" ]; then
            echo "housing: refusing to replace $1 with a symlink" >&2
            exit 1
          fi
          mkdir -p "$(dirname "$1")"
          ln -sfn "$2" "$1"
        }
        ${lib.concatStrings (lib.mapAttrsToList (l: t: ''
          link "${l}" "${t}"
        '') config.symlinks)}
        exec "$@"
      '';
    };
  };
in
{
  imports = [ ./houses.nix ];

  # Houses run in a user namespace that maps only grmpf, so root-owned store
  # files appear owned by nobody and ssh rejects the root-owned Include this
  # adds to /etc/ssh/ssh_config ("Bad owner or permissions"), breaking ssh in
  # every house. Nothing here uses its unix/, vsock/ or machine/ host names.
  programs.ssh.systemd-ssh-proxy.enable = false;

  housing.users.grmpf.houses = {
    slop.capabilities = { housingLib, ... }: {
      imports = [ base ];
      landlock = {
        rwDirs = [
          "${home}/projects"
          "${home}/synced/projects"
          "${home}/bigfiles"
          "${home}/.omp/profiles/afk/agent"
          "${home}/.claude"
        ];
        rwFiles = [ "${home}/.claude.json" ];
        roDirs = [
          "${home}/.agents"
          "${home}/.config/git"
          "${home}/.config/jj"
        ];
        roFiles = [
          "${home}/.ssh/id_ed25519_github1"
          "${home}/.ssh/id_ed25519_github1.pub"
          config.clan.core.vars.generators.sbox-age.files.identity.path
          # p0 inference token, read by `p0-api-key` (inference-api-key.nix).
          config.clan.core.vars.generators.inference-api-key.files.token.path
          (config.hyper.inferenceApiKey.userTokenPath "grmpf")
          # TeamClaude key, read by `teamclaude-api-key` (teamclaude-api-key.nix).
          config.clan.core.vars.generators.teamclaude-api-key.files.key.path
        ];
        # The nix daemon socket is root-equivalent for trusted users (grmpf
        # is one); sbox exposes it too via its read-only /nix bind.
        socketFiles = [ nixDaemonSocket ];
        connectTcpPorts = [ 22 443 ]
          ++ lib.optional config.services.llama-swap.enable config.services.llama-swap.port;
      };
      symlinks = {
        "${houseHome}/.omp/profiles/afk/agent" = "${home}/.omp/profiles/afk/agent";
        "${houseHome}/.claude" = "${home}/.claude";
        "${houseHome}/.claude.json" = "${home}/.claude.json";
        "${houseHome}/.agents" = "${home}/.agents";
        "${houseHome}/.config/git" = "${home}/.config/git";
        "${houseHome}/.config/jj" = "${home}/.config/jj";
        "${houseHome}/.ssh/id_ed25519_github" = "${home}/.ssh/id_ed25519_github1";
        "${houseHome}/.config/age/identities" =
          config.clan.core.vars.generators.sbox-age.files.identity.path;
      };
      # ssh resolves ~ from passwd, not $HOME, so it never looks in the house
      # home; point git (and jj, which shells out to git) at the GitHub key.
      # The system ControlPath (~/.ssh/control) is denied here, and a failed
      # mux bind aborts the connection, so multiplexing is off.
      execWrappers.githubKey = housingLib.dag.entryBetween [ "final" ] [ "profile" ] ''
        export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_ed25519_github -o IdentitiesOnly=yes -o ControlPath=none"
        exec "$@"
      '';
    };

    secure.packages = [ pkgs.sops ];

    secure.capabilities = { housingLib, ... }: {
      imports = [ base ];
      landlock = {
        rwDirs = [
          "${home}/synced/projects/hyperconfig"
          "${home}/.ssh/control"
        ];
        roDirs = [
          "${home}/.ssh"
          "${home}/.config/sops/age"
          "${home}/.config/git"
          "${home}/.config/jj"
        ];
        socketDirs = [ "${home}/.ssh/control" ];
        socketFiles = [
          nixDaemonSocket
          "${realRuntime}/ssh-agent"
          "${realRuntime}/ssh-tpm-agent.sock"
        ];
        connectTcpPorts = [ 22 443 ];
      };
      symlinks = {
        "${houseHome}/.config/sops/age" = "${home}/.config/sops/age";
        "${houseHome}/.config/git" = "${home}/.config/git";
        "${houseHome}/.config/jj" = "${home}/.config/jj";
        "${houseRuntime}/ssh-agent" = "${realRuntime}/ssh-agent";
        "${houseRuntime}/ssh-tpm-agent.sock" = "${realRuntime}/ssh-tpm-agent.sock";
      };
      # Never run git hooks: a hook planted by an agent in a repo must not
      # execute where the deploy and sops keys are reachable.
      execWrappers.noGitHooks = housingLib.dag.entryBetween [ "final" ] [ "profile" ] ''
        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0=core.hooksPath
        export GIT_CONFIG_VALUE_0=/dev/null
        exec "$@"
      '';
    };
  };
}
