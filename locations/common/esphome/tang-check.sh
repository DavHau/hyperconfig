#!/usr/bin/env bash
# End-to-end check of a Tang server with stock clevis: encrypt a random secret against
# it, decrypt it again, compare, and time the decrypt (one /rec round trip).
#
# Usage:
#   tang-check.sh <url> [<thp>]
# e.g. (device in casa, through nas; the tang component listens on 7654):
#   ssh -N -L 7654:192.168.20.31:7654 root@nas.d &
#   locations/common/esphome/tang-check.sh http://localhost:7654
#   REPEAT=5 locations/common/esphome/tang-check.sh http://localhost:7654 <thp>
#
# Steps:
#   1. GET <url>/adv and print the advertised signing key thumbprint(s).
#   2. clevis encrypt tang: with <thp> given, clevis fetches <url>/adv/<thp> itself and
#      trusts it only if <thp> signed it; without, the advertisement fetched in step 1 is
#      trusted as-is ({"adv": ...}, trust on first use; compare the printed thp against
#      the clan var esphome-<loc>/tang_thp or the device's dump_config log).
#   3. clevis decrypt, REPEAT times (default 1), printing the wall-clock time of each; the
#      device logs the multiply time of each /rec at INFO ("P-256 multiply <n> us").
#   4. Compare the decrypted secret with the original; exit 1 on any mismatch/failure.
#
# Needs clevis, jose and curl; re-runs itself under `nix shell` if one is missing.

set -euo pipefail

for tool in clevis jose curl; do
    if ! command -v "$tool" >/dev/null; then
        exec nix shell nixpkgs#clevis nixpkgs#jose nixpkgs#curl -c "$0" "$@"
    fi
done

[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: $0 <url> [<thp>]" >&2; exit 2; }
url=${1%/}
thp=${2:-}
repeat=${REPEAT:-1}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch_time=$(curl -sfg -m 30 -o "$work/adv.jws" -w '%{time_total}' "$url/adv") ||
    { echo "FAIL: GET $url/adv" >&2; exit 1; }
# The same derivation clevis-encrypt-tang uses: the payload's verify keys, thumbprinted.
advertised=$(jose fmt -j "$work/adv.jws" -g payload -y -o- |
    jose jwk use -i- -r -u verify -o- |
    jose jwk thp -i- -a S256)
echo "GET /adv: ${fetch_time}s; signing thumbprint(s): $advertised"

if [[ -n $thp ]]; then
    grep -qxF "$thp" <<<"$advertised" || { echo "FAIL: $thp is not among the advertised signing keys" >&2; exit 1; }
    cfg=$(jose fmt -j '{}' -q "$url" -s url -U -q "$thp" -s thp -U -o-)
else
    cfg=$(jose fmt -j '{}' -q "$url" -s url -U -q "$work/adv.jws" -s adv -U -o-)
fi

secret=$(head -c 32 /dev/urandom | base64)
printf '%s' "$secret" | clevis encrypt tang "$cfg" >"$work/secret.jwe" ||
    { echo "FAIL: clevis encrypt tang $cfg" >&2; exit 1; }
kid=$(cut -d. -f1 "$work/secret.jwe" | jose b64 dec -i- | jose fmt -j- -g kid -u-)
echo "clevis encrypt: OK (kid $kid)"

for ((i = 1; i <= repeat; i++)); do
    start=$(date +%s%N)
    if ! got=$(clevis decrypt <"$work/secret.jwe"); then
        echo "FAIL: clevis decrypt (run $i)" >&2
        exit 1
    fi
    end=$(date +%s%N)
    if [[ $got != "$secret" ]]; then
        echo "FAIL: decrypted secret differs (run $i)" >&2
        exit 1
    fi
    echo "clevis decrypt $i/$repeat: OK in $(((end - start) / 1000000)) ms"
done
echo "PASS: $url"
