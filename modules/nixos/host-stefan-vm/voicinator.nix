{config, lib, pkgs, ...}: let
  vars = config.clan.core.vars.generators.voicinator;
in {
  clan.core.vars.generators.voicinator = {
    prompts.telegram-token = {};
    prompts.openai-api-key = {};
    prompts.blockonomics-api-key = {};
  };
  systemd.services.voicinator = {
    description = "voicemail to text chat bot";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      DynamicUser = "true";
      StateDirectory = "voicinator";
      RuntimeDirectory = "voicinator";
      CacheDirectory = "voicinator";
      LoadCredential = [
        "telegram_token:${vars.files.telegram-token.path}"
        "gpt-api-key:${vars.files.openai-api-key.path}"
        "blockonomics-api-key:${vars.files.blockonomics-api-key.path}"
      ];
      Restart = "always";
      RuntimeMaxSec = "12h";
    };
    path = [
      pkgs.coreutils
      pkgs.gitMinimal
      pkgs.nix
      pkgs.which
    ];
    environment = {
      XDG_CACHE_HOME = "%C/voicinator";
      MODEL_SIZE = "medium";
    };
    script = ''
      set -x
      repo=$STATE_DIRECTORY/voicinator
      if [ ! -d $repo/.git ]; then
        git clone https://github.com/shoutingcatana/voicinator "$repo"
      # else
      #   git -C $repo fetch
      #   git -C $repo reset --hard origin/main
      fi
      cd $RUNTIME_DIRECTORY
      echo "loading devShell of flake $repo"
      nix develop $(realpath $repo) -L -c python -u -c "print('hello')"
      nix develop $(realpath $repo) -L -c python -u $repo/telegram_bot.py
    '';
  };
}
