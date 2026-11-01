#!/usr/bin/env bash
# Host tests for the ESPHome tang component (components/tang/), against stock tooling.
#
# Usage: locations/common/esphome/tests/tang/run.sh
#
# 1. tang-keygen.sh makes a throwaway key pair; tangd (nixpkgs#tang) serves it and
#    tang-check.sh round-trips a secret through stock clevis: the key format works.
# 2. gen_host_config.py runs the component's build-time code (jose.py) on those keys:
#    the advertisement verifies with `jose jws ver`, the kids match `jose jwk thp`
#    (S256 and S1), the payload carries exactly the one deriveKey key.
# 3. tang_core.cpp is compiled for the host with nixpkgs' bearssl (host_server.cpp):
#    br_ec_p256_m15.mul() replies equal `jose jwk exc` for random client keys and for
#    a coordinate sent without its leading zero byte; off-curve points are refused.
# 4. host_server serves the build-time advertisement + core request path, and
#    tang-check.sh round-trips through stock clevis against it; HTTP edge cases.
#
# Everything comes from nixpkgs via nix; nothing is installed. Exit status 0 = all pass.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
esphome_dir=$(cd "$here/../.." && pwd)

if [[ -z ${TANG_TEST_SHELL:-} ]]; then
    exec env TANG_TEST_SHELL=1 nix shell nixpkgs#clevis nixpkgs#jose nixpkgs#curl nixpkgs#gcc nixpkgs#tang \
        -c "$0" "$@"
fi

store() { nix build --no-link --print-out-paths "$@" | head -n1; }
python=$(store --impure --expr \
    '(builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}.python3.withPackages (ps: [ ps.cryptography ])')/bin/python3
bearssl_dev=$(store nixpkgs#bearssl.dev)
bearssl_lib=$(store nixpkgs#bearssl.lib)
# The ArduinoJson version ESPHome 2026.9's json component pins.
arduinojson=$(nix store prefetch-file --json \
    --expected-hash sha256-q1+7gmi4RrX0vFpf7hG7LJb3uLhG9b72VAr7apzHals= \
    https://github.com/bblanchon/ArduinoJson/releases/download/v7.4.3/ArduinoJson-v7.4.3.h |
    jose fmt -j- -g storePath -u-)
tangd=$(dirname "$(command -v tang-show-keys)")/../libexec/tangd

work=$(mktemp -d)
pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    rm -rf "$work"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS  %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$*"; }
check() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
free_port() { "$python" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
wait_port() { for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$1/adv" && return 0; sleep 0.1; done; return 1; }

echo "== keygen + stock tangd"
"$esphome_dir/tang-keygen.sh" "$work/secrets.yaml" "$work/keys" >"$work/keygen.out"
sig_thp=$(sed -n 's/^signing key thumbprint (clevis thp): //p' "$work/keygen.out")
exc_kid=$(sed -n 's/^exchange key kid (S256): *//p' "$work/keygen.out")
check "keygen: secrets file mode 0600" 600 "$(stat -c %a "$work/secrets.yaml")"
check "keygen: tangd key dir holds both keys" 2 "$(find "$work/keys" -name '*.jwk' | wc -l)"
port=$(free_port)
"$tangd" -l -p "$port" "$work/keys" >"$work/tangd.log" 2>&1 &
pids+=($!)
wait_port "$port"
if "$esphome_dir/tang-check.sh" "http://127.0.0.1:$port" "$sig_thp" >"$work/check-tangd.out" 2>&1; then
    ok "tang-check.sh against tangd with keygen keys (thp pinned)"
else
    bad "tang-check.sh against tangd: $(cat "$work/check-tangd.out")"
fi

echo "== build-time advertisement (jose.py)"
"$python" "$here/gen_host_config.py" "$work/secrets.yaml" "$work"
{ read -r kid256; read -r kid1; read -r adv_thp; } <"$work/kids.txt"
exc_jwk=$work/keys/$exc_kid.jwk
if jose jws ver -i "$work/adv.jws" -k "$work/sig.pub.jwk"; then ok "jose jws ver accepts the advertisement"; else bad "jose jws ver"; fi
check "kid S256 matches jose jwk thp" "$(jose jwk thp -i "$exc_jwk" -a S256)" "$kid256"
check "kid S1 matches jose jwk thp" "$(jose jwk thp -i "$exc_jwk" -a S1)" "$kid1"
check "signing thumbprint matches keygen" "$sig_thp" "$adv_thp"
jose fmt -j "$work/adv.jws" -g payload -y -o- >"$work/payload.json"
check "payload: one deriveKey key, the exchange key" "$kid256" \
    "$(jose jwk use -i "$work/payload.json" -r -u deriveKey -o- | jose jwk thp -i- -a S256)"
check "payload: one verify key, the signing key" "$sig_thp" \
    "$(jose jwk use -i "$work/payload.json" -r -u verify -o- | jose jwk thp -i- -a S256)"

echo "== tang_core.cpp + bearssl vs jose jwk exc"
cp "$arduinojson" "$work/ArduinoJson.h"
g++ -std=gnu++20 -O1 -Wall -Wextra -Wno-unused-parameter -I "$esphome_dir/components/tang" -I "$work" \
    -I "$bearssl_dev/include" "$esphome_dir/components/tang/tang_core.cpp" "$here/host_server.cpp" \
    -L "$bearssl_lib/lib" -Wl,-rpath,"$bearssl_lib/lib" -lbearssl -o "$work/host_server"
ok "host_server compiles"
mismatch=0
for i in $(seq 20); do
    jose jwk gen -i '{"alg":"ECMR","crv":"P-256"}' -o "$work/c.jwk"
    jose jwk pub -i "$work/c.jwk" -o "$work/cpub.jwk"
    # Compared by RFC 7638 thumbprint: equal iff kty, crv, x and y are, whatever the member order.
    want=$(jose jwk exc -l "$exc_jwk" -r "$work/cpub.jwk")
    got=$("$work/host_server" --exc "$work/cpub.jwk")
    [[ $(jose jwk thp -i- <<<"$want") == "$(jose jwk thp -i- <<<"$got")" ]] ||
        { mismatch=1; echo "    want $want"; echo "    got  $got"; }
done
check "20 random ECMR exchanges equal jose jwk exc" 0 "$mismatch"
# A client coordinate whose leading byte is 0x00, sent stripped (as some encoders do):
# the core must left-pad it back to 32 bytes.
"$python" - "$work" <<'EOF'
import base64, json, sys
from cryptography.hazmat.primitives.asymmetric import ec
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
while True:
    pub = ec.generate_private_key(ec.SECP256R1()).public_key().public_numbers()
    x, y = pub.x.to_bytes(32, "big"), pub.y.to_bytes(32, "big")
    if x[0] == 0 or y[0] == 0:
        break
full = {"alg": "ECMR", "crv": "P-256", "kty": "EC", "x": b64(x), "y": b64(y)}
stripped = dict(full, x=b64(x.lstrip(b"\0") if x[0] == 0 else x), y=b64(y.lstrip(b"\0") if y[0] == 0 else y))
off = dict(full, y=b64(y[:-1] + bytes([y[-1] ^ 1])))
for name, jwk in (("full", full), ("stripped", stripped), ("offcurve", off)):
    open(f"{sys.argv[1]}/{name}.jwk", "w").write(json.dumps(jwk))
EOF
want=$(jose jwk exc -l "$exc_jwk" -r "$work/full.jwk" | jose jwk thp -i-)
check "leading-zero coordinate, stripped, still equals jose jwk exc" "$want" \
    "$("$work/host_server" --exc "$work/stripped.jwk" | jose jwk thp -i-)"
if "$work/host_server" --exc "$work/offcurve.jwk" 2>/dev/null; then bad "off-curve point refused"; else ok "off-curve point refused"; fi

echo "== host_server (core request path) with stock clevis"
port=$(free_port)
"$work/host_server" "$port" 2>"$work/host_server.log" &
pids+=($!)
wait_port "$port"
url=http://127.0.0.1:$port
if "$esphome_dir/tang-check.sh" "$url" >"$work/check1.out" 2>&1; then ok "tang-check.sh (adv trusted)"; else bad "tang-check.sh: $(cat "$work/check1.out")"; fi
if REPEAT=2 "$esphome_dir/tang-check.sh" "$url" "$sig_thp" >"$work/check2.out" 2>&1; then
    ok "tang-check.sh (thp pinned, /adv/<thp>)"
else
    bad "tang-check.sh thp: $(cat "$work/check2.out")"
fi
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check "GET /adv/ -> 200" 200 "$(code "$url/adv/")"
check "GET /adv/anything -> 200" 200 "$(code "$url/adv/anything")"
check "GET /adv/a/b -> 404" 404 "$(code "$url/adv/a/b")"
check "GET /rec/<kid> -> 405" 405 "$(code "$url/rec/$kid256")"
check "POST /rec/<unknown> -> 404" 404 "$(code -X POST --data-binary @"$work/full.jwk" "$url/rec/AAAA")"
check "POST /rec/<S1 kid> -> 200" 200 "$(code -H 'Content-Type: application/jwk+json' --data-binary @"$work/full.jwk" "$url/rec/$kid1")"
check "POST /rec/<kid> off-curve -> 400" 400 "$(code --data-binary @"$work/offcurve.jwk" "$url/rec/$kid256")"
check "POST /rec/<kid> garbage -> 400" 400 "$(code --data-binary 'nope' "$url/rec/$kid256")"
check "POST /rec/<kid> P-521 crv -> 400" 400 \
    "$(code --data-binary "$(jose fmt -j "$work/full.jwk" -q P-521 -s crv -U -o-)" "$url/rec/$kid256")"
check "POST oversized body -> 413" 413 "$(code --data-binary "$(head -c 3000 /dev/zero | tr '\0' a)" "$url/rec/$kid256")"

echo
echo "passed $pass, failed $fail"
[[ $fail -eq 0 ]]
