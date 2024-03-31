{config, lib, pkgs, ...}: let
  secret = config.clanCore.facts.services.voicinator.secret;
  tokenPath = config.sops.secrets.nas-voicinator-telegram-token.path;
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
      LoadCredential = "telegram-bot-token:${tokenPath}";
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
      if [ ! -d $STATE_DIRECTORY/.git ]; then
        git -C $STATE_DIRECTORY clone https://github.com/DavHau/voicinator
      else
        git -C $STATE_DIRECTORY pull
      fi
      cd $RUNTIME_DIRECTORY
      export TELEGRAM_BOT_TOKEN=$(cat $CREDENTIALS_DIRECTORY/telegram-bot-token)
      echo "loading devShell of flake $STATE_DIRECTORY"
      nix develop $(realpath $STATE_DIRECTORY) -L -c python -u -c "print('hello')"
      nix develop $(realpath $STATE_DIRECTORY) -L -c python -u $STATE_DIRECTORY/telegram_bot.py
    '';
  };
}
