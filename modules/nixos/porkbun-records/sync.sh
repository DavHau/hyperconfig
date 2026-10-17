# porkbun-records-sync [--dry-run] <config.json>
#
# Brings the porkbun records declared in <config.json> (written by
# ./default.nix) in line: creates a missing record, edits one whose content
# differs, and deletes the records of a name/type that was declared before
# (the state file) and no longer is. Nothing else in the zone is touched.
#
# Order, so that a bad answer never costs a record: every lookup first
# (retrieveByNameType), then the writes; any failed or malformed answer
# aborts before the first write. A record whose runtime source fails is
# left as it is and the run ends non-zero; it still counts as declared, so
# it is never deleted for that.
#
# --dry-run prints the planned calls and writes nothing (no API write, no
# state file). Credentials: $CREDENTIALS_DIRECTORY/{apikey,secretkey}
# (LoadCredential=), else PORKBUN_API_KEY / PORKBUN_SECRET_KEY. They only
# ever reach curl in the request body, never its argv. PORKBUN_RECORDS_STATE
# overrides the state file (a dry run elsewhere has none: nothing to delete).

usage() {
  echo "usage: porkbun-records-sync [--dry-run] <config.json>" >&2
  exit 2
}

die() {
  echo "porkbun-records: $*" >&2
  exit 1
}

dry_run=0
if [ "${1:-}" = --dry-run ]; then
  dry_run=1
  shift
fi
[ $# -eq 1 ] || usage
config=$1

api=$(jq -r .apiBase "$config")
ttl=$(jq -r .ttl "$config")
state=${PORKBUN_RECORDS_STATE:-$(jq -r .stateFile "$config")}

if [ -n "${CREDENTIALS_DIRECTORY:-}" ]; then
  apikey=$(<"$CREDENTIALS_DIRECTORY/apikey")
  secretkey=$(<"$CREDENTIALS_DIRECTORY/secretkey")
else
  apikey=${PORKBUN_API_KEY:-}
  secretkey=${PORKBUN_SECRET_KEY:-}
fi
[ -n "$apikey" ] && [ -n "$secretkey" ] || die "no porkbun credentials"

# split_name <fqdn>: sets zone (the last two labels, as porkbun-dns does)
# and sub ('' for the apex).
split_name() {
  local fqdn=$1
  zone=$(printf '%s' "$fqdn" | awk -F. 'NF < 2 { exit 1 } { print $(NF-1) "." $NF }') \
    || die "not a DNS name: $fqdn"
  sub=${fqdn%"$zone"}
  sub=${sub%.}
}

# call <endpoint> [extra JSON body fields]: POSTs the credentials plus the
# extra fields, prints the response, fails on anything but status SUCCESS.
call() {
  local endpoint=$1 extra=${2:-{\}} response
  response=$(jq -n --arg k "$apikey" --arg s "$secretkey" --argjson extra "$extra" \
    '{apikey: $k, secretapikey: $s} + $extra' \
    | curl --silent --show-error --fail-with-body --max-time 60 \
        -H 'Content-Type: application/json' --data @- "$api/$endpoint") \
    || die "$endpoint: ${response:-no answer}"
  [ "$(jq -r .status <<<"$response" 2>/dev/null)" = SUCCESS ] \
    || die "$endpoint: $(jq -r '.message // .' <<<"$response" 2>/dev/null || printf '%s' "$response")"
  printf '%s\n' "$response"
}

# contents <fqdn> <type>: the contents of every existing record of that
# name and type, one JSON array; dies unless the answer carries a list.
contents() {
  split_name "$1"
  call "dns/retrieveByNameType/$zone/$2/$sub" \
    | jq -ce 'if (.records | type) == "array" then [.records[].content] else error("no record list") end' \
    || die "dns/retrieveByNameType/$zone/$2/$sub: malformed answer"
}

# --- plan: lookups only --------------------------------------------------
failed=0
plan=()
mapfile -t declared < <(jq -c '.records[] | {name, type}' "$config")
count=$(jq '.records | length' "$config")
for ((i = 0; i < count; i++)); do
  rec=$(jq -c ".records[$i]" "$config")
  name=$(jq -r .name <<<"$rec")
  type=$(jq -r .type <<<"$rec")
  if jq -e 'has("command")' <<<"$rec" >/dev/null; then
    mapfile -t argv < <(jq -r '.command[]' <<<"$rec")
    if ! content=$("${argv[@]}") || [ -z "$content" ]; then
      echo "porkbun-records: $name $type: its source failed, record left as it is" >&2
      failed=1
      continue
    fi
  else
    content=$(jq -r .content <<<"$rec")
  fi
  have=$(contents "$name" "$type")
  if [ "$(jq length <<<"$have")" -eq 0 ]; then
    plan+=("create $name $type $content")
  elif jq -e --arg c "$content" 'all(. == $c)' <<<"$have" >/dev/null; then
    echo "unchanged: $name $type $content"
  else
    plan+=("edit $name $type $content")
  fi
done

declared_json=$(printf '%s\n' "${declared[@]}" | jq -cs 'unique')
managed='[]'
if [ -e "$state" ]; then
  managed=$(jq -ce 'if type == "array" then . else error("not a list") end' "$state") \
    || die "$state: not a list of records"
fi
mapfile -t gone < <(jq -c --argjson d "$declared_json" '.[] | select(. as $r | $d | any(. == $r) | not)' <<<"$managed")
for rec in "${gone[@]}"; do
  name=$(jq -r .name <<<"$rec")
  type=$(jq -r .type <<<"$rec")
  # outside the `if`: errexit must still catch a failed lookup here
  have=$(contents "$name" "$type")
  if [ "$(jq length <<<"$have")" -gt 0 ]; then
    plan+=("delete $name $type")
  fi
done

if [ "$dry_run" = 1 ]; then
  for step in "${plan[@]}"; do echo "would $step"; done
  [ ${#plan[@]} -gt 0 ] || echo "nothing to change"
  exit "$failed"
fi

# --- act -----------------------------------------------------------------
# write_state <json>: atomically, so a crash never loses a managed name.
write_state() {
  printf '%s\n' "$1" >"$state.new"
  mv "$state.new" "$state"
}
# Everything about to be created counts as managed before it exists, so a
# crash in between cannot leave a record this module would never delete.
write_state "$(jq -c --argjson d "$declared_json" '. + $d | unique' <<<"$managed")"

for step in "${plan[@]}"; do
  read -r action name type content <<<"$step"
  split_name "$name"
  case $action in
    create)
      call "dns/create/$zone" \
        "$(jq -n --arg n "$sub" --arg y "$type" --arg c "$content" --arg t "$ttl" \
           '{name: $n, type: $y, content: $c, ttl: $t}')" >/dev/null
      echo "created: $name $type $content"
      ;;
    edit)
      call "dns/editByNameType/$zone/$type/$sub" \
        "$(jq -n --arg c "$content" --arg t "$ttl" '{content: $c, ttl: $t}')" >/dev/null
      echo "updated: $name $type $content"
      ;;
    delete)
      call "dns/deleteByNameType/$zone/$type/$sub" >/dev/null
      echo "deleted: $name $type"
      ;;
  esac
done
write_state "$declared_json"
exit "$failed"
