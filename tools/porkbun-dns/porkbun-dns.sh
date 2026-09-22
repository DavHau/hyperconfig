# porkbun-dns - manage DNS records on porkbun.
#
#   porkbun-dns list   <domain>
#   porkbun-dns get    <fqdn> <type>
#   porkbun-dns set    <fqdn> <type> <content> [ttl]   # create or update
#   porkbun-dns delete <fqdn> <type>
#
# <fqdn> is the full record name (id.davhau.com, or davhau.com for the
# apex). The zone is the last two labels; porkbun addresses a record by
# zone + type + subdomain, so `set` updates every existing record of that
# name/type or creates one when none exists. `list` prints the zone as
# porkbun returns it (JSON).
#
# Credentials: PORKBUN_API_KEY / PORKBUN_SECRET_KEY if set, otherwise the
# shared `porkbun` clan var (the one dyndns-porkbun.nix uses), read with
# `clan vars get $PORKBUN_MACHINE porkbun/...` (default machine: edi; run
# inside the hyperconfig checkout). Keys are only ever passed to curl in
# the request body.

api=https://api.porkbun.com/api/json/v3

usage() {
  sed -n '2,7p' "$0" >&2
  exit 2
}

die() {
  echo "porkbun-dns: $*" >&2
  exit 1
}

# split_name <fqdn>: sets zone and sub ('' for the apex).
split_name() {
  local fqdn=$1
  zone=$(printf '%s' "$fqdn" | awk -F. 'NF < 2 { exit 1 } { print $(NF-1) "." $NF }') \
    || die "not a DNS name: $fqdn"
  sub=${fqdn%"$zone"}
  sub=${sub%.}
}

# call <endpoint> [jq filter building extra body fields] : POSTs the
# credentials plus the extra JSON object, prints the response, fails on
# any non-SUCCESS status.
call() {
  local endpoint=$1 extra=${2:-{\}} response
  response=$(jq -n --arg k "$apikey" --arg s "$secretkey" --argjson extra "$extra" \
    '{apikey: $k, secretapikey: $s} + $extra' \
    | curl --silent --show-error --fail-with-body -H 'Content-Type: application/json' \
        --data @- "$api/$endpoint") \
    || die "$endpoint: $response"
  [ "$(jq -r .status <<<"$response")" = SUCCESS ] \
    || die "$endpoint: $(jq -r '.message // .' <<<"$response")"
  printf '%s\n' "$response"
}

[ $# -ge 1 ] || usage
cmd=$1
shift

case $cmd in
  list)   [ $# -eq 1 ] || usage ;;
  get)    [ $# -eq 2 ] || usage ;;
  set)    [ $# -eq 3 ] || [ $# -eq 4 ] || usage ;;
  delete) [ $# -eq 2 ] || usage ;;
  *)      usage ;;
esac

machine=${PORKBUN_MACHINE:-edi}
apikey=${PORKBUN_API_KEY:-$(clan vars get "$machine" porkbun/apikey)}
secretkey=${PORKBUN_SECRET_KEY:-$(clan vars get "$machine" porkbun/secretkey)}
[ -n "$apikey" ] && [ -n "$secretkey" ] || die "no porkbun credentials"

case $cmd in
  list)
    split_name "$1"
    call "dns/retrieve/$zone" | jq .records
    ;;
  get)
    split_name "$1"
    call "dns/retrieveByNameType/$zone/$2/$sub" | jq .records
    ;;
  set)
    split_name "$1"
    type=$2 content=$3 ttl=${4:-600}
    existing=$(call "dns/retrieveByNameType/$zone/$type/$sub" | jq '.records | length')
    if [ "$existing" -gt 0 ]; then
      call "dns/editByNameType/$zone/$type/$sub" \
        "$(jq -n --arg c "$content" --arg t "$ttl" '{content: $c, ttl: $t}')" >/dev/null
      echo "updated $existing record(s): $1 $type -> $content"
    else
      call "dns/create/$zone" \
        "$(jq -n --arg n "$sub" --arg y "$type" --arg c "$content" --arg t "$ttl" \
           '{name: $n, type: $y, content: $c, ttl: $t}')" >/dev/null
      echo "created: $1 $type -> $content"
    fi
    ;;
  delete)
    split_name "$1"
    call "dns/deleteByNameType/$zone/$2/$sub" >/dev/null
    echo "deleted: $1 $2"
    ;;
esac
