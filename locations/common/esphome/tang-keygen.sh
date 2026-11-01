#!/usr/bin/env bash
# Generate the private keys for the ESPHome `tang` component (components/tang/).
#
# Usage:
#   tang-keygen.sh [--force] <secrets.yaml> [<tangd-key-dir>]
# e.g.
#   locations/common/esphome/tang-keygen.sh locations/casa/esphome/secrets.yaml
#
# Writes two private JWKs, as single-line JSON strings, into the device's gitignored
# secrets.yaml (created mode 0600 if missing), where tang.yaml picks them up via !secret:
#   tang_exchange_key  P-256 ECMR exchange key ("deriveKey"). P-256 because the ESP8266
#                      multiplies with BearSSL's P-256-only backend; stock clevis/jose
#                      accept any of P-256/384/521 for the exchange.
#   tang_signing_key   P-521 ES512 advertisement signing key, as tangd-keygen makes. Only
#                      used at build time to sign /adv; the device never signs.
# Refuses to replace existing tang_* entries unless --force is given: replacing the
# exchange key orphans every clevis binding made against the old one (move the old
# exchange key to `old_keys:` instead if bindings still use it).
#
# With <tangd-key-dir>, also stores both keys as <thumbprint>.jwk (mode 0600) in the
# layout `tangd` reads, e.g. to test the key format against a stock server:
#   tangd -l -p 9090 <tangd-key-dir>   # nixpkgs#tang; then ./tang-check.sh http://localhost:9090
#
# Prints the signing key thumbprint (the "thp" clevis shows and accepts at bind time)
# and the exchange key's kid (the <kid> in POST /rec/<kid>; also in the device log).
#
# Needs jose; re-runs itself under `nix shell nixpkgs#jose` if it is not on PATH.

set -euo pipefail

if ! command -v jose >/dev/null; then
    exec nix shell nixpkgs#jose -c "$0" "$@"
fi

force=0
if [[ ${1:-} == --force ]]; then
    force=1
    shift
fi
[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: $0 [--force] <secrets.yaml> [<tangd-key-dir>]" >&2; exit 2; }
secrets=$1
keydir=${2:-}

umask 077
if [[ -e $secrets ]] && grep -qE '^tang_(exchange|signing)_key:' "$secrets"; then
    if [[ $force -ne 1 ]]; then
        echo "$secrets already holds tang_* keys; pass --force to replace them" >&2
        exit 1
    fi
fi

exc=$(jose jwk gen -i '{"alg":"ECMR","crv":"P-256"}')
sig=$(jose jwk gen -i '{"alg":"ES512"}')
exc_kid=$(jose jwk thp -i- -a S256 <<<"$exc")
sig_thp=$(jose jwk thp -i- -a S256 <<<"$sig")

# The JWKs are compact JSON without single quotes, so YAML single quotes hold them verbatim.
touch "$secrets"
existing=$(grep -vE '^tang_(exchange|signing)_key:' "$secrets" || true)
{
    [[ -n $existing ]] && printf '%s\n' "$existing"
    printf "tang_exchange_key: '%s'\n" "$exc"
    printf "tang_signing_key: '%s'\n" "$sig"
} >"$secrets.tmp.$$"
# cat > rather than mv: keep the file's inode, owner and mode.
cat "$secrets.tmp.$$" >"$secrets"
rm -f "$secrets.tmp.$$"

if [[ -n $keydir ]]; then
    mkdir -p "$keydir"
    printf '%s\n' "$exc" >"$keydir/$exc_kid.jwk"
    printf '%s\n' "$sig" >"$keydir/$sig_thp.jwk"
fi

echo "wrote tang_exchange_key and tang_signing_key to $secrets${keydir:+ (and $keydir/)}"
echo "signing key thumbprint (clevis thp): $sig_thp"
echo "exchange key kid (S256):             $exc_kid"
