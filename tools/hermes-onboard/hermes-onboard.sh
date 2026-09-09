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

# One eval for every fact. The dashboard vhost is the nginx server whose
# proxyPass targets the native backend port (20000 + uid); its name is
# also the public DNS name of the machine, so SSH uses it too. The user
# name is spliced into the expression; \${n} is Nix's, not the shell's.
expr=$(cat <<EOF
c:
let
  u = c.users.users.$user or null;
  h = c.services.hermes-microvm.users.$user or null;
  backend = if u == null || u.uid == null then null else "http://127.0.0.1:" + toString (20000 + u.uid);
  servesBackend = v: builtins.any (l: (l.proxyPass or null) == backend) (builtins.attrValues v.locations);
  vhosts = builtins.filter (n: servesBackend c.services.nginx.virtualHosts.\${n})
    (builtins.attrNames c.services.nginx.virtualHosts);
  comment = k: let p = builtins.filter builtins.isString (builtins.split " " k);
    in if builtins.length p > 2 then builtins.elemAt p 2 else "(no comment)";
in
{
  exists = u != null && h != null && h.enable;
  native = h != null && h.native;
  keys = if u == null then [ ] else map comment u.openssh.authorizedKeys.keys;
  vhost = if backend != null && vhosts != [ ] then builtins.head vhosts else null;
  hasDashboardVars = c.clan.core.vars.generators ? "hermes-dashboard-$user";
  hasTelegram = (c.hyper.hermes.users.$user.telegram.enable or false);
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
vhost=$(jq -r '.vhost // empty' <<<"$facts")
keys=$(jq -r '.keys | join(", ")' <<<"$facts")
host=${vhost:-$machine}

echo "Hermes access for $user on $machine"
echo
echo "SSH login:        ssh $user@$host"
[ -n "$keys" ] && echo "                  (authorized key: $keys)"
echo "Hermes TUI:       ssh -t $user@$host hermes"
echo "Coding agent:     ssh -t $user@$host afk --model p0/qwen   (oh-my-pi, afk profile)"
if [ "$native" = true ]; then
  echo "                  (agent runs natively on $machine: full shell access to its own home)"
fi
if [ -n "$vhost" ] && [ "$(jq -r .hasDashboardVars <<<"$facts")" = true ]; then
  password=$(clan vars get "$machine" "hermes-dashboard-$user/password" 2>/dev/null) \
    || password="<not generated: clan vars generate $machine --generator hermes-dashboard-$user>"
  echo "Web dashboard:    https://$vhost"
  echo "                  user: $user   password: $password"
else
  echo "Web dashboard:    none (local only; hermes-desktop over SSH, see spaces hermes-remote)"
fi
if [ "$(jq -r .hasTelegram <<<"$facts")" = true ]; then
  echo "Telegram:         DM the bot; the allowlisted user id is in the telegram var"
fi
