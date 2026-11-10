# Post-deploy check of a space's forge logins (./forges.nix), run in the
# space as its user: `space-forge-check`. For every login of tea's config:
# the API answers /api/v1/user with the expected bot account (so the token
# from the credential is valid), and lists the repositories that account
# can push to (the ones it can open and merge PRs in). Exit 1 if any login
# fails. Prints no token.
set -euo pipefail
logins=$1
fail=0
while IFS=$'\t' read -r name url user; do
  echo "== $name ($url), expecting $user"
  me=$(tea api --login "$name" /user 2>&1) || true
  got=$(jq -r '.login // empty' <<<"$me" 2>/dev/null || true)
  if [ "$got" != "$user" ]; then
    echo "FAIL: /api/v1/user: $(jq -r '.message // .' <<<"$me" 2>/dev/null | head -c 300)"
    fail=1
    continue
  fi
  echo "ok: authenticated as $got"
  page=1 writable=()
  while :; do
    batch=$(tea api --login "$name" "/user/repos?limit=50&page=$page")
    mapfile -t names < <(jq -r '.[] | select(.permissions.push) | .full_name' <<<"$batch")
    writable+=("${names[@]}")
    [ "$(jq length <<<"$batch")" -lt 50 ] && break
    page=$((page + 1))
  done
  echo "repositories $user can push to (${#writable[@]}):"
  if [ "${#writable[@]}" -gt 0 ]; then
    printf '  %s\n' "${writable[@]}"
  else
    echo "WARN: none; add $user to the repositories' teams"
  fi
done < <(jq -r '.logins[] | [.name, .url, .user] | @tsv' "$logins")
exit "$fail"
