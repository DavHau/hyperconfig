# hermes-onboard <machine> <user>
#
# Prints the access sheet for one hermes user on one machine: SSH login,
# one-shot TUI and omp launches, and the public web dashboard with its
# password. Everything is read from the flake (nixosConfigurations) and the
# clan vars store, so the sheet matches what is deployed. Run from the repo
# root (or set HYPERCONFIG to it).

usage() {
  echo "usage: hermes-onboard <machine> <user>" >&2
  exit 2
}

[ $# -eq 2 ] || usage
machine=$1
user=$2
repo=${HYPERCONFIG:-.}

# One eval for every fact. The public dashboard is declared in
# hyper.hermesDashboard (modules/nixos/hermes-dashboard-public.nix):
# https://<host>/<user>/, plus an optional legacy hostname at its root. The
# shared host is also the public DNS name of the machine, so SSH uses it.
# The user name is spliced into the expression; \${n} is Nix's, not the
# shell's.
expr=$(cat <<EOF
c:
let
  u = c.users.users.$user or null;
  h = c.services.hermes-microvm.users.$user or null;
  d = c.hyper.hermesDashboard.users.$user or null;
  comment = k: let p = builtins.filter builtins.isString (builtins.split " " k);
    in if builtins.length p > 2 then builtins.elemAt p 2 else "(no comment)";
in
{
  exists = u != null && h != null && h.enable;
  native = h != null && h.native;
  keys = if u == null then [ ] else map comment u.openssh.authorizedKeys.keys;
  publicHost = if d == null then null else c.hyper.hermesDashboard.host;
  dashboard = if d == null then null else "https://\${c.hyper.hermesDashboard.host}/";
  legacy = if d == null || d.legacyHost == null then null else "https://\${d.legacyHost}/";
  account = if d == null then null else d.account;
  issuer = if d == null then null else c.hyper.oidc.issuer;
  hasTelegram = (c.hyper.hermes.users.$user.telegram.enable or false);
  claudeAuth = c.environment.etc ? "hermes-claude-auth";
}
EOF
)
facts=$(nix eval --json "$repo#nixosConfigurations.$machine.config" --apply "$expr" 2>/dev/null) || {
  echo "hermes-onboard: cannot evaluate nixosConfigurations.$machine" >&2
  exit 1
}

if [ "$(jq -r .exists <<<"$facts")" != true ]; then
  echo "hermes-onboard: no hermes user '$user' on $machine" >&2
  exit 1
fi

native=$(jq -r .native <<<"$facts")
dashboard=$(jq -r '.dashboard // empty' <<<"$facts")
legacy=$(jq -r '.legacy // empty' <<<"$facts")
keys=$(jq -r '.keys | join(", ")' <<<"$facts")
host=$(jq -r '.publicHost // empty' <<<"$facts")
host=${host:-$machine}

echo "Hermes access for $user on $machine"
echo
echo "SSH login:        ssh $user@$host"
[ -n "$keys" ] && echo "                  (authorized key: $keys)"
echo "Hermes TUI:       ssh -t $user@$host hermes"
echo "Coding agent:     ssh -t $user@$host afk --model p0/qwen   (oh-my-pi, afk profile)"
if [ "$native" = true ]; then
  echo "                  (agent runs natively on $machine: full shell access to its own home)"
fi
if [ -n "$dashboard" ]; then
  echo "Web dashboard:    $dashboard"
  [ -n "$legacy" ] && echo "                  (also: $legacy, redirects there)"
  echo "                  sign in with the $(jq -r .issuer <<<"$facts") account '$(jq -r .account <<<"$facts")' (passkey)"
  echo "                  enroll: pocket-id-enroll $(jq -r .account <<<"$facts")  on the pocket-id host, send the link"
else
  echo "Web dashboard:    none (local only; hermes-desktop over SSH, see spaces hermes-remote)"
fi
if [ "$(jq -r .hasTelegram <<<"$facts")" = true ]; then
  echo "Telegram:         DM the bot; the allowlisted user id is in the telegram var"
fi
if [ "$native" = true ] && [ "$(jq -r .claudeAuth <<<"$facts")" = true ]; then
  echo "Claude Pro/Max:   ssh -t $user@$host 'HOME=~/hermes claude'  then /login; afterwards /model -> anthropic in the TUI"
  echo "                  (hermes-claude-auth is active; the login must land in the agent's HOME, ~/hermes)"
fi
