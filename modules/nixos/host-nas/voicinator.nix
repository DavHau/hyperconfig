{config, lib, pkgs, ...}: let
  secret = config.clanCore.facts.services.voicinator.secret;
  telegram-token = config.sops.secrets.nas-voicinator-telegram-token.path;
  openai-api-key = config.sops.secrets.openai-api-key.path;
in {
  clanCore.facts.services.voicinator = {
    generator.script = ''
      echo $prompt_value > $secrets/voicinator-telegram-token
    '';
    generator.prompt = "Enter Telegram api token for voicinator service:";
    secret.voicinator-telegram-token = {};
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
        "telegram_token:${telegram-token}"
        "gpt-api-key:${openai-api-key}"
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
      if [ ! -d $STATE_DIRECTORY/.git ]; then
        git -C $STATE_DIRECTORY clone https://github.com/shoutingcatana/voicinator
      else
        git -C $STATE_DIRECTORY fetch
        git -C $STATE_DIRECTORY reset --hard origin/main
      fi
      cd $RUNTIME_DIRECTORY
      echo "loading devShell of flake $STATE_DIRECTORY"
      nix develop $(realpath $STATE_DIRECTORY) -L -c python -u -c "print('hello')"
      nix develop $(realpath $STATE_DIRECTORY) -L -c python -u $STATE_DIRECTORY/telegram_bot.py
    '';
  };
}
