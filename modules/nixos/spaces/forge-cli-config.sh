# Writes tea's config for the space's user: the logins of $1 (JSON, tea's
# config.yml schema plus a `credential` per login, no tokens) with each
# token read from the credential file $2/<credential>, to $3, owned by the
# user $4, 0600. Runs as root in the guest; tea reads it through its
# wrapper (./forges.nix).
set -euo pipefail
template=$1 secrets=$2 out=$3
config=$(jq 'del(.logins[].credential)' "$template")
n=$(jq '.logins | length' "$template")
for ((i = 0; i < n; i++)); do
  cred=$(jq -r ".logins[$i].credential" "$template")
  if [ ! -s "$secrets/$cred" ]; then
    echo "forge credential $cred missing or empty; its login gets no token" >&2
    continue
  fi
  # the token as --rawfile: never on a command line
  config=$(printf '%s' "$config" | jq --rawfile t "$secrets/$cred" --argjson i "$i" \
    '.logins[$i].token = ($t | rtrimstr("\n"))')
done
umask 077
printf '%s\n' "$config" >"$out.tmp"
chown "$4:$4" "$out.tmp"
mv "$out.tmp" "$out"
