# dave-hermes's Home Assistant token for the living-room TV's rack plug
# (switch.smartplug1 on cm-pi's HA, http://192.168.8.219:8123), used by its
# android-tv-customization skill to power-cycle the TV.
#
# A long-lived HA token minted on cm-pi; a persisted prompt, so the var
# holds exactly the token: `clan vars set som ha-rack-plug-token/token`.
# Readable by dave-hermes only, at
# config.clan.core.vars.generators.ha-rack-plug-token.files.token.path
# (/run/secrets/per-machine/som/ha-rack-plug-token/token); the skill reads
# that file, it never enters the agent's state dir.
{
  clan.core.vars.generators.ha-rack-plug-token = {
    prompts.token = {
      type = "hidden";
      persist = true;
      description = "HA long-lived token for dave-hermes on cm-pi's Home Assistant (switch.smartplug1, the TV rack plug)";
    };
    files.token = {
      owner = "dave-hermes";
      group = "users";
    };
  };
}
