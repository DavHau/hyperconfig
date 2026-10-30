# porkbun-dns - manage DNS records on porkbun.
#
#   porkbun-dns list   <domain>
#   porkbun-dns get    <fqdn> <type>
#   porkbun-dns add    <fqdn> <type> <content> [--ttl N] [--prio N]
#   porkbun-dns set    <fqdn> <type> <content> [--ttl N] [--prio N]
#   porkbun-dns delete <fqdn> <type> [<content> | --all]
#
# <fqdn> is the full record name (id.davhau.com, or davhau.com for the
# apex). The zone is always the last two labels (so zones under a
# multi-label public suffix such as example.co.uk are not supported).
#
#   add     creates one more record next to existing ones of that
#           name/type (second MX, extra TXT); refuses when a record with
#           the same name, type and content already exists.
#   set     makes <content> the only value: creates the record when none
#           exists, edits it (by id) when exactly one exists, and refuses
#           when several exist (use add/delete then).
#   delete  with <content> removes only the records with that content;
#           without it removes the name/type's only record, or all of
#           them with --all.
#
# --ttl defaults to 600; --prio is the MX/SRV priority. `list` and `get`
# print porkbun's records as JSON.
#
# Credentials: PORKBUN_API_KEY / PORKBUN_SECRET_KEY if set, otherwise the
# shared `porkbun` clan var (the one dyndns-porkbun.nix uses), read with
# `clan vars get $PORKBUN_MACHINE porkbun/...` (default machine: edi; run
# inside the hyperconfig checkout). Keys are only ever passed to curl in
# the request body. PORKBUN_API_URL overrides the API base (for tests).

api=${PORKBUN_API_URL:-https://api.porkbun.com/api/json/v3}

usage() {
  # By pattern, not line numbers: writeShellApplication prepends a preamble.
  sed -n 's/^#   \(porkbun-dns .*\)/  \1/p' "$0" >&2
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

# show <records json array>: one line per record, for messages.
show() {
  jq -r '.[] | "  id=\(.id) \(.name) \(.type) \(.content) ttl=\(.ttl)"
    + (if (.prio // "0") != "0" then " prio=\(.prio)" else "" end)' <<<"$1" >&2
}

# record_body: the create/edit body for $sub $type $content $ttl $prio.
record_body() {
  jq -n --arg n "$sub" --arg y "$type" --arg c "$content" --arg t "$ttl" --arg p "$prio" \
    '{name: $n, type: $y, content: $c, ttl: $t} + (if $p == "" then {} else {prio: $p} end)'
}

# Options may appear anywhere after the command; the rest are positional.
ttl=600 prio='' all=''
args=()
while [ $# -gt 0 ]; do
  case $1 in
    --ttl)  [ $# -ge 2 ] || usage; ttl=$2; shift 2 ;;
    --prio) [ $# -ge 2 ] || usage; prio=$2; shift 2 ;;
    --all)  all=1; shift ;;
    -*)     usage ;;
    *)      args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"

[ $# -ge 1 ] || usage
cmd=$1
shift

case $cmd in
  list)    [ $# -eq 1 ] || usage ;;
  get)     [ $# -eq 2 ] || usage ;;
  add|set) [ $# -eq 3 ] || usage ;;
  delete)  [ $# -eq 2 ] || { [ $# -eq 3 ] && [ -z "$all" ]; } || usage ;;
  *)       usage ;;
esac
case $cmd in
  add|set) [ -z "$all" ] || usage ;;
  delete)  [ "$ttl" = 600 ] && [ -z "$prio" ] || usage ;;
  *)       [ -z "$all" ] && [ "$ttl" = 600 ] && [ -z "$prio" ] || usage ;;
esac

machine=${PORKBUN_MACHINE:-edi}
apikey=${PORKBUN_API_KEY:-$(clan vars get "$machine" porkbun/apikey)}
secretkey=${PORKBUN_SECRET_KEY:-$(clan vars get "$machine" porkbun/secretkey)}
[ -n "$apikey" ] && [ -n "$secretkey" ] || die "no porkbun credentials"

if [ "$cmd" = list ]; then
  split_name "$1"
  call "dns/retrieve/$zone" | jq .records
  exit
fi

split_name "$1"
type=$2 content=${3:-}
existing=$(call "dns/retrieveByNameType/$zone/$type/$sub" | jq -c .records)
count=$(jq length <<<"$existing")

case $cmd in
  get)
    jq . <<<"$existing"
    ;;
  add)
    same=$(jq -c --arg c "$content" 'map(select(.content == $c))' <<<"$existing")
    if [ "$(jq length <<<"$same")" -gt 0 ]; then
      echo "porkbun-dns: $1 $type already has this record:" >&2
      show "$same"
      exit 1
    fi
    call "dns/create/$zone" "$(record_body)" >/dev/null
    echo "added: $1 $type -> $content (now $((count + 1)) record(s))"
    ;;
  set)
    if [ "$count" -eq 0 ]; then
      call "dns/create/$zone" "$(record_body)" >/dev/null
      echo "created: $1 $type -> $content"
    elif [ "$count" -eq 1 ]; then
      id=$(jq -r '.[0].id' <<<"$existing")
      # porkbun's edit replaces every field: keep the old prio unless given.
      [ -n "$prio" ] || prio=$(jq -r '.[0].prio // ""' <<<"$existing")
      call "dns/edit/$zone/$id" "$(record_body)" >/dev/null
      echo "updated record $id: $1 $type -> $content"
    else
      echo "porkbun-dns: $1 $type has $count records, refusing to overwrite them all:" >&2
      show "$existing"
      echo "use 'add' for another record, or 'delete $1 $type <content>' first" >&2
      exit 1
    fi
    ;;
  delete)
    if [ -n "$content" ]; then
      victims=$(jq -c --arg c "$content" 'map(select(.content == $c))' <<<"$existing")
      [ "$(jq length <<<"$victims")" -gt 0 ] \
        || die "no $1 $type record with content: $content"
    else
      [ "$count" -gt 0 ] || die "no $1 $type record"
      if [ "$count" -gt 1 ] && [ -z "$all" ]; then
        echo "porkbun-dns: $1 $type has $count records:" >&2
        show "$existing"
        echo "give the content of the one to delete, or --all" >&2
        exit 1
      fi
      victims=$existing
    fi
    for id in $(jq -r '.[].id' <<<"$victims"); do
      call "dns/delete/$zone/$id" >/dev/null
    done
    echo "deleted $(jq length <<<"$victims") record(s):"
    show "$victims" 2>&1
    ;;
esac
