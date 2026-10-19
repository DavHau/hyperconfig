# hermes-onboard <machine> <agent>
#
# Prints the welcome message for the person behind one published hermes
# agent (hyper.hermesDashboard.users), ready to paste: a one-time link to
# set up their passkey, then where to talk to the agent (browser, Hermes
# Mobile, terminal). Operator notes go to stderr. Facts come from the flake
# and the clan vars store, so the message matches what is deployed. Run
# from the repo root (or set HYPERCONFIG).
#
# The message names only the front door (hermes.davhau.com): it signs the
# person in and forwards to their dashboard on the agents' site, and its
# /app page shows the address for the app
# (modules/nixos/hermes-dashboard-public.nix).
#
# The setup link is a pocket-id one-time access token, minted through the
# admin API with the oidc server's static API key (clan var
# pocket-id/api_key). Each run mints a new one, valid LINK_DAYS days
# (default 7, pocket-id caps it at 31), good for one sign-in.

[ $# -eq 2 ] || {
  echo "usage: hermes-onboard <machine> <agent>" >&2
  exit 2
}
machine=$1
agent=$2
repo=${HYPERCONFIG:-.}
link_days=${LINK_DAYS:-7}

die() {
  echo "hermes-onboard: $*" >&2
  exit 1
}

# One eval for every fact; \${…} below is Nix's, not the shell's.
facts=$(nix eval --json "$repo#nixosConfigurations.$machine.config" --apply "$(cat <<EOF
c:
let
  d = c.hyper.hermesDashboard.users.$agent or null;
  comment = k: let p = builtins.filter builtins.isString (builtins.split " " k);
    in if builtins.length p > 2 then builtins.elemAt p 2 else "(no comment)";
in
if d == null then null else {
  inherit (d) account;
  front = c.hyper.hermesDashboard.host;
  issuer = c.hyper.oidc.issuer;
  keys = map comment c.users.users.$agent.openssh.authorizedKeys.keys;
  telegram = c.hyper.hermes.users.$agent.telegram.enable or false;
  claude = c.environment.etc ? "hermes-claude-auth";
}
EOF
)" 2>/dev/null) || die "cannot evaluate nixosConfigurations.$machine"
[ "$facts" != null ] || die "no published hermes agent '$agent' on $machine"

get() { jq -r ".$1" <<<"$facts"; }
account=$(get account)
front=$(get front)
issuer=$(get issuer)

# Mint the link before printing anything: without it the message is useless.
server=$(nix eval --raw "$repo#clan.inventory.instances.oidc.roles.server.machines" \
  --apply 'm: builtins.head (builtins.attrNames m)' 2>/dev/null) ||
  die "no oidc server machine in the clan inventory"
key=$(clan vars get "$server" pocket-id/api_key 2>/dev/null) ||
  die "cannot read clan var pocket-id/api_key of $server"
# The admin key rides in through a file descriptor, not argv (ps).
api() { curl -fsS -H @<(printf 'X-API-Key: %s\n' "$key") "$@"; }
# search is a substring match; pick the exact username.
id=$(api --get --data-urlencode "search=$account" "$issuer/api/users" |
  jq -r --arg a "$account" '.data[] | select(.username == $a) | .id') ||
  die "pocket-id user lookup failed"
[ -n "$id" ] || die "no pocket-id account '$account' yet (deploy $server first)"
token=$(api -H 'Content-Type: application/json' -d "{\"ttl\":\"$((link_days * 24))h\"}" \
  "$issuer/api/users/$id/one-time-access-token" | jq -er .token) ||
  die "pocket-id token creation failed"

echo "hermes-onboard: pocket-id account $account; SSH keys: $(jq -r '.keys | join(", ")' <<<"$facts")" >&2

cat <<EOF
Welcome to Hermes!

Hermes is your personal AI assistant. It runs around the clock on DavHau's
server and keeps its own files.

1. Set up your login (once, before $(date -d "+$link_days days" '+%A, %-d %B'))

   $issuer/lc/$token

   This personal link signs you in once. Add a passkey when asked (phone,
   fingerprint or computer login; no password). Keep the link to yourself.

2. Talk to your assistant

   Browser:  https://$front/  (sign in with your passkey, then bookmark the
             page you land on)
   Phone:    open https://$front/app on your phone; it walks you through
             the app (Android and iPhone).
EOF

if [ "$(get telegram)" = true ]; then
  echo
  echo "   Telegram: your bot is set up, just send it a message."
fi

echo
echo "3. Optional"
echo
if [ "$(get claude)" = true ]; then
  echo "   Claude Pro/Max: write \"Connect my Claude subscription\" in the chat"
  echo "   and follow the link it sends."
fi
cat <<EOF
   Other messengers (Telegram, WhatsApp, Signal, ...): connect them on the
   Channels page of your dashboard.
   Terminal: ssh $agent@$front  (ssh -t $agent@$front hermes to chat)
EOF
