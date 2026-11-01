#!/usr/bin/env python3
"""Turn tang-keygen.sh's secrets.yaml entries into host_config.h for host_server.

Uses the component's own build-time code (components/tang/jose.py): the same key
validation, thumbprints and advertisement signing that to_code() runs, so the
host server serves what the firmware would. Also writes the advertisement to
<out-dir>/adv.jws and the public signing JWK to <out-dir>/sig.pub.jwk for
`jose jws ver`, and the kids to <out-dir>/kids.txt.

    gen_host_config.py <secrets.yaml> <out-dir>
"""

import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "components" / "tang"))

from jose import build_advertisement, thumbprints, validate_private_ec_jwk  # noqa: E402


def main():
    secrets, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    entries = dict(re.findall(r"^(tang_\w+): '(.*)'$", secrets.read_text(), re.M))
    exc, crv, d = validate_private_ec_jwk(entries["tang_exchange_key"])
    assert crv == "P-256", crv
    sig, _, _ = validate_private_ec_jwk(entries["tang_signing_key"])

    adv = build_advertisement([exc], sig)
    kid256, kid1 = thumbprints(crv, exc["x"], exc["y"])
    thp = thumbprints(sig["crv"], sig["x"], sig["y"])[0]

    (out / "adv.jws").write_text(adv)
    (out / "sig.pub.jwk").write_text(
        json.dumps({k: sig[k] for k in ("kty", "crv", "x", "y")})
    )
    (out / "kids.txt").write_text(f"{kid256}\n{kid1}\n{thp}\n")
    d_init = ", ".join(f"0x{b:02X}" for b in d)
    (out / "host_config.h").write_text(
        f"static const char ADV[] = {json.dumps(adv)};\n"
        f"static const uint8_t KEY_D[32] = {{{d_init}}};\n"
        f"static const char KID_SHA256[] = {json.dumps(kid256)};\n"
        f"static const char KID_SHA1[] = {json.dumps(kid1)};\n"
    )


if __name__ == "__main__":
    main()
