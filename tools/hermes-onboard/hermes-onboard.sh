# hermes-onboard <machine> <user>
#
# Prints the welcome sheet for one hermes user on one machine, written to
# be pasted to the person as is: first the one-time passkey setup link,
# then the web dashboard, then optional extras (Claude subscription through
# the agent's own OAuth flow, messengers on the dashboard's Channels page),
# then the terminal access for those who want it.
# Notes meant for the operator (which keys log in, where secrets live) go
# to stderr, so stdout stays the message. Everything is read from the flake
# (nixosConfigurations, clan inventory) and the clan vars store, so the
# sheet matches what is deployed. Run from the repo root (or set
# HYPERCONFIG to it).
#
# The setup link is a pocket-id one-time access token, minted through the
# admin API with the server's static API key (clan var pocket-id/api_key of
# the oidc server machine). Every run mints a new one; each is valid for
# LINK_DAYS days (default 7, pocket-id caps it at 31) and signs in once.
# The person then registers a passkey on the account page it lands on.

usage() {
  echo "usage: hermes-onboard <machine> <user>" >&2
  exit 2
}

[ $# -eq 2 ] || usage
machine=$1
user=$2
repo=${HYPERCONFIG:-.}
link_days=${LINK_DAYS:-7}
link_ttl="$((link_days * 24))h"

# pocket_id_link <issuer> <account>: prints a one-time login link, or an
# error on stderr and nothing on stdout.
pocket_id_link() {
  local issuer=$1 account=$2 server key id token
  server=$(nix eval --raw "$repo#clan.inventory.instances.oidc.roles.server.machines" \
    --apply 'm: builtins.head (builtins.attrNames m)' 2>/dev/null) || {
    echo "hermes-onboard: cannot find the oidc server machine in the clan inventory" >&2
    return 1
  }
  key=$(clan vars get "$server" pocket-id/api_key 2>/dev/null) || {
    echo "hermes-onboard: cannot read clan var pocket-id/api_key of $server" >&2
    return 1
  }
  # The admin key rides in through a file descriptor, not argv (ps).
  api() { curl -fsS -H @<(printf 'X-API-Key: %s\n' "$key") "$@"; }
  # search is a substring match over name/email/username; pick the exact
  # username.
  id=$(api --get --data-urlencode "search=$account" "$issuer/api/users" |
    jq -r --arg a "$account" '.data[] | select(.username == $a) | .id') || {
    echo "hermes-onboard: pocket-id user lookup failed" >&2
    return 1
  }
  if [ -z "$id" ]; then
    echo "hermes-onboard: no pocket-id account '$account' yet (deploy $server first)" >&2
    return 1
  fi
  token=$(api -H 'Content-Type: application/json' -d "{\"ttl\":\"$link_ttl\"}" \
    "$issuer/api/users/$id/one-time-access-token" | jq -er .token) || {
    echo "hermes-onboard: pocket-id token creation failed" >&2
    return 1
  }
  echo "$issuer/lc/$token"
}

# One eval for every fact. The public dashboard is declared in
# hyper.hermesDashboard (modules/nixos/hermes-dashboard-public.nix):
# https://<host>/. The
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
keys=$(jq -r '.keys | join(", ")' <<<"$facts")
host=$(jq -r '.publicHost // empty' <<<"$facts")
host=${host:-$machine}

note() { echo "hermes-onboard: $*" >&2; }

# Mint the setup link before printing anything: a sheet without it is
# useless, so fail instead of printing half a message.
if [ -n "$dashboard" ]; then
  issuer=$(jq -r .issuer <<<"$facts")
  account=$(jq -r .account <<<"$facts")
  link=$(pocket_id_link "$issuer" "$account") || exit 1
fi

[ -n "$keys" ] && note "SSH as $user accepts the keys: $keys"

echo "Welcome to Hermes, $user!"
echo
echo "Hermes is your personal AI assistant. It runs on DavHau.com around the"
echo "clock and keeps its own files, so you can come back to it any time."

if [ -n "$dashboard" ]; then
  echo
  echo "STEP 1 - Set up your login (do this first, only once)"
  echo
  echo "  Open this personal link before $(date -d "+$link_days days" '+%A, %-d %B'):"
  echo
  echo "    $link"
  echo
  echo "  It signs you in once. Then add a passkey when the page asks for it:"
  echo "  your phone, fingerprint or computer password is enough, no new"
  echo "  password to remember. The link works only once, keep it to yourself."
  echo
  echo "STEP 2 - Talk to your assistant"
  echo
  echo "  Open $dashboard in your browser"
  echo "  and log in with your passkey (account name: $account)."
  echo "  Bookmark the page: this is where you chat with Hermes from now on."
fi

claude=$(jq -r .claudeAuth <<<"$facts")
telegram=$(jq -r .hasTelegram <<<"$facts")
[ "$telegram" = true ] && note "telegram: the allowlisted user id is in the telegram var"

if [ "$claude" = true ] || [ -n "$dashboard" ] || [ "$telegram" = true ]; then
  echo
  echo "OPTIONAL - Make it yours"
  if [ "$claude" = true ]; then
    echo
    echo "  Have a Claude Pro or Max subscription? Your assistant can use it."
    echo "  Write in the chat: \"Connect my Claude subscription\". It sends you a"
    echo "  sign-in link: open it, log in to Claude, and paste the code you get"
    echo "  back into the chat."
  fi
  if [ "$telegram" = true ]; then
    echo
    echo "  Your Telegram bot is already set up: just send it a message."
  fi
  if [ -n "$dashboard" ]; then
    echo
    echo "  Want to reach your assistant from Telegram, WhatsApp, Signal and"
    echo "  other messengers? Connect them in the web interface on the"
    echo "  Channels page (left menu)."
  fi
fi

echo
if [ -n "$dashboard" ]; then
  echo "OPTIONAL - For terminal users"
  echo
  echo "  Everything above works in the browser. If you use a terminal and SSH:"
else
  echo "HOW TO CONNECT (terminal)"
  echo
fi
echo
echo "  Log in:            ssh $user@$host"
echo "  Chat in terminal:  ssh -t $user@$host hermes"
echo "  Coding agent:      ssh -t $user@$host afk --model p0/qwen"
if [ "$native" = true ]; then
  echo "  (you get a full shell in the account your assistant runs in)"
fi
