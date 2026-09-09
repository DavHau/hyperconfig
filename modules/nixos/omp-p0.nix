# The bare `omp` from spaces' agentHarnesses (desktop profile) ships no
# providers: spaces refuses to manage harness config files because the
# harness rewrites them. models.yml is the exception, omp only reads it, so
# the same store file afk links into its profile (omp-common.nix) is linked
# into bare omp's ~/.omp/agent by a per-user oneshot, the way spaces links
# skills into ~/.agents/skills. The key comes from `apiKey: "!p0-api-key"`
# inside that file, so no environment plumbing is needed. Skills are
# already shared: both harnesses scan ~/.agents/skills.
#
# A models.yml the user wrote is left alone; only an absent file or a link
# into the store (ours from an earlier generation) is replaced. The default
# model role (p0/qwen) is seeded once into config.yml, see omp-p0-link.sh.
{ pkgs, inputs, lib, config, ... }:
let
  common = import ./omp-common.nix { inherit pkgs inputs lib config; };
in
{
  systemd.user.services.omp-p0-models = lib.mkIf common.models-needed {
    description = "Link the p0 models.yml into this user's bare omp profile";
    wantedBy = [ "default.target" ];
    environment = {
      MODELS_FILE = "${common.modelsFile}";
      DEFAULT_MODEL = "p0/qwen";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe (
        pkgs.writeShellApplication {
          name = "omp-p0-link";
          runtimeInputs = [ pkgs.coreutils pkgs.gnugrep ];
          text = builtins.readFile ./omp-p0-link.sh;
        }
      );
    };
  };
}
